# Complete multi-system flake outputs for a TypeScript CLI tool.
# Wraps build/typescript/tool.nix's `mkTypescriptTool` + per-system aggregation
# + module-trio for zero-boilerplate consumer flakes.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, flake-utils, substrate, ... }:
#     (import "${substrate}/lib/typescript-tool-flake.nix" {
#       inherit nixpkgs flake-utils;
#     }) {
#       toolName = "curupira-mcp";
#       src = self;
#       cliEntry = "cli.js";
#       binName = "curupira-mcp";
#       plemeLinkerSrc = inputs.pleme-linker;
#     };
#
# Module trio (NixOS + nix-darwin + home-manager): pass `module = { ... }` to
# auto-emit nixosModules.default / darwinModules.default / homeManagerModules.default.
# See substrate/lib/module-trio.nix for the spec shape. Example:
#
#   {
#     toolName = "curupira-mcp";
#     src = self;
#     cliEntry = "cli.js";
#     binName = "curupira-mcp";
#     plemeLinkerSrc = inputs.pleme-linker;
#     module = {
#       description = "Curupira MCP server";
#       withMcp = true;
#     };
#   };
{
  nixpkgs,
  flake-utils ? null,
}:
{
  toolName,
  systems ? ["aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux"],
  src,
  cliEntry ? "cli.js",
  binName ? toolName,
  plemeLinker ? null,
  plemeLinkerSrc ? null,
  parentTsconfig ? null,
  workspaceDeps ? {},
  packageAttr ? toolName,
  module ? null,
  ...
} @ args:
let
  flakeWrapper = import ./util/flake-wrapper.nix { inherit nixpkgs; };
  pkgsLib = (import nixpkgs { system = "x86_64-linux"; }).lib;

  mkPerSystem = system: let
    pkgs = import nixpkgs { inherit system; };
    tsTool = import ./build/typescript/tool.nix { inherit pkgs; };

    resolvedLinker =
      if plemeLinker != null then plemeLinker
      else if plemeLinkerSrc != null then tsTool.mkPlemeLinker { inherit plemeLinkerSrc; }
      else throw "typescript-tool-flake: must pass either `plemeLinker` or `plemeLinkerSrc`";

    package = tsTool.mkTypescriptTool {
      name = toolName;
      inherit src cliEntry binName parentTsconfig workspaceDeps;
      plemeLinker = resolvedLinker;
    };
  in {
    packages = {
      default = package;
      ${packageAttr} = package;
    };

    devShells.default = pkgs.mkShell {
      nativeBuildInputs = [
        pkgs.nodejs_20
        resolvedLinker
      ];
    };

    apps.default = {
      type = "app";
      program = "${package}/bin/${binName}";
    };
  };

  trio =
    if module == null then null
    else (import ./module-trio.nix { lib = pkgsLib; }).mkModuleTrio (
      {
        name = module.name or toolName;
        description = module.description or "${toolName} TypeScript CLI tool";
        binaryName = module.binaryName or binName;
        packageAttr = module.packageAttr or packageAttr;
      } // (builtins.removeAttrs module [ "name" "description" "binaryName" "packageAttr" ])
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
        ${packageAttr} = (mkPerSystem final.system).packages.default;
      };
    } // moduleOutputs;
  }
