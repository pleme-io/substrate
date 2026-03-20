# Rust Overlay Module
#
# Provides a reusable Rust overlay function using fenix stable toolchain.
# This ensures consistent Rust versions (1.90+) across all services.
#
# SINGLE SOURCE OF TRUTH: All Rust builds should use this overlay to ensure
# consistent toolchain versions and crate2nix compatibility.
#
# IMPORTANT: This overlay only overrides buildRustCrate (used by crate2nix for
# service builds). It does NOT replace system rustc/cargo to avoid breaking
# nixpkgs packages (mercurial, librsvg, cryptography, etc.) that use Rust
# internally and may not be compatible with the newer fenix toolchain.
#
# Usage:
#   nixLib = import ./lib { inherit pkgs fenix system; };
#   pkgs = import nixpkgs {
#     inherit system;
#     overlays = [ (nixLib.mkRustOverlay { inherit fenix system; }) ];
#   };
{
  # Create a Rust overlay using latest stable from fenix (1.90+)
  # Parameters:
  #   fenix: The fenix flake input (inputs.fenix)
  #   system: Target system (e.g., "x86_64-linux", "aarch64-darwin")
  # Returns: An overlay function (final: prev: ...)
  #
  # This overlay:
  # 1. Configures buildRustCrate to use fenix's rustc (critical for edition 2024)
  # 2. Exposes fenix toolchain via fenixRustToolchain for direct use in devShells
  mkRustOverlay = { fenix, system }: let
    rustToolchain = fenix.packages.${system}.stable.withComponents [
      "rustc" "cargo" "rust-src" "clippy" "rustfmt"
    ];
  in final: prev: let
    # unwrapped derivation provides configureFlags for buildRustCrate target detection
    rustcUnwrapped = prev.stdenv.mkDerivation {
      name = "rustc-unwrapped";
      phases = ["installPhase"];
      installPhase = ''
        mkdir -p $out/bin
        ln -s ${rustToolchain}/bin/* $out/bin/
      '';
      configureFlags = [ "--target=${prev.stdenv.hostPlatform.rust.rustcTarget}" ];
    };

    # rustc wrapper for buildRustCrate only (not global)
    rustcWrapper = rustToolchain // {
      pname = "rustc";
      unwrapped = rustcUnwrapped;
      targetPlatforms = prev.lib.platforms.all;
      badTargetPlatforms = [];
      passthru = (rustToolchain.passthru or {}) // {
        unwrapped = rustcUnwrapped;
        targetPlatforms = prev.lib.platforms.all;
        badTargetPlatforms = [];
      };
      meta = (rustToolchain.meta or {}) // { mainProgram = "rustc"; };
    };

    # cargo wrapper for buildRustCrate only (not global)
    cargoWrapped = prev.runCommand "cargo-wrapped" {
      nativeBuildInputs = [ prev.makeWrapper ];
      pname = "cargo";
      meta = { mainProgram = "cargo"; };
    } ''
      mkdir -p $out/bin
      makeWrapper ${rustToolchain}/bin/cargo $out/bin/cargo \
        --suffix PATH : "${rustToolchain}/bin"
    '';
  in {
    # DO NOT override system rustc/cargo — this breaks nixpkgs packages
    # (mercurial, librsvg, cryptography, etc.) that aren't compatible with
    # the newer fenix toolchain's stricter lints and behavior changes.

    # Override buildRustCrate to use fenix's rustc (supports edition 2024)
    # This is what crate2nix uses to build our services.
    buildRustCrate = prev.buildRustCrate.override {
      rustc = rustcWrapper;
      cargo = cargoWrapped;
    };

    # Expose fenix toolchain for devShells and direct cargo/clippy use
    fenixRustToolchain = rustToolchain;
    fenixRustc = rustcWrapper;
    fenixCargo = cargoWrapped;
  };

  # Get the latest Rust toolchain from fenix
  # Useful when you need the toolchain directly without an overlay
  getRustToolchain = { fenix, system }:
    fenix.packages.${system}.stable.withComponents [
      "rustc" "cargo" "rust-src" "clippy" "rustfmt"
    ];
}
