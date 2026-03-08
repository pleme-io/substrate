# Complete multi-system flake outputs for a Rust CLI tool.
# Wraps rust-tool-release.nix + eachSystem + overlays for zero-boilerplate
# consumer flakes.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, crate2nix, flake-utils, substrate, ... }:
#     (import "${substrate}/lib/rust-tool-release-flake.nix" {
#       inherit nixpkgs crate2nix flake-utils;
#     }) {
#       toolName = "kindling";
#       src = self;
#       repo = "pleme-io/kindling";
#     };
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
  systems ? ["aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux"],
  ...
} @ args:
let
  toolArgs = builtins.removeAttrs args [ "systems" ];
  flakeWrapper = import ./flake-wrapper.nix { inherit nixpkgs; };

  mkPerSystem = system: let
    rustTool = import ./rust-tool-release.nix {
      inherit system nixpkgs devenv;
      crate2nix = crate2nix.packages.${system}.default;
      fenix = if fenix != null then fenix else null;
      forge = if forge != null then forge.packages.${system}.default else null;
    };
  in rustTool toolArgs;
in
  flakeWrapper.mkFlakeOutputs {
    inherit systems mkPerSystem;
    extraOutputs = {
      overlays.default = final: prev: {
        ${toolArgs.toolName} = (mkPerSystem final.system).packages.default;
      };
    };
  }
