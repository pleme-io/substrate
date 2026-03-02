# ============================================================================
# FLAKE WRAPPER - Shared eachSystem + output aggregation for *-flake.nix files
# ============================================================================
# Eliminates the repeated eachSystem/packages/devShells/apps aggregation pattern
# found in rust-tool-release-flake.nix, zig-tool-release-flake.nix,
# typescript-library-flake.nix, and rust-service-flake.nix.
#
# Internal helper — not exported from lib/default.nix.
#
# Usage:
#   mkFlakeOutputs = (import ./flake-wrapper.nix { inherit nixpkgs; }).mkFlakeOutputs;
#   mkFlakeOutputs {
#     systems = [ "aarch64-darwin" ... ];
#     mkPerSystem = system: { packages, devShells, apps };
#     extraOutputs = { overlays.default = ...; };
#   }
{ nixpkgs }: {
  # Generate standard flake outputs from a per-system builder function.
  #
  # systems: list of system strings
  # mkPerSystem: system -> { packages, devShells, apps }
  # extraOutputs: additional top-level outputs (overlays, modules, etc.)
  mkFlakeOutputs = {
    systems,
    mkPerSystem,
    extraOutputs ? {},
  }: let
    eachSystem = f: nixpkgs.lib.genAttrs systems f;
  in {
    packages = eachSystem (system: (mkPerSystem system).packages);
    devShells = eachSystem (system: (mkPerSystem system).devShells);
    apps = eachSystem (system: (mkPerSystem system).apps);
  } // extraOutputs;
}
