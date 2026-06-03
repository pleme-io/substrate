# Complete multi-system flake outputs for a Go library (pull-model release).
# Wraps build/go/library-check.nix + eachSystem + overlays + module-trio for
# zero-boilerplate consumer flakes. The Go peer of build/rust/library-flake.nix
# — the missing dual on the Go library side.
#
# Usage in a library flake:
#   {
#     inputs = {
#       nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-25.11";
#       substrate = {
#         url = "github:pleme-io/substrate";
#         inputs.nixpkgs.follows = "nixpkgs";
#       };
#       forge.url = "github:pleme-io/forge";   # optional — enables release apps
#     };
#     outputs = { self, nixpkgs, substrate, forge, ... }:
#       (import "${substrate}/lib/build/go/library-flake.nix" {
#         inherit nixpkgs;
#         forge = forge or null;
#       }) {
#         name = "akeyless-go";
#         src = self;
#         vendorHash = "sha256-...";           # null = no deps
#         repo = "akeylesslabs/akeyless-go";   # optional — enables release/bump
#       };
#   }
#
# Returns standard flake outputs: packages, devShells, apps, overlays.default.
# `packages.default` is the build-verification check (mkGoLibraryCheck) — it
# compiles `./...` in the Nix sandbox without installing a binary. `apps`
# exposes the language-generic release surface (check-all / lock-platform,
# plus release / bump when `repo` is set) on every system.
#
# Release surface: when `repo` is set, apps.{release,bump} delegate to the
# language-generic `forge tool <verb> --language go` (see
# util/release-helpers.nix). apps.{check-all,lock-platform} are always present.
# Go uses the PULL model — `forge tool release` tags + pushes a semver git tag
# (TAG-ONLY, no upload); proxy.golang.org fetches the module lazily. There is
# no registry push step the way crates.io / npm require.
#
# Module trio (NixOS + nix-darwin + home-manager): pass `module = { ... }` to
# auto-emit nixosModules.default / darwinModules.default / homeManagerModules.default.
# See substrate/lib/module-trio.nix for the spec shape. Libraries rarely need
# module trios — mostly relevant when a library ships a companion CLI shim.
{
  nixpkgs,
  forge ? null,
}:
{
  name,
  systems ? ["aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux"],
  src,
  modRoot ? null,
  module ? null,
  repo ? null,
  ...
} @ args:
let
  libArgs = builtins.removeAttrs args [ "name" "systems" "modRoot" "module" "repo" ];
  flakeWrapper = import ../../util/flake-wrapper.nix { inherit nixpkgs; };
  pkgsLib = (import nixpkgs { system = "x86_64-linux"; }).lib;
  hygiene = import ../../util/flake-hygiene.nix {
    lib = pkgsLib;
  };
  # Enforce flake hygiene at evaluation time — fails fast on misconfiguration.
  # In library flakes, src = self, so src.inputs holds the flake inputs.
  _hygieneCheck =
    if args ? src && args.src ? inputs then hygiene.enforceAll args.src.inputs
    else true;

  goLibraryCheck = import ./library-check.nix;
  releaseHelpers = import ../../util/release-helpers.nix;

  # mkGoLibraryCheck has a closed attrset (no `...`) and no `modRoot`
  # parameter — buildGoModule reads `modRoot` from a top-level attr, so
  # for monorepo libraries we thread it through `extraAttrs` (the same
  # escape hatch tool.nix uses). null = the library lives at repo root.
  modRootAttrs =
    if modRoot == null then {}
    else { extraAttrs = (libArgs.extraAttrs or {}) // { inherit modRoot; }; };

  mkPerSystem = system: let
    pkgs = import nixpkgs { inherit system; };
    lib = pkgs.lib;
    # Build-verification derivation — compiles the library, installs nothing.
    check = goLibraryCheck.mkGoLibraryCheck pkgs ({
      pname = name;
    } // libArgs // modRootAttrs);
    # forge binary resolution: prefer the passed flake input, else PATH lookup.
    forgeCmd =
      if forge != null then "${forge.packages.${system}.default}/bin/forge"
      else "forge";
    # Release lifecycle apps — language-generic, parameterised with language="go".
    releaseArgs = { hostPkgs = pkgs; toolName = name; inherit forgeCmd; language = "go"; };
  in {
    packages = {
      default = check;
      ${name} = check;
    };
    devShells = {
      default = pkgs.mkShellNoCC {
        packages = with pkgs; [ go gopls gotools ];
      };
    };
    apps = {
      check-all = releaseHelpers.mkCheckAllApp releaseArgs;
      lock-platform = releaseHelpers.mkLockPlatformApp releaseArgs;
    } // lib.optionalAttrs (repo != null) {
      # `repo` is required by `forge tool release` (the GitHub coordinate).
      # Go's pull-model publish is TAG-ONLY — release tags + pushes a semver
      # git tag; proxy.golang.org fetches lazily. No artifact upload.
      release = releaseHelpers.mkReleaseApp (releaseArgs // { inherit repo; });
      bump = releaseHelpers.mkBumpApp releaseArgs;
    };
  };

  trio =
    if module == null then null
    else (import ../../module-trio.nix { lib = pkgsLib; }).mkModuleTrio (
      {
        name = module.name or name;
        description = module.description or "${name} Go library";
        packageAttr = module.packageAttr or name;
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
        ${name} = (mkPerSystem final.stdenv.hostPlatform.system).packages.default;
      };
    } // moduleOutputs;
  }
