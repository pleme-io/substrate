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
#
# Module trio (NixOS + nix-darwin + home-manager): pass `module = { ... }` to
# auto-emit nixosModules.default / darwinModules.default / homeManagerModules.default.
# See substrate/lib/module-trio.nix for the spec shape. Example:
#
#   {
#     toolName = "namimado";
#     src = self;
#     module = {
#       description = "Namimado desktop browser";
#       withMcp = true; withHttp = true; withSystemDaemon = false;
#     };
#   };
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
  module ? null,
  ...
} @ args:
let
  toolArgs = builtins.removeAttrs args [ "systems" "module" ];
  flakeWrapper = import ../../util/flake-wrapper.nix { inherit nixpkgs; };
  hygiene = import ../../util/flake-hygiene.nix {
    lib = (import nixpkgs { system = "x86_64-linux"; }).lib;
  };
  pkgsLib = (import nixpkgs { system = "x86_64-linux"; }).lib;
  # Enforce flake hygiene at evaluation time — fails fast on misconfiguration.
  # In tool flakes, src = self, so src.inputs holds the flake inputs.
  _hygieneCheck =
    if args ? src && args.src ? inputs then hygiene.enforceAll args.src.inputs
    else true;

  mkPerSystem = system: let
    rustTool = import ./tool-release.nix {
      inherit system nixpkgs devenv;
      crate2nix = crate2nix.packages.${system}.default;
      fenix = if fenix != null then fenix else null;
      forge = if forge != null then forge.packages.${system}.default else null;
    };
  in rustTool toolArgs;

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
        ${toolArgs.toolName} = (mkPerSystem final.system).packages.default;
      };
    } // moduleOutputs;
  }
