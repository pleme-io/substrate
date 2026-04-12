# ============================================================================
# LEPTOS BUILD FLAKE BUILDER - Zero-boilerplate flake for Leptos PWAs
# ============================================================================
# Complete multi-system flake outputs for a Leptos web application.
# Wraps leptos-build.nix + eachSystem + overlays for zero-boilerplate
# consumer flakes.
#
# Produces: SSR server binary, CSR WASM bundle, combined deployment package,
# Docker images (SSR or CSR-only via Hanabi), and dev shell.
#
# Usage in a consumer flake.nix:
#   {
#     inputs = {
#       nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
#       substrate = {
#         url = "github:pleme-io/substrate";
#         inputs.nixpkgs.follows = "nixpkgs";
#       };
#     };
#     outputs = { self, nixpkgs, substrate, ... }:
#       (import "${substrate}/lib/leptos-build-flake.nix" {
#         inherit nixpkgs substrate;
#       }) {
#         inherit self;
#         name = "lilitu-web";
#       };
#   }
{
  nixpkgs,
  substrate ? null,
  fenix ? null,
  crate2nix ? null,
  forge ? null,
}:
{
  self,
  name,
  systems ? [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ],
  # SSR configuration
  ssrBinaryName ? name,
  ssrFeatures ? "ssr",
  # CSR configuration
  csrFeatures ? "hydrate",
  wasmBindgenTarget ? "web",
  optimizeLevel ? 3,
  # Assets
  staticAssets ? null,
  indexHtml ? null,
  # Docker
  tag ? "latest",
  port ? 3000,
  healthPort ? 3001,
  # Module exports (set to null to skip)
  moduleDir ? null,
  # Extra build inputs
  extraNativeBuildInputs ? [],
  ...
} @ args:
let
  flakeWrapper = import ../../util/flake-wrapper.nix { inherit nixpkgs; };
  hygiene = import ../../util/flake-hygiene.nix {
    lib = (import nixpkgs { system = "x86_64-linux"; }).lib;
  };
  # Enforce flake hygiene at evaluation time
  _hygieneCheck = if self ? inputs then hygiene.enforceAll self.inputs else true;

  # Resolve fenix from self.inputs if not passed directly
  resolveFenix = system:
    if fenix != null then fenix.packages.${system}
    else if self ? inputs && self.inputs ? fenix then self.inputs.fenix.packages.${system}
    else throw "leptos-build-flake: fenix input required (pass directly or add to flake inputs)";

  # Resolve crate2nix from self.inputs if not passed directly
  resolveCrate2nix = system:
    if crate2nix != null then crate2nix.packages.${system}.default
    else if self ? inputs && self.inputs ? crate2nix then self.inputs.crate2nix.packages.${system}.default
    else null;

  mkPerSystem = system: let
    pkgs = import nixpkgs { inherit system; };
    fenixPkgs = resolveFenix system;

    leptosModule = import ./leptos-build.nix {
      inherit pkgs;
      fenix = fenixPkgs;
      crate2nix = resolveCrate2nix system;
    };

    result = leptosModule.mkLeptosBuild {
      inherit name ssrBinaryName ssrFeatures csrFeatures
              wasmBindgenTarget optimizeLevel staticAssets
              indexHtml extraNativeBuildInputs;
      src = self;
    };

    dockerImage = leptosModule.mkLeptosDockerImage {
      inherit name tag port healthPort;
      leptosBuild = result;
    };
  in {
    packages = result.packages // {
      inherit dockerImage;
    };
    devShells = {
      default = result.devShell;
    };
    apps = {
      default = {
        type = "app";
        program = "${result.combined}/bin/${ssrBinaryName}";
      };
    };
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
      // {
        overlays.default = final: prev: {
          ${name} = self.packages.${final.system}.default;
        };
      };
  }
