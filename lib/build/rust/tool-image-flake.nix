# Complete multi-system flake outputs for a Rust CLI tool packaged as a Docker image.
# Wraps rust-tool-image.nix + eachSystem + overlays for zero-boilerplate
# consumer flakes.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, crate2nix, flake-utils, substrate, forge, ... }:
#     (import "${substrate}/lib/build/rust/tool-image-flake.nix" {
#       inherit nixpkgs crate2nix flake-utils forge;
#     }) {
#       toolName = "image-sync";
#       src = self;
#       repo = "pleme-io/image-sync";
#       tag = "0.1.0";
#       extraContents = pkgs: [ pkgs.crane ];
#       architectures = ["amd64"];
#     };
#
# Apps:
#   nix run .#release  — push all arch images to ghcr.io/${repo} via forge
{
  nixpkgs,
  crate2nix,
  flake-utils,
  fenix ? null,
  devenv ? null,
  forge ? null,
}:
{
  toolName,
  systems ? ["aarch64-darwin" "x86_64-linux" "aarch64-linux"],
  ...
} @ args:
let
  toolArgs = builtins.removeAttrs args [ "systems" ];
  flakeWrapper = import ../../util/flake-wrapper.nix { inherit nixpkgs; };

  mkPerSystem = system: let
    rustToolImage = import ./tool-image.nix {
      inherit system nixpkgs devenv;
      crate2nix = crate2nix.packages.${system}.default;
      fenix = if fenix != null then fenix else null;
      forge = if forge != null then forge.packages.${system}.default else null;
    };
  in rustToolImage toolArgs;
in
  flakeWrapper.mkFlakeOutputs {
    inherit systems mkPerSystem;
    extraOutputs = {
      overlays.default = final: prev: {
        ${toolArgs.toolName} = (mkPerSystem final.system).packages.default;
      };
    };
  }
