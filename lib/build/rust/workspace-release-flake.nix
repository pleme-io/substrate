# Complete multi-system flake outputs for a Rust workspace CLI tool.
# Wraps workspace-release.nix + eachSystem + overlays for zero-boilerplate
# consumer flakes.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, crate2nix, flake-utils, substrate, ... }:
#     (import "${substrate}/lib/rust-workspace-release-flake.nix" {
#       inherit nixpkgs crate2nix flake-utils;
#     }) {
#       toolName = "mamorigami";         # binary name
#       packageName = "mamorigami-cli";  # workspace member crate
#       src = self;
#       repo = "pleme-io/mamorigami";
#     };
{
  nixpkgs,
  crate2nix,
  flake-utils,
  fenix ? null,
  devenv ? null,
  forge ? null,
  # gen powers substrate's IFD spec-regen path. Consumers can pass
  # their own gen flake (preferred — pins to a known rev). When
  # null, substrate auto-fetches gen via `builtins.getFlake` so the
  # IFD path still works — closes the "consumer didn't wire gen,
  # substrate falls through to throw" regression class surfaced
  # 2026-05-30 across workspace-style consumers (ishou, etc.).
  gen ? null,
}:
{
  toolName,
  packageName,
  systems ? ["aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux"],
  module ? null,
  ...
} @ args:
let
  workspaceArgs = builtins.removeAttrs args [ "systems" "module" ];
  flakeWrapper = import ../../util/flake-wrapper.nix { inherit nixpkgs; };
  hygiene = import ../../util/flake-hygiene.nix {
    lib = (import nixpkgs { system = "x86_64-linux"; }).lib;
  };
  pkgsLib = (import nixpkgs { system = "x86_64-linux"; }).lib;
  # Enforce flake hygiene at evaluation time — fails fast on misconfiguration.
  # In workspace flakes, src = self, so src.inputs holds the flake inputs.
  _hygieneCheck =
    if args ? src && args.src ? inputs then hygiene.enforceAll args.src.inputs
    else true;

  # Auto-fetch gen as a flake when the consumer didn't pass one.
  # `builtins.getFlake` requires a LOCKED reference in pure-eval
  # mode — so we read substrate's `gen-pin.json` to discover the gen
  # rev substrate is pinned at. `gen-pin.json` (NOT flake.lock — gen
  # is no longer a flake input, which broke the substrate↔gen lock
  # cycle) IS the single source of truth for the gen rev. When
  # substrate bumps that pin, every downstream workspace consumer's
  # auto-fetched gen tracks the bump automatically. Caching is handled
  # by nix's flake-cache against the locked rev. This IFD-time
  # `getFlake` does NOT grow any lock.
  genPin = builtins.fromJSON (builtins.readFile ./gen-pin.json);
  genRev = genPin.rev;
  effectiveGen =
    if gen != null then gen
    else builtins.getFlake "github:pleme-io/gen/${genRev}";

  mkPerSystem = system: let
    rustWorkspace = import ./workspace-release.nix {
      inherit system nixpkgs devenv;
      crate2nix = crate2nix.packages.${system}.default;
      fenix = if fenix != null then fenix else null;
      forge = if forge != null then forge.packages.${system}.default else null;
      gen = effectiveGen.packages.${system}.host-tool or effectiveGen.packages.${system}.default;
    };
  in rustWorkspace workspaceArgs;

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
        ${workspaceArgs.toolName} = (mkPerSystem final.stdenv.hostPlatform.system).packages.default;
      };
    } // moduleOutputs;
  }
