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
}:
{
  toolName,
  systems ? ["aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux"],
  ...
} @ args:
let
  # Extract args that are NOT for rust-tool-release.nix
  toolArgs = builtins.removeAttrs args [ "systems" ];

  eachSystem = f: nixpkgs.lib.genAttrs systems f;

  mkOutputs = system: let
    rustTool = import ./rust-tool-release.nix {
      inherit system nixpkgs;
      crate2nix = crate2nix.packages.${system}.default;
      fenix = if fenix != null then fenix else null;
    };
  in rustTool toolArgs;
in
{
  packages = eachSystem (system: (mkOutputs system).packages);
  devShells = eachSystem (system: (mkOutputs system).devShells);
  apps = eachSystem (system: (mkOutputs system).apps);
}
// {
  overlays.default = final: prev: {
    ${toolArgs.toolName} = (mkOutputs final.system).packages.default;
  };
}
