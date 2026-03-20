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
  flakeWrapper = import ../../util/flake-wrapper.nix { inherit nixpkgs; };

  mkPerSystem = system: let
    zigTool = import ./tool-release.nix {
      inherit system nixpkgs;
    };
  in zigTool toolArgs;
in
  flakeWrapper.mkFlakeOutputs {
    inherit systems mkPerSystem;
    extraOutputs = {
      overlays.default = final: prev: {
        ${toolArgs.toolName} = (mkPerSystem final.system).packages.default;
      };
    };
  }
