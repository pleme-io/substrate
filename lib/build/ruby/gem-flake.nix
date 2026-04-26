# Complete multi-system flake outputs for a Ruby gem library.
# Wraps ruby-gem.nix + eachSystem for zero-boilerplate consumer flakes.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, ruby-nix, flake-utils, substrate, forge, ... }:
#     (import "${substrate}/lib/ruby-gem-flake.nix" {
#       inherit nixpkgs ruby-nix flake-utils substrate forge;
#     }) {
#       inherit self;
#       name = "pangea-core";
#     };
#
# Module trio (NixOS + nix-darwin + home-manager): pass `module = { ... }` to
# auto-emit nixosModules.default / darwinModules.default / homeManagerModules.default.
# See substrate/lib/module-trio.nix for the spec shape.
{
  nixpkgs,
  ruby-nix,
  flake-utils,
  substrate,
  forge,
}:
{
  name,
  self,
  systems ? ["x86_64-linux" "aarch64-linux" "aarch64-darwin"],
  shellHookExtra ? "",
  devShellExtras ? [],
  module ? null,
}:
let
  pkgsLib = (import nixpkgs { system = "x86_64-linux"; }).lib;
  hygiene = import ../../util/flake-hygiene.nix {
    lib = pkgsLib;
  };
  # Enforce flake hygiene at evaluation time — fails fast on misconfiguration.
  _hygieneCheck = if self ? inputs then hygiene.enforceAll self.inputs else true;

  trio =
    if module == null then null
    else (import ../../module-trio.nix { lib = pkgsLib; }).mkModuleTrio (
      {
        name = module.name or name;
        description = module.description or "${name} Ruby gem";
        packageAttr = module.packageAttr or name;
      } // (builtins.removeAttrs module [ "name" "description" "packageAttr" ])
    );

  moduleOutputs = if trio == null then {} else {
    homeManagerModules.default = trio.homeManagerModule;
    nixosModules.default = trio.nixosModule;
    darwinModules.default = trio.darwinModule;
  };
in
  (flake-utils.lib.eachSystem systems (system:
    (import ./gem.nix {
      inherit nixpkgs system ruby-nix substrate forge;
    }) {
      inherit self name shellHookExtra devShellExtras;
    }
  )) // moduleOutputs
