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
  # ── THE SYMPTOM, SO THE NEXT PERSON RECOGNISES IT ────────────────────────
  # `targets` is not an optimisation. A pkgsStatic build with NO rust overlay
  # has no prebuilt toolchain, so nixpkgs builds rustc -- and therefore LLVM --
  # from source for the musl target, and on recent LLVM that build FAILS:
  #
  #   llvm-static-x86_64-unknown-linux-musl-21.1.8, ~file 3400/3992
  #   linking libLLVM.so.21.1 (a SHARED object) for a musl-static target
  #   ld.bfd: failed to set dynamic section sizes: bad value
  #
  # THREE INDEPENDENT ENCOUNTERS, none of which recognised the others:
  #   * kindling-profiles, 2026-07-31 -- TWO AMI bakes died there, ~56 min and
  #     ~$1.35 each. Resolved by moving that consumer to the glibc `host-tool`
  #     output, which was right for THAT binary (it shells out to dynamically
  #     linked `ip`/`nft`) and left the class alive.
  #   * an earlier attempt to size around it, recorded in the same file, was
  #     arithmetically a no-op: maxJobs*cores was 16 both before and after.
  #   * pangea-operator's Ruby-free operator image, 2026-08-12 -- explains why
  #     GHCR carried ZERO noruby-* tags: the variant had never built anywhere,
  #     by anyone, and every red release run was failing right here.
  #
  # If the binary genuinely should not be static, move it off pkgsStatic (the
  # kindling fix). If it must be static -- a distroless-static image has no
  # dynamic linker, so it must -- pass its triple here. Measured on
  # pangea-operator: `nix path-info --derivation -r` over the image went from
  # dying in llvm-static to ZERO llvm-static-musl derivations in the graph.
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
  in (import ./crates-io-cdn-overlay.nix final prev) // {
    # crates.io 403 fix (2026-05-27 policy change): compose the
    # crates-io-cdn overlay here so EVERY consumer of this rust overlay
    # — substrate's own library/service/tool builders AND every
    # downstream flake doing `import nixpkgs { overlays = [ mkRustOverlay
    # … ]; }` then `buildRustPackage`/`fetchCargoVendor` (e.g.
    # mathscape) — gets the api/v1 → static.crates.io rewrite
    # automatically, with zero per-repo config. The gen lockfile-builder
    # path canonicalizes independently; this covers the
    # buildRustPackage/crate2nix paths. fetchurl is a content-addressed
    # FOD, so the rewrite is zero-cascade (no crate output hashes change).

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
