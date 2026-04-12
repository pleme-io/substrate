# Substrate Build Result Contract
#
# The universal return type for all substrate builder functions.
# Every builder MUST return a value that conforms to this contract.
# Non-standard builders (Go tool returning a single derivation) are
# wrapped at the export boundary to produce this shape.
#
# This is the Checkpoint layer in the convergence theory — the typed
# proof that a builder produced the expected outputs.
#
# Pure — depends only on nixpkgs lib.
{ lib }:

let
  inherit (lib) types mkOption;
  foundation = import ./foundation.nix { inherit lib; };
in rec {
  # ── Build Result (the universal output contract) ──────────────────
  buildResult = types.submodule {
    options = {
      packages = mkOption {
        type = types.attrsOf types.package;
        default = {};
        description = "Named package outputs. Must include 'default' if non-empty.";
      };
      devShells = mkOption {
        type = types.attrsOf types.package;
        default = {};
        description = "Development shells. Must include 'default' if non-empty.";
      };
      apps = mkOption {
        type = types.attrsOf foundation.appEntry;
        default = {};
        description = "Runnable applications ({ type = \"app\"; program = ...; }).";
      };
      overlays = mkOption {
        type = types.attrsOf types.raw;
        default = {};
        description = "Nixpkgs overlays (final: prev: { ... }).";
      };
      checks = mkOption {
        type = types.attrsOf types.package;
        default = {};
        description = "CI check derivations.";
      };
      meta = mkOption {
        type = types.attrsOf types.raw;
        default = {};
        description = "Arbitrary metadata (language, version, etc.).";
      };
    };
  };

  # ── Build Result Module ───────────────────────────────────────────
  # For use with lib.evalModules. Import this as a module, set config
  # to the builder's return value, and evaluation will type-check it.
  #
  # Usage:
  #   eval = lib.evalModules {
  #     modules = [ buildResultTypes.buildResultModule { config = builderOutput; } ];
  #   };
  buildResultModule = {
    options = {
      packages = mkOption {
        type = types.attrsOf types.package;
        default = {};
      };
      devShells = mkOption {
        type = types.attrsOf types.package;
        default = {};
      };
      apps = mkOption {
        type = types.attrsOf foundation.appEntry;
        default = {};
      };
      overlays = mkOption {
        type = types.attrsOf types.raw;
        default = {};
      };
      checks = mkOption {
        type = types.attrsOf types.package;
        default = {};
      };
      meta = mkOption {
        type = types.attrsOf types.raw;
        default = {};
      };
    };
  };

  # ── Flake Output Contract ─────────────────────────────────────────
  # Extended build result for standalone flake builders (*-flake.nix).
  # Adds homeManagerModules and nixosModules.
  flakeResult = types.submodule {
    options = {
      packages = mkOption {
        type = types.attrsOf (types.attrsOf types.package);
        default = {};
        description = "Per-system packages: { x86_64-linux.default = ...; }";
      };
      devShells = mkOption {
        type = types.attrsOf (types.attrsOf types.package);
        default = {};
      };
      apps = mkOption {
        type = types.attrsOf (types.attrsOf foundation.appEntry);
        default = {};
      };
      overlays = mkOption {
        type = types.attrsOf types.raw;
        default = {};
        description = "System-independent overlays.";
      };
      homeManagerModules = mkOption {
        type = types.attrsOf types.raw;
        default = {};
      };
      nixosModules = mkOption {
        type = types.attrsOf types.raw;
        default = {};
      };
    };
  };
}
