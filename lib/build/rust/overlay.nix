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
  #   targets: optional list of extra Rust target triples (e.g.
  #     ["x86_64-unknown-linux-musl"]). Each contributes a PREBUILT
  #     `rust-std` from fenix so cross-compiling to that target never
  #     rebuilds rustc/LLVM from source — the host rustc runs on the
  #     build machine and emits the target's objects. Defaults to []
  #     (host-only — preserves existing behavior).
  mkRustOverlay = { fenix, system, targets ? [] }: let
    # Optional cross targets: each contributes a prebuilt rust-std.
    # Static-musl builds via pkgsStatic otherwise drag in a from-source
    # rustc + LLVM (a ~30-min build that also hits a static-link bug on
    # recent LLVM); the prebuilt std makes the host rustc cross-compile
    # straight to the target.
    crossStds = builtins.map
      (t: fenix.packages.${system}.targets.${t}.stable.rust-std)
      targets;
    rustToolchain =
      if targets == []
      then fenix.packages.${system}.stable.withComponents [
        "rustc" "cargo" "rust-src" "clippy" "rustfmt"
      ]
      else fenix.packages.${system}.combine ([
        fenix.packages.${system}.stable.rustc
        fenix.packages.${system}.stable.cargo
        fenix.packages.${system}.stable.rust-src
        fenix.packages.${system}.stable.clippy
        fenix.packages.${system}.stable.rustfmt
      ] ++ crossStds);
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
      # Host builds use the PATH-suffixed cargo wrapper (proven). Cross/
      # static targets pass the combined fenix toolchain directly as cargo
      # — rustc is co-located in the same bin/, so no PATH wrapper is
      # needed, and this avoids makeWrapper, whose setup-hook assertion
      # trips under the pkgsStatic stdenv (the static-musl release path).
      cargo = if targets == [] then cargoWrapped else rustToolchain;
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
