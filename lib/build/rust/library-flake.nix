# Complete multi-system flake outputs for a Rust crates.io library.
# Wraps build/rust/library.nix + eachSystem + overlays + module-trio for
# zero-boilerplate consumer flakes. Companion to tool-release-flake.nix —
# the missing dual on the library side.
#
# Usage in a library flake:
#   {
#     inputs = {
#       nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-25.11";
#       crate2nix.url = "github:nix-community/crate2nix";
#       fenix.url = "github:nix-community/fenix";
#       substrate = {
#         url = "github:pleme-io/substrate";
#         inputs.nixpkgs.follows = "nixpkgs";
#       };
#     };
#     outputs = { self, nixpkgs, crate2nix, fenix, substrate, ... }:
#       (import "${substrate}/lib/rust-library-flake.nix" {
#         inherit nixpkgs crate2nix fenix;
#       }) {
#         libraryName = "shikumi";
#         src = self;
#       };
#   }
#
# Returns standard flake outputs: packages, devShells, apps, overlays.default.
# `apps` exposes the cargo-release-app surface (check-all / bump / publish /
# release / regenerate) on every system.
#
# Module trio (NixOS + nix-darwin + home-manager): pass `module = { ... }` to
# auto-emit nixosModules.default / darwinModules.default / homeManagerModules.default.
# See substrate/lib/module-trio.nix for the spec shape. Libraries rarely need
# module trios — mostly relevant when a library ships a companion CLI shim.
{
  nixpkgs,
  crate2nix,
  fenix,
  devenv ? null,
}:
{
  libraryName,
  systems ? ["aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux"],
  src,
  cargoNix ? null,
  buildInputs ? [],
  nativeBuildInputs ? [],
  crateOverrides ? {},
  extraDevInputs ? [],
  devEnvVars ? {},
  module ? null,
  ...
} @ args:
let
  flakeWrapper = import ../../util/flake-wrapper.nix { inherit nixpkgs; };
  hygiene = import ../../util/flake-hygiene.nix {
    lib = (import nixpkgs { system = "x86_64-linux"; }).lib;
  };
  pkgsLib = (import nixpkgs { system = "x86_64-linux"; }).lib;
  rustOverlayBuilder = import ./overlay.nix;
  # Enforce flake hygiene at evaluation time — fails fast on misconfiguration.
  # In library flakes, src = self, so src.inputs holds the flake inputs.
  _hygieneCheck =
    if args ? src && args.src ? inputs then hygiene.enforceAll args.src.inputs
    else true;

  baseLibraryArgs = {
    name = libraryName;
    inherit src buildInputs nativeBuildInputs crateOverrides extraDevInputs devEnvVars;
  };
  libraryArgs =
    if cargoNix != null
    then baseLibraryArgs // { inherit cargoNix; }
    else baseLibraryArgs;

  # Lightweight nixLib stub — library.nix only consumes `nixLib.rustOverlays`.
  mkNixLibStub = system: {
    rustOverlays.${system} = {
      rust = rustOverlayBuilder.mkRustOverlay { inherit fenix system; };
    };
  };

  mkPerSystem = system: let
    rustLibrary = import ./library.nix {
      inherit system nixpkgs devenv crate2nix;
      nixLib = mkNixLibStub system;
    };
  in rustLibrary libraryArgs;

  trio =
    if module == null then null
    else (import ../../module-trio.nix { lib = pkgsLib; }).mkModuleTrio (
      {
        name = module.name or libraryName;
        description = module.description or "${libraryName} Rust library";
        packageAttr = module.packageAttr or libraryName;
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
        ${libraryName} = (mkPerSystem final.system).packages.default;
      };
    } // moduleOutputs;
  }
