# ============================================================================
# CLOUDFLARE-PAGES-DEPLOY — `wrangler pages deploy` wrapped as a Nix app
# ============================================================================
#
# Small helper that exposes a consistent `nix run .#pages-deploy` across
# every pleme-io static-site consumer. Pure wrapper over wrangler; no build
# logic. Meant to compose with `rust-static-site-flake.nix` which produces
# `dist/`.
#
# Usage inside a consumer flake's `mkPerSystem`:
#
#   let pagesDeploy = import "${substrate}/lib/build/web/cloudflare-pages-deploy.nix" {
#         inherit pkgs;
#       };
#   in {
#     apps.pages-deploy = pagesDeploy.mkDeployApp {
#       projectName = "zuihitsu";
#       distDir = "dist";
#       branch = "main";
#     };
#   }

{ pkgs }:

{
  # Build a `{ type = "app"; program = ...; }` value for a consumer flake.
  mkDeployApp = {
    projectName,
    distDir ? "dist",
    branch ? "main",
    extraArgs ? "",
  }: {
    type = "app";
    program = "${pkgs.writeShellScriptBin "${projectName}-pages-deploy" ''
      set -euo pipefail
      if [[ ! -d "${distDir}" ]]; then
        echo "no ${distDir}/ — run your generator first (e.g. nix run .#generate)" >&2
        exit 1
      fi
      export PATH=${pkgs.lib.makeBinPath [ pkgs.nodejs_20 pkgs.nodePackages.wrangler ]}:$PATH
      exec wrangler pages deploy "${distDir}" \
        --project-name="${projectName}" \
        --branch="${branch}" \
        ${extraArgs} "$@"
    ''}/bin/${projectName}-pages-deploy";
  };

  # Same wrapper but hooked into a `dist` derivation path rather than an
  # in-tree directory — useful when generating in the Nix sandbox is
  # someday feasible.
  mkDeployAppFromDrv = {
    projectName,
    distDrv,
    branch ? "main",
    extraArgs ? "",
  }: {
    type = "app";
    program = "${pkgs.writeShellScriptBin "${projectName}-pages-deploy-drv" ''
      set -euo pipefail
      export PATH=${pkgs.lib.makeBinPath [ pkgs.nodejs_20 pkgs.nodePackages.wrangler ]}:$PATH
      exec wrangler pages deploy "${distDrv}" \
        --project-name="${projectName}" \
        --branch="${branch}" \
        ${extraArgs} "$@"
    ''}/bin/${projectName}-pages-deploy-drv";
  };

  # Deploy hook trigger — useful for webhooks where you have a Pages Deploy
  # Hook URL (Pages settings → Deploys → Deploy hooks) and want to invoke
  # it from CLI / CI. Token is read from env CLOUDFLARE_API_TOKEN.
  mkDeployHookApp = {
    hookUrl,
    label ? "hook",
  }: {
    type = "app";
    program = "${pkgs.writeShellScriptBin "cfp-deploy-${label}" ''
      set -euo pipefail
      exec ${pkgs.curl}/bin/curl -fsS -X POST "${hookUrl}"
    ''}/bin/cfp-deploy-${label}";
  };
}
