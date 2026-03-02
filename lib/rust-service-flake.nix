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
}:
{
  self,
  serviceName,
  systems ? ["aarch64-darwin" "x86_64-linux" "aarch64-linux"],
  # Module exports (set to null to skip)
  moduleDir ? ./module,
  nixosModuleFile ? ./module/nixos.nix,
  # All remaining args forwarded to rust-service.nix
  ...
} @ args:
let
  serviceArgs = builtins.removeAttrs args [
    "self" "systems" "moduleDir" "nixosModuleFile"
  ];
  flakeWrapper = import ./flake-wrapper.nix { inherit nixpkgs; };

  mkPerSystem = system: let
    rustService = import ./rust-service.nix {
      inherit system nixpkgs;
      nixLib = substrate;
      crate2nix = crate2nix.packages.${system}.default;
      forge = forge.packages.${system}.default;
    };
  in rustService (serviceArgs // { src = self; });
in
  flakeWrapper.mkFlakeOutputs {
    inherit systems mkPerSystem;
    extraOutputs =
      (if moduleDir != null then {
        homeManagerModules.default = import (self + "/module") {
          hmHelpers = import ./hm-service-helpers.nix { lib = nixpkgs.lib; };
        };
      } else {})
      // (if nixosModuleFile != null then {
        nixosModules.default = import (self + "/module/nixos.nix");
      } else {})
      // {
        overlays.default = final: prev: {
          ${serviceName} = self.packages.${final.system}.default;
        };
      };
  }
