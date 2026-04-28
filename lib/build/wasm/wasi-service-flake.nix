# Complete multi-system flake outputs for a WASI service.
# Wraps wasi-service.nix + eachSystem + overlays for zero-boilerplate
# consumer flakes. Includes flake-hygiene enforcement.
#
# Docker image contains wasmtime (native binary) running the compiled
# wasm32-wasip2 module. Architecture is always the native host platform.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, fenix, substrate, ... }:
#     (import "${substrate}/lib/wasi-service-flake.nix" {
#       inherit nixpkgs substrate fenix;
#     }) {
#       inherit self;
#       serviceName = "my-wasi-service";
#       wasiCapabilities = [ "network" "env" ];
#     };
#
# Produces: packages.default (Docker image), devShells.default, overlays.default
#
# Module trio (NixOS + nix-darwin + home-manager): pass `module = { ... }` to
# auto-emit nixosModules.default / darwinModules.default / homeManagerModules.default.
# See substrate/lib/module-trio.nix for the spec shape.
{
  nixpkgs,
  substrate,
  fenix,
}:
{
  self,
  serviceName,
  systems ? [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ],
  module ? null,
  # All remaining args forwarded to wasi-service.nix
  ...
} @ args:
let
  serviceArgs = builtins.removeAttrs args [
    # Wrapper-level args that wasi-service.nix doesn't accept and
    # would reject as unknown. wasi-service.nix expects: name, src,
    # plus build-shape attrs (wasiCapabilities, dockerImageConfig,
    # crateNixOverrides, ...).
    "self" "systems" "module" "serviceName"
  ];
  flakeWrapper = import ../../util/flake-wrapper.nix { inherit nixpkgs; };
  pkgsLib = (import nixpkgs { system = "x86_64-linux"; }).lib;
  hygiene = import ../../util/flake-hygiene.nix {
    lib = pkgsLib;
  };
  # Enforce flake hygiene at evaluation time — fails fast on misconfiguration.
  # Pass self.inputs if available (flake context), otherwise skip gracefully.
  _hygieneCheck = if self ? inputs then hygiene.enforceAll self.inputs else true;

  trio =
    if module == null then null
    else (import ../../module-trio.nix { lib = pkgsLib; }).mkModuleTrio (
      {
        name = module.name or serviceName;
        description = module.description or "${serviceName} WASI service";
        packageAttr = module.packageAttr or serviceName;
      } // (builtins.removeAttrs module [ "name" "description" "packageAttr" ])
    );

  moduleOutputs = if trio == null then {} else {
    homeManagerModules.default = trio.homeManagerModule;
    nixosModules.default = trio.nixosModule;
    darwinModules.default = trio.darwinModule;
  };

  mkPerSystem = system: let
    fenixPkgs = fenix.packages.${system};
    pkgs = import nixpkgs { inherit system; };

    wasiService = import ./wasi-service.nix {
      inherit pkgs;
      fenix = fenixPkgs;
    };

    result = wasiService (serviceArgs // {
      name = serviceName;
      src = self;
    });
  in {
    packages = {
      default = result.dockerImage;
      dockerImage = result.dockerImage;
      wasmModule = result.wasmModule;
    };

    devShells = {
      default = result.devShell;
    };

    apps = {
      default = {
        type = "app";
        program = toString (pkgs.writeShellScript "run-${serviceName}" ''
          set -euo pipefail
          echo "Running ${serviceName} via wasmtime..."
          ${pkgs.wasmtime}/bin/wasmtime run \
            ${builtins.concatStringsSep " " (map (cap: "--wasi inherit-${cap}") (serviceArgs.wasiCapabilities or [ "network" "env" ]))} \
            ${result.wasmModule}/lib/${serviceName}.wasm "$@"
        '');
      };
    };
  };
in
  flakeWrapper.mkFlakeOutputs {
    inherit systems mkPerSystem;
    extraOutputs = {
      overlays.default = final: prev: {
        ${serviceName} = (mkPerSystem final.system).packages.default;
      };
    } // moduleOutputs;
  }
