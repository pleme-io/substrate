# Complete multi-system flake outputs for a Zig CLI tool.
# Wraps zig-tool-release.nix + eachSystem + overlays for zero-boilerplate
# consumer flakes.
#
# Zig has built-in cross-compilation, so all 4 targets are built on the host
# system — no remote builders, no fenix, no crate2nix needed.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, substrate, ... }:
#     (import "${substrate}/lib/zig-tool-release-flake.nix" {
#       inherit nixpkgs;
#     }) {
#       toolName = "z9s";
#       src = self;
#       repo = "drzln/z9s";
#     };
{
  nixpkgs,
}:
{
  toolName,
  systems ? ["aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux"],
  ...
} @ args:
let
  toolArgs = builtins.removeAttrs args [ "systems" ];

  eachSystem = f: nixpkgs.lib.genAttrs systems f;

  mkOutputs = system: let
    zigTool = import ./zig-tool-release.nix {
      inherit system nixpkgs;
    };
  in zigTool toolArgs;
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
