# Complete multi-system flake outputs for a Go CLI tool.
# Wraps go-tool.nix + eachSystem + overlays for zero-boilerplate
# consumer flakes — the Go peer of build/rust/tool-release-flake.nix.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, flake-utils, substrate, forge, ... }:
#     (import "${substrate}/lib/build/go/tool-release-flake.nix" {
#       inherit nixpkgs;
#       forge = forge or null;          # optional — enables the release apps
#     }) {
#       toolName = "kubectl-tree";
#       version = "0.4.6";
#       src = self;
#       vendorHash = "sha256-...";       # null = in-tree vendoring (go-gen-spec)
#       repo = "pleme-io/kubectl-tree";  # optional — enables release/bump apps
#     };
#
# Release surface (mirrors the Rust tool-release-flake): when `repo` is set,
# apps.{release,bump} delegate to the language-generic `forge tool <verb>
# --language go` (see util/release-helpers.nix). apps.{check-all,lock-platform}
# are always present. Go uses the PULL model — `forge tool release` tags +
# pushes a semver git tag (no upload); proxy.golang.org fetches lazily.
#
# Module trio (NixOS + nix-darwin + home-manager): pass `module = { ... }` to
# auto-emit nixosModules.default / darwinModules.default / homeManagerModules.default.
# See substrate/lib/module-trio.nix for the spec shape.
{
  nixpkgs,
  forge ? null,
}:
{
  toolName,
  systems ? ["aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux"],
  module ? null,
  repo ? null,
  ...
} @ args:
let
  toolArgs = builtins.removeAttrs args [ "toolName" "systems" "module" "repo" ];
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
  goDevenv = import ./devenv.nix;
  releaseHelpers = import ../../util/release-helpers.nix;

  mkPerSystem = system: let
    pkgs = import nixpkgs { inherit system; };
    lib = pkgs.lib;
    package = goToolBuilder.mkGoTool pkgs ({
      pname = toolName;
    } // toolArgs);
    # forge binary resolution: prefer the passed flake input, else PATH lookup.
    forgeCmd =
      if forge != null then "${forge.packages.${system}.default}/bin/forge"
      else "forge";
    # Release lifecycle apps — language-generic, parameterised with language="go".
    releaseArgs = { hostPkgs = pkgs; inherit toolName forgeCmd; language = "go"; };
  in {
    packages = {
      default = package;
      ${toolName} = package;
    };
    devShells = {
      default = goDevenv.mkGoDevShell pkgs {};
    };
    apps = {
      default = {
        type = "app";
        program = "${package}/bin/${toolName}";
      };
      check-all = releaseHelpers.mkCheckAllApp releaseArgs;
      lock-platform = releaseHelpers.mkLockPlatformApp releaseArgs;
    } // lib.optionalAttrs (repo != null) {
      # `repo` is required by `forge tool release` (the GitHub coordinate).
      release = releaseHelpers.mkReleaseApp (releaseArgs // { inherit repo; });
      bump = releaseHelpers.mkBumpApp releaseArgs;
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
        ${toolName} = (mkPerSystem final.stdenv.hostPlatform.system).packages.default;
      };
    } // moduleOutputs;
  }
