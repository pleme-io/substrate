# Complete multi-system flake outputs for a Fleet + Pangea infrastructure project.
# Wraps fleet-pangea-infra.nix + eachSystem for zero-boilerplate consumer flakes.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, ruby-nix, flake-utils, substrate, forge, fleet, pangea, ... }:
#     (import "${substrate}/lib/fleet-pangea-infra-flake.nix" {
#       inherit nixpkgs ruby-nix flake-utils substrate forge fleet pangea;
#     }) {
#       inherit self;
#       name = "my-infra";
#       flows = {
#         deploy = { description = "Deploy infra"; steps = [ ... ]; };
#       };
#     };
# Complete multi-system flake outputs for a Fleet + Pangea infrastructure project.
# Wraps fleet-pangea-infra.nix + eachSystem for zero-boilerplate consumer flakes.
#
# Optional `renderer` input: a flake providing a binary that generates workspace
# files from proven types. When provided, adds `render` and `prove` apps to the
# output alongside the standard fleet flows.
#
# The renderer binary contract:
#   <renderer> <domain> <output_dir> [--verify]
#   - <domain>: infrastructure domain (e.g., "quero.lol")
#   - <output_dir>: path to write workspace files
#   - --verify: check generated matches disk (drift detection)
#
# The prover binary contract:
#   Runs `cargo test` on the type system crate. Exits non-zero on failure.
#
# Usage:
#   outputs = (import "${substrate}/lib/fleet-pangea-infra-flake.nix" {
#     inherit nixpkgs ruby-nix flake-utils substrate forge fleet;
#     renderer = pangea-forge;  # optional: adds render/prove/sdlc apps
#   }) {
#     inherit self;
#     name = "my-infra";
#     domain = "example.com";  # optional: for renderer
#     flows = { ... };
#   };
{
  nixpkgs,
  ruby-nix,
  flake-utils,
  substrate,
  forge,
  fleet ? null,
  pangea ? null,
  renderer ? null,
  prover ? null,
}:
{
  name,
  self,
  flows ? {},
  domain ? null,
  systems ? ["x86_64-linux" "aarch64-linux" "aarch64-darwin"],
  shellHookExtra ? "",
  devShellExtras ? [],
}:
  flake-utils.lib.eachSystem systems (system:
    let
      base = (import ./fleet-pangea-infra.nix {
        inherit nixpkgs system ruby-nix substrate forge fleet pangea;
      }) {
        inherit self name flows shellHookExtra devShellExtras;
      };

      pkgs = import nixpkgs { inherit system; };

      # Renderer apps (only when renderer flake is provided)
      rendererApps = if renderer != null && domain != null then let
        rendererBin = "${renderer.packages.${system}.default}/bin/pangea_render";
      in {
        render = {
          type = "app";
          program = toString (pkgs.writeShellScript "${name}-render" ''
            set -euo pipefail
            REPO_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
            cd "$REPO_ROOT"
            echo "[sdlc] Rendering ${domain} → workspaces/"
            ${rendererBin} ${domain} "$REPO_ROOT/workspaces"
          '');
        };
        verify = {
          type = "app";
          program = toString (pkgs.writeShellScript "${name}-verify-render" ''
            set -euo pipefail
            REPO_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
            cd "$REPO_ROOT"
            echo "[sdlc] Verifying ${domain} render matches disk"
            ${rendererBin} ${domain} "$REPO_ROOT/workspaces" --verify
          '');
        };
      } else {};

      # Prover apps (only when prover flake is provided)
      proverApps = if prover != null then {
        prove = {
          type = "app";
          program = toString (pkgs.writeShellScript "${name}-prove" ''
            set -euo pipefail
            echo "[sdlc] Proving infrastructure types"
            ${prover.packages.${system}.default}/bin/cargo-test-wrapper
          '');
        };
      } else {};

    in {
      inherit (base) devShells;
      apps = base.apps // rendererApps // proverApps;
    }
  )
