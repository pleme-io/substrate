# Complete multi-system flake outputs for a Rust workspace CLI tool.
# Wraps workspace-release.nix + eachSystem + overlays for zero-boilerplate
# consumer flakes.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, crate2nix, flake-utils, substrate, ... }:
#     (import "${substrate}/lib/rust-workspace-release-flake.nix" {
#       inherit nixpkgs crate2nix flake-utils;
#     }) {
#       toolName = "mamorigami";         # binary name
#       packageName = "mamorigami-cli";  # workspace member crate
#       src = self;
#       repo = "pleme-io/mamorigami";
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
  packageName,
  systems ? ["aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux"],
  ...
} @ args:
let
  workspaceArgs = builtins.removeAttrs args [ "systems" ];
  flakeWrapper = import ../../util/flake-wrapper.nix { inherit nixpkgs; };

  mkPerSystem = system: let
    rustWorkspace = import ./workspace-release.nix {
      inherit system nixpkgs devenv;
      crate2nix = crate2nix.packages.${system}.default;
      fenix = if fenix != null then fenix else null;
      forge = if forge != null then forge.packages.${system}.default else null;
    };
  in rustWorkspace workspaceArgs;
in
  flakeWrapper.mkFlakeOutputs {
    inherit systems mkPerSystem;
    extraOutputs = {
      overlays.default = final: prev: {
        ${workspaceArgs.toolName} = (mkPerSystem final.system).packages.default;
      };
    };
  }
