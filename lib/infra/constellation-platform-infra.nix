# Per-system Constellation Platform infrastructure builder
#
# Reads constellation.json and generates Fleet flows + nix run apps
# from the typed workspace DAG. Extends fleet-pangea-infra.nix.
#
# The constellation.json is the typed contract between arch-synthesizer
# (Rust proof engine) and this builder (Nix rendering target).
#
# Usage:
#   constellationInfra = import "${substrate}/lib/infra/constellation-platform-infra.nix" {
#     inherit nixpkgs system ruby-nix substrate forge fleet;
#   };
#   outputs = constellationInfra {
#     inherit self;
#     name = "quero-platform";
#     constellation = builtins.fromJSON (builtins.readFile (self + "/constellation.json"));
#   };
#
# Apps produced (for constellation with layers [iam, state, dns, vpc, builders, cache]):
#   flow-plan-quero-iam       — plan single workspace
#   flow-deploy-quero-iam     — deploy single workspace
#   flow-destroy-quero-iam    — destroy single workspace
#   ... (3 per deployable workspace)
#   flow-plan-quero-stack     — plan all in topological order
#   flow-deploy-quero-stack   — deploy all in topological order
#   flow-destroy-quero-stack  — destroy all in reverse topological order
#   flow-list                 — list all flows
#   plan, apply, destroy      — bulk pangea operations
#   test                      — bundle exec rspec
{
  nixpkgs,
  system,
  ruby-nix,
  substrate,
  forge,
  fleet ? null,
  pangea ? null,
}:
{
  name,
  self,
  constellation,  # REQUIRED: parsed constellation.json (attrset)
  shellHookExtra ? "",
  devShellExtras ? [],
}:
let
  pkgs = import nixpkgs { inherit system; };
  lib = pkgs.lib;

  # Extract constellation fields
  domain = constellation.domain;
  account = constellation.account;
  layers = constellation.layers;
  prefix = builtins.head (lib.splitString "." domain);

  # Filter to deployable layers only
  deployableLayers = builtins.filter (l: l.deployable) layers;

  # Build a step for a single workspace
  mkStep = layer: operation: let
    ws = layer.workspace;
    template = layer.template;
  in {
    id = layer.layer;
    action = {
      type = "pangea";
      file = "workspaces/${ws}/${template}";
      namespace = "development";
      inherit operation;
      env = { AWS_PROFILE = account.profile; };
    };
  } // (if layer.depends_on != [] then {
    depends_on = layer.depends_on;
  } else {});

  # Per-workspace flows: plan-{ws}, deploy-{ws}, destroy-{ws}
  perWorkspaceFlows = builtins.listToAttrs (builtins.concatLists (
    builtins.map (layer: let
      ws = layer.workspace;
    in [
      {
        name = "plan-${ws}";
        value = {
          description = "Plan ${ws}";
          steps = [ (mkStep layer "plan") ];
        };
      }
      {
        name = "deploy-${ws}";
        value = {
          description = "Deploy ${ws}";
          steps = [ (mkStep layer "apply") ];
        };
      }
      {
        name = "destroy-${ws}";
        value = {
          description = "Destroy ${ws}";
          steps = [ (mkStep layer "destroy") ];
        };
      }
    ]) deployableLayers
  ));

  # Topological sort: layers are already ordered by arch-synthesizer's deployment_plan()
  # but we need to respect depends_on for the DAG flow. Since constellation.json layers
  # come from the Rust topological sort, we use them as-is.

  # Composed DAG flows: plan-{prefix}-stack, deploy-{prefix}-stack, destroy-{prefix}-stack
  dagFlows = builtins.listToAttrs (builtins.map (opPair: let
    op = builtins.elemAt opPair 0;
    operation = builtins.elemAt opPair 1;
    flowName = "${op}-${prefix}-stack";
    orderedLayers = if op == "destroy"
      then lib.reverseList deployableLayers
      else deployableLayers;
  in {
    name = flowName;
    value = {
      description = "${lib.toUpper (builtins.substring 0 1 op)}${builtins.substring 1 (builtins.stringLength op) op} full ${domain} stack";
      steps = builtins.map (layer: mkStep layer operation) orderedLayers;
    };
  }) [
    ["plan" "plan"]
    ["deploy" "apply"]
    ["destroy" "destroy"]
  ]);

  # Combine all flows
  allFlows = perWorkspaceFlows // dagFlows;

  # Delegate to fleet-pangea-infra for the actual Nix plumbing
  fleetPangeaInfra = import ./fleet-pangea-infra.nix {
    inherit nixpkgs system ruby-nix substrate forge fleet pangea;
  };
  base = fleetPangeaInfra {
    inherit self name shellHookExtra devShellExtras;
    flows = allFlows;
  };

in base
