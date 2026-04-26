# Complete multi-system flake outputs for a Go CLI tool.
# Wraps go-tool.nix + eachSystem + overlays for zero-boilerplate
# consumer flakes.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, flake-utils, substrate, ... }:
#     (import "${substrate}/lib/go-tool-flake.nix" {
#       inherit nixpkgs;
#     }) {
#       toolName = "kubectl-tree";
#       version = "0.4.6";
#       src = self;
#       vendorHash = "sha256-...";
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
  toolArgs = builtins.removeAttrs args [ "toolName" "systems" "module" ];
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

  goToolBuilder = import ./tool.nix;

  mkPerSystem = system: let
    pkgs = import nixpkgs { inherit system; };
    package = goToolBuilder.mkGoTool pkgs ({
      pname = toolName;
    } // toolArgs);
  in {
    packages = {
      default = package;
      ${toolName} = package;
    };
    devShells = {
      default = pkgs.mkShellNoCC {
        packages = with pkgs; [ go gopls gotools ];
      };
    };
    apps = {
      default = {
        type = "app";
        program = "${package}/bin/${toolName}";
      };
    };
  };

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
        ${toolName} = (mkPerSystem final.system).packages.default;
      };
    } // moduleOutputs;
  }
