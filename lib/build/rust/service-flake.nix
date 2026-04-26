# Complete multi-system flake outputs for a Rust service.
# Wraps rust-service.nix + eachSystem + homeManagerModules + nixosModules + overlays
# for zero-boilerplate consumer flakes.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, fenix, substrate, forge, crate2nix, ... }:
#     (import "${substrate}/lib/rust-service-flake.nix" {
#       inherit nixpkgs substrate forge crate2nix;
#     }) {
#       inherit self;
#       serviceName = "hanabi";
#       registry = "ghcr.io/pleme-io/hanabi";
#     };
{
  nixpkgs,
  substrate,
  forge,
  crate2nix,
  devenv ? null,
}:
{
  self,
  serviceName,
  systems ? ["aarch64-darwin" "x86_64-linux" "aarch64-linux"],
  # Module exports (set to null to skip)
  moduleDir ? ./module,
  nixosModuleFile ? ./module/nixos.nix,
  module ? null,
  # All remaining args forwarded to rust-service.nix
  ...
} @ args:
let
  serviceArgs = builtins.removeAttrs args [
    "self" "systems" "moduleDir" "nixosModuleFile" "module"
  ];
  flakeWrapper = import ../../util/flake-wrapper.nix { inherit nixpkgs; };
  hygiene = import ../../util/flake-hygiene.nix {
    lib = (import nixpkgs { system = "x86_64-linux"; }).lib;
  };
  pkgsLib = (import nixpkgs { system = "x86_64-linux"; }).lib;
  # Enforce flake hygiene at evaluation time — fails fast on misconfiguration.
  # Pass self.inputs if available (flake context), otherwise skip gracefully.
  _hygieneCheck = if self ? inputs then hygiene.enforceAll self.inputs else true;

  mkPerSystem = system: let
    rustService = import ./service.nix {
      inherit system nixpkgs devenv;
      nixLib = substrate;
      crate2nix = crate2nix.packages.${system}.default;
      forge = forge.packages.${system}.default;
    };
  in rustService (serviceArgs // { src = self; });

  trio =
    if module == null then null
    else (import ../../module-trio.nix { lib = pkgsLib; }).mkModuleTrio (
      {
        name = module.name or serviceName;
        description = module.description or "${serviceName} service";
        packageAttr = module.packageAttr or serviceName;
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
    extraOutputs =
      (if moduleDir != null then {
        homeManagerModules.default = import (self + "/module") {
          hmHelpers = import ../../hm/service-helpers.nix { lib = nixpkgs.lib; };
        };
      } else {})
      // (if nixosModuleFile != null then {
        nixosModules.default = import (self + "/module/nixos.nix");
      } else {})
      // {
        overlays.default = final: prev: {
          ${serviceName} = self.packages.${final.system}.default;
        };
      }
      // moduleOutputs;
  }
