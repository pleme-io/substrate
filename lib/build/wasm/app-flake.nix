# ============================================================================
# WASM APP FLAKE BUILDER — Zero-boilerplate flake for Yew/WASM web apps
# ============================================================================
# Complete multi-system flake outputs for a Rust → wasm32-unknown-unknown
# Yew (or any wasm-bindgen-based) web application.
#
# Wraps mkWasmBuild + mkWasmDockerImage{,WithHanabi} + mkWasmDevShell + the
# eachSystem/overlays plumbing for zero-boilerplate consumer flakes. This is
# the missing dual to `leptosBuildFlakeBuilder` — the substrate already had
# the bare mk* primitives, but no flake-level wrapper that composed them
# the way Leptos and WASI consumers expect.
#
# Produces (per system):
#   packages.default       — wasm-bindgen-processed bundle (HTML + JS + .wasm)
#   packages.wasmApp       — same as default
#   packages.dockerImage   — Hanabi-served (preferred) or nginx-served image
#   devShells.default      — wasmToolchain + wasm-bindgen-cli + binaryen + trunk
#   apps.default           — `trunk serve` for local dev
#   overlays.default       — exposes the wasmApp at the given name
#
# Module trio: pass `module = { ... }` to auto-emit nixosModules.default /
# darwinModules.default / homeManagerModules.default. See
# substrate/lib/module-trio.nix for the spec shape.
#
# Usage in a consumer flake.nix:
#   {
#     inputs = {
#       nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
#       substrate = {
#         url = "github:pleme-io/substrate";
#         inputs.nixpkgs.follows = "nixpkgs";
#       };
#       fenix = { url = "github:nix-community/fenix"; inputs.nixpkgs.follows = "nixpkgs"; };
#       crate2nix = { url = "github:nix-community/crate2nix"; inputs.nixpkgs.follows = "nixpkgs"; };
#     };
#     outputs = { self, nixpkgs, substrate, fenix, crate2nix, ... }:
#       (import "${substrate}/lib/build/wasm/app-flake.nix" {
#         inherit nixpkgs substrate fenix crate2nix;
#       }) {
#         inherit self;
#         name = "pangea-web";
#         # Hanabi binary from a sibling crate (preferred over nginx)
#         hanabiBinary = self.packages.${builtins.head (builtins.attrNames self.packages or {})}.hanabi or null;
#       };
#   }
#
# To use the nginx-served image instead of Hanabi, omit `hanabiBinary`.
{
  nixpkgs,
  substrate ? null,
  fenix ? null,
  crate2nix ? null,
}:
{
  self,
  name,
  systems ? [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ],
  # WASM build configuration — forwarded to mkWasmBuild
  cargoNix ? null,            # Path to Cargo.nix; defaults to <src>/Cargo.nix, auto-generated if missing
  indexHtml ? null,           # Path to index.html; defaults to <src>/index.html, generated if missing
  staticAssets ? null,        # Optional static assets path
  wasmBindgenTarget ? "web",
  optimizeLevel ? 3,
  crateOverrides ? {},
  # Docker image configuration
  hanabiBinary ? null,        # If non-null, builds Hanabi-served image; else nginx
  tag ? "latest",
  architecture ? "amd64",
  port ? 80,                  # nginx-only; Hanabi uses 80/8080 fixed
  # Dev shell
  extraDevShellPackages ? [],
  # Module trio
  module ? null,
  ...
} @ args:
let
  flakeWrapper = import ../../util/flake-wrapper.nix { inherit nixpkgs; };
  pkgsLib = (import nixpkgs { system = "x86_64-linux"; }).lib;
  hygiene = import ../../util/flake-hygiene.nix { lib = pkgsLib; };

  # Enforce flake hygiene at evaluation time
  _hygieneCheck = if self ? inputs then hygiene.enforceAll self.inputs else true;

  # Resolve fenix/crate2nix from self.inputs if not passed directly — same
  # pattern as leptos-build-flake.nix.
  resolveFenix = system:
    if fenix != null then fenix.packages.${system}
    else if self ? inputs && self.inputs ? fenix then self.inputs.fenix.packages.${system}
    else throw "wasm-app-flake: fenix input required (pass directly or add to flake inputs)";

  resolveCrate2nix = system:
    if crate2nix != null then crate2nix
    else if self ? inputs && self.inputs ? crate2nix then self.inputs.crate2nix
    else throw "wasm-app-flake: crate2nix input required (pass directly or add to flake inputs)";

  trio =
    if module == null then null
    else (import ../../module-trio.nix { lib = pkgsLib; }).mkModuleTrio (
      {
        inherit name;
        description = module.description or "${name} WASM web application";
        packageAttr = module.packageAttr or name;
      } // (builtins.removeAttrs module [ "name" "description" "packageAttr" ])
    );

  moduleOutputs = if trio == null then {} else {
    homeManagerModules.default = trio.homeManagerModule;
    nixosModules.default = trio.nixosModule;
    darwinModules.default = trio.darwinModule;
  };

  mkPerSystem = system: let
    pkgs = import nixpkgs { inherit system; };
    fenixPkgs = resolveFenix system;
    crate2nixInput = resolveCrate2nix system;

    wasmModule = import ./build.nix {
      inherit pkgs;
      fenix = fenixPkgs;
      crate2nix = crate2nixInput;
    };

    wasmApp = wasmModule.mkWasmBuild ({
      inherit name wasmBindgenTarget optimizeLevel crateOverrides;
      src = self;
    } // (if cargoNix != null then { inherit cargoNix; } else {})
      // (if indexHtml != null then { inherit indexHtml; } else {})
      // (if staticAssets != null then { inherit staticAssets; } else {}));

    dockerImage =
      if hanabiBinary != null
      then wasmModule.mkWasmDockerImageWithHanabi {
        inherit name tag architecture wasmApp;
        webServer = hanabiBinary;
      }
      else wasmModule.mkWasmDockerImage {
        inherit name tag architecture port wasmApp;
      };

    devShell = wasmModule.mkWasmDevShell {
      inherit name;
      extraPackages = extraDevShellPackages;
    };
  in {
    packages = {
      default = wasmApp;
      ${name} = wasmApp;
      wasmApp = wasmApp;
      dockerImage = dockerImage;
    };

    devShells.default = devShell;

    apps.default = {
      type = "app";
      program = toString (pkgs.writeShellScript "trunk-serve-${name}" ''
        set -euo pipefail
        echo "Starting trunk serve for ${name}..."
        exec ${pkgs.trunk}/bin/trunk serve "$@"
      '');
    };
  };
in
  flakeWrapper.mkFlakeOutputs {
    inherit systems mkPerSystem;
    extraOutputs = {
      overlays.default = final: prev: {
        ${name} = (mkPerSystem final.system).packages.default;
      };
    } // moduleOutputs;
  }
