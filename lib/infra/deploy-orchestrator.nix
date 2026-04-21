# Deploy orchestrator — generates nix run apps for workspace-ordered deployment.
#
# Given a list of workspace names in dependency order, produces:
#   deploy-{ws}  — deploy a single workspace
#   plan-{ws}    — plan a single workspace (dry run)
#   deploy-all   — deploy ALL workspaces in order
#   plan-all     — plan ALL workspaces in order
#
# Usage in a flake:
#   deployApps = (import "${substrate}/lib/infra/deploy-orchestrator.nix" {
#     inherit pkgs;
#   }) {
#     workspaces = ["quero-iam" "quero-state" "quero-dns" "quero-vpc" ...];
#     awsProfile = "akeyless-development";
#   };
#
# Then merge: apps = pangeaOutputs.apps.${system} // amiApps // deployApps;

{ pkgs }:

{
  workspaces,
  awsProfile ? "default",
  # Commands run INSIDE nix develop from each workspace directory.
  # Default uses `pangea bulk …` which walks every .rb in the dir —
  # matches what every quero-* workspace actually needs. Bare
  # `pangea plan` would require a specific template filename, which
  # the orchestrator can't know without per-workspace config.
  deployCmd ? "pangea bulk apply --dir .",
  planCmd ? "pangea bulk plan --dir .",
  destroyCmd ? "pangea bulk destroy --dir .",
}:

let
  mkApp = name: text: {
    type = "app";
    program = "${pkgs.writeShellScriptBin name text}/bin/${name}";
  };

  # Per-workspace apps — run nix develop from root, cd into workspace
  perWorkspace = builtins.listToAttrs (builtins.concatMap (ws: [
    {
      name = "deploy-${ws}";
      value = mkApp "deploy-${ws}" ''
        set -euo pipefail
        export AWS_PROFILE="${awsProfile}"
        echo "=== Deploying ${ws} ==="
        exec nix develop --impure --command bash -c "cd ${ws} && ${deployCmd}"
      '';
    }
    {
      name = "plan-${ws}";
      value = mkApp "plan-${ws}" ''
        set -euo pipefail
        export AWS_PROFILE="${awsProfile}"
        echo "=== Planning ${ws} ==="
        exec nix develop --impure --command bash -c "cd ${ws} && ${planCmd}"
      '';
    }
    {
      name = "destroy-${ws}";
      value = mkApp "destroy-${ws}" ''
        set -euo pipefail
        export AWS_PROFILE="${awsProfile}"
        echo "=== Destroying ${ws} ==="
        exec nix develop --impure --command bash -c "cd ${ws} && ${destroyCmd}"
      '';
    }
  ]) workspaces);

  # Orchestrators — run all workspaces in order via nix develop
  deployAllScript = builtins.concatStringsSep " && " (map (ws: ''
    echo "=== Deploying ${ws} ===" && cd ${ws} && ${deployCmd} && cd ..'') workspaces);

  planAllScript = builtins.concatStringsSep " && " (map (ws: ''
    echo "=== Planning ${ws} ===" && cd ${ws} && ${planCmd} && cd ..'') workspaces);

  orchestrators = {
    deploy-all = mkApp "deploy-all" ''
      set -euo pipefail
      export AWS_PROFILE="${awsProfile}"
      exec nix develop --impure --command bash -c '${deployAllScript} && echo "=== All ${toString (builtins.length workspaces)} workspaces deployed ==="'
    '';
    plan-all = mkApp "plan-all" ''
      set -euo pipefail
      export AWS_PROFILE="${awsProfile}"
      exec nix develop --impure --command bash -c '${planAllScript} && echo "=== All ${toString (builtins.length workspaces)} workspaces planned ==="'
    '';
  };

in
  perWorkspace // orchestrators
