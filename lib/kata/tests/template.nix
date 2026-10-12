{
  lib,
  iroha,
  kata,
}:
let
  templateDir = ../../../templates/fleet;
  blanks = import (templateDir + "/fleet.nix");

  layoutFiles = [
    "flake.nix"
    "fleet.nix"
    "CLAUDE.md"
    "README.md"
    "kijun.b"
    ".sops.yaml"
    ".gitignore"
    ".github/workflows/checks.yml"
    "docs/README.md"
    "lib/fleet.nix"
    "lib/node-layers.nix"
    "lib/nodes.nix"
    "lib/darwin-nodes.nix"
    "modules/pleme/nixos/default.nix"
    "modules/pleme/darwin/default.nix"
    "profiles/server-base.nix"
    "parts/fleet.nix"
    "parts/nixos.nix"
    "parts/darwin.nix"
    "parts/deploy.nix"
    "parts/proofs.nix"
    "parts/canonical.nix"
  ];

  nodeFiles =
    name: class:
    [
      "nodes/${name}/default.nix"
      "nodes/${name}/layers.nix"
      "nodes/${name}/configuration.nix"
    ]
    ++ lib.optional (class == "nixos") "nodes/${name}/hardware-configuration.nix";

  sharedSurfaces = map (lib.removeSuffix ".nix") (
    builtins.filter (f: f != "default.nix") (
      builtins.attrNames (builtins.readDir (templateDir + "/modules/pleme/shared"))
    )
  );

  surfaceFiles = s: [ "parts/${s}.nix" ];

  conceptSource = s: builtins.readFile (templateDir + "/modules/pleme/shared/${s}.nix");

  kindOf =
    s:
    let
      m = builtins.match ''.*kind = "([a-z]+)";.*'' (lib.replaceStrings [ "\n" ] [ " " ] (conceptSource s));
    in
    if m == null then "binary" else builtins.head m;

  aggregatorNames =
    platform: builtins.readFile (templateDir + "/modules/pleme/${platform}/default.nix");

  missing = builtins.filter (f: !(builtins.pathExists (templateDir + "/${f}"))) (
    layoutFiles
    ++ lib.concatLists (lib.mapAttrsToList (n: v: nodeFiles n v.class) blanks.nodes)
    ++ lib.concatMap surfaceFiles sharedSurfaces
  );

  stubInputs = {
    nixpkgs.lib = lib;
    sops-nix = {
      nixosModules.sops = "sops-nixos";
      darwinModules.sops = "sops-darwin";
    };
    substrate = {
      inherit kata iroha;
      moduleTrio = import ../../module-trio.nix { inherit lib; };
    };
  };

  f = import (templateDir + "/lib/fleet.nix") {
    inputs = stubInputs;
    universes = {
      nixosSystem = args: {
        kind = "nixos";
        inherit args;
      };
      darwinSystem = args: {
        kind = "darwin";
        inherit args;
      };
    };
  };
  nodes = import (templateDir + "/lib/nodes.nix") { inputs = stubInputs; };

  selectionOf =
    name:
    (import (templateDir + "/nodes/${name}/default.nix") {
      inputs = stubInputs;
      inherit lib;
    }).imports;
  publishedOf =
    name:
    (lib.evalModules { modules = [ (builtins.head (selectionOf name)) ]; }).config.kata.nodeLayers;

  workflow = builtins.readFile (templateDir + "/.github/workflows/checks.yml");
  claude = builtins.readFile (templateDir + "/CLAUDE.md");
in
{
  template-layout-is-complete = {
    expr = missing;
    expected = [ ];
  };
  template-has-a-shared-surface = {
    expr = sharedSurfaces != [ ];
    expected = true;
  };
  every-shared-concept-is-declared-through-the-trio = {
    expr = builtins.filter (s: !(lib.hasInfix "mkModuleTrio" (conceptSource s))) sharedSurfaces;
    expected = [ ];
  };
  the-template-ships-a-binary-a-package-and-a-registry = {
    expr = lib.sort lib.lessThan (map kindOf sharedSurfaces);
    expected = [
      "binary"
      "package"
      "registry"
    ];
  };
  every-concept-is-imported-by-both-platform-aggregators = {
    expr = lib.genAttrs [ "nixos" "darwin" ] (
      p: builtins.filter (s: !(lib.hasInfix "../shared/${s}.nix" (aggregatorNames p))) sharedSurfaces
    );
    expected = {
      nixos = [ ];
      darwin = [ ];
    };
  };
  blanks-validate = {
    expr = f.config.name;
    expected = "example";
  };
  fleet-assembles = {
    expr = {
      nixos = builtins.attrNames f.nixosConfigurations;
      darwin = builtins.attrNames f.darwinConfigurations;
    };
    expected = {
      nixos = [ "alpha" ];
      darwin = [ "beta" ];
    };
  };
  template-invariants-pass = {
    expr =
      (iroha.mkEvalChecks {
        name = "tpl";
        tests = f.invariants;
      }).passed;
    expected = true;
  };
  template-deploy-data = {
    expr = f.deployRs.nodes.alpha.sshUser;
    expected = "admin";
  };
  template-darwin-node-is-local-only = {
    expr = f.deployRs.nodes ? beta;
    expected = false;
  };
  every-nixos-node-declared-through-mknode = {
    expr = builtins.attrNames nodes;
    expected = lib.attrNames (lib.filterAttrs (_: n: n.class == "nixos") blanks.nodes);
  };
  mknode-hostname-is-the-fleet-fqdn = {
    expr = nodes.alpha.hostname;
    expected = f.domains.fqdn "alpha";
  };
  mknode-stack-ends-with-the-node-dir = {
    expr = lib.last nodes.alpha.modules;
    expected = templateDir + "/nodes/alpha";
  };
  nodes-select-base-through-kata = {
    expr = lib.mapAttrs (n: _: (publishedOf n).selected) blanks.nodes;
    expected = {
      alpha = [
        "base"
        "server"
      ];
      beta = [ "base" ];
    };
  };
  checks-workflow-calls-the-fleet-workflow = {
    expr = lib.hasInfix "pleme-io/substrate/.github/workflows/nix-fleet.yml@main" workflow;
    expected = true;
  };
  checks-workflow-runs-on-the-private-pool = {
    expr = lib.hasInfix "runner-labels: '[\"self-hosted\",\"pleme-private\"]'" workflow;
    expected = true;
  };
  kijun-config-declares-fleet-repo-v1 = {
    expr = lib.hasInfix "fleet_repo(1)" (builtins.readFile (templateDir + "/kijun.b"));
    expected = true;
  };
  claude-md-points-at-kijun-rules = {
    expr = lib.hasInfix "kijun rules" claude;
    expected = true;
  };
}
