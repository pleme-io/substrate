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
#
# Module trio (NixOS + nix-darwin + home-manager): pass `module = { ... }` to
# auto-emit nixosModules.default / darwinModules.default / homeManagerModules.default.
# See substrate/lib/module-trio.nix for the spec shape.
{
  nixpkgs,
}:
{
  toolName,
  systems ? ["aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux"],
  module ? null,
  ...
} @ args:
let
  toolArgs = builtins.removeAttrs args [ "systems" "module" ];
  flakeWrapper = import ../../util/flake-wrapper.nix { inherit nixpkgs; };
  pkgsLib = (import nixpkgs { system = "x86_64-linux"; }).lib;
  hygiene = import ../../util/flake-hygiene.nix {
    lib = pkgsLib;
  };
  # Enforce flake hygiene at evaluation time — fails fast on misconfiguration.
  # In tool flakes, src = self, so src.inputs holds the flake inputs.
  _hygieneCheck =
    if args ? src && args.src ? inputs then hygiene.enforceAll args.src.inputs
    else true;

  mkPerSystem = system: let
    zigTool = import ./tool-release.nix {
      inherit system nixpkgs;
    };
  in zigTool toolArgs;

  trio =
    if module == null then null
    else (import ../../module-trio.nix { lib = pkgsLib; }).mkModuleTrio (
      {
        name = module.name or toolName;
        description = module.description or "${toolName} CLI tool";
        packageAttr = module.packageAttr or toolName;
      } // (builtins.removeAttrs module [ "name" "description" "packageAttr" ])
    );

  moduleOutputs = if trio == null then {} else {
    homeManagerModules.default = trio.homeManagerModule;
    nixosModules.default = trio.nixosModule;
    darwinModules.default = trio.darwinModule;
  };
in
  flakeWrapper.mkFlakeOutputs {
    inherit systems mkPerSystem;
    extraOutputs = {
      overlays.default = final: prev: {
        ${toolArgs.toolName} = (mkPerSystem final.stdenv.hostPlatform.system).packages.default;
      };
    } // moduleOutputs;
  }
