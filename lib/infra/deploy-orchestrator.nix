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
  deployCmd ? "bundle exec pangea apply",
  planCmd ? "bundle exec pangea plan",
  destroyCmd ? "bundle exec pangea destroy",
}:

let
  mkApp = name: text: {
    type = "app";
    program = "${pkgs.writeShellScriptBin name text}/bin/${name}";
  };

  # Per-workspace apps
  perWorkspace = builtins.listToAttrs (builtins.concatMap (ws: [
    {
      name = "deploy-${ws}";
      value = mkApp "deploy-${ws}" ''
        set -euo pipefail
        export AWS_PROFILE="${awsProfile}"
        echo "=== Deploying ${ws} ==="
        cd ${ws}
        ${deployCmd}
      '';
    }
    {
      name = "plan-${ws}";
      value = mkApp "plan-${ws}" ''
        set -euo pipefail
        export AWS_PROFILE="${awsProfile}"
        echo "=== Planning ${ws} ==="
        cd ${ws}
        ${planCmd}
      '';
    }
    {
      name = "destroy-${ws}";
      value = mkApp "destroy-${ws}" ''
        set -euo pipefail
        export AWS_PROFILE="${awsProfile}"
        echo "=== Destroying ${ws} ==="
        cd ${ws}
        ${destroyCmd}
      '';
    }
  ]) workspaces);

  # Orchestrators — run all workspaces in order
  deployAllScript = builtins.concatStringsSep "\n" (map (ws: ''
    echo "=== Deploying ${ws} ==="
    cd $src/${ws}
    ${deployCmd}
  '') workspaces);

  planAllScript = builtins.concatStringsSep "\n" (map (ws: ''
    echo "=== Planning ${ws} ==="
    cd $src/${ws}
    ${planCmd}
  '') workspaces);

  orchestrators = {
    deploy-all = mkApp "deploy-all" ''
      set -euo pipefail
      export AWS_PROFILE="${awsProfile}"
      src=$(pwd)
      ${deployAllScript}
      echo "=== All ${toString (builtins.length workspaces)} workspaces deployed ==="
    '';
    plan-all = mkApp "plan-all" ''
      set -euo pipefail
      export AWS_PROFILE="${awsProfile}"
      src=$(pwd)
      ${planAllScript}
      echo "=== All ${toString (builtins.length workspaces)} workspaces planned ==="
    '';
  };

in
  perWorkspace // orchestrators
