# overlay.nix — the DELIVERY surface for the fleet Go toolchain.
#
# toolchain.nix decides WHICH Go the fleet builds with; this file decides HOW a
# consumer receives it. Those are separate problems, and conflating them is
# precisely what left the toolchain unreachable. Read toolchain.nix's header for
# the incident and the pin; this header is about delivery only.
#
# THE MEASURED DEFECT THIS FILE USED TO HAVE. `mkGoOverlay` built the toolchain
# with `prev.callPackage ./toolchain.nix {}` — i.e. out of the CONSUMER's package
# set. That inverts fenix's entire mechanism. fenix works on a nixos-24.05
# consumer precisely BECAUSE the consumer's nixpkgs never builds rustc; this
# built Go with the very package set whose staleness IS the problem. And against
# the exact consumer from the incident it did not merely produce an old compiler,
# it ABORTED:
#
#   $ nix eval --impure --expr '(import ./overlay.nix).getGoToolchain {
#       pkgs = import (getFlake "github:NixOS/nixpkgs/b134951…") { … }; }'
#   error: evaluation aborted with the following error message:
#     'lib.customisation.callPackageWith: Function called without required
#      argument "replaceVars" at …/lib/build/go/toolchain.nix:12'
#
# `replaceVars` does not exist in nixos-24.05 at all — it landed in the 25.x line
# at pkgs/build-support/replace-vars/. And because that is `abort`, not `throw`,
# not even `builtins.tryEval` can catch it, so there is no graceful-degradation
# path available to write. A second, independent failure sits right behind it:
# 24.05's lib/systems has no elaborated `stdenv.targetPlatform.go` attrset
# either. The old shape was therefore not "works but stale" on the consumer that
# needed it — it was structurally unusable, which is the honest reason it was
# never wired anywhere except tool-image-flake.nix.
#
# THE FIX IS PLACEMENT, NOT PLUMBING: build the toolchain in SUBSTRATE's own
# nixpkgs and hand the finished derivation across, exactly as flake.nix already
# hands `fenix.packages.${system}` across. Hence `mkGoToolchain { pkgs; … }`,
# called by flake.nix with substrate's OWN pkgs and published as
# `substrate.goToolchains.${system}.stable`.
#
# THREE DELIVERY ALTITUDES, in the order to reach for them.
#
#   1. PER-DERIVATION — the default, and what the fleet uses. Hand the toolchain
#      to one builder; it scopes `buildGoModule.override { go = …; }` to that
#      derivation and nothing else. Direct mirror of lib/build/oci-push.nix's
#      scoped `makeRustPlatform`, and the shape mkHardenedGoBinary now takes.
#      Measured working cross-nixpkgs: substrate's toolchain (built in the 26.05
#      anchor) injected into a 24.05 `buildGoModule` yields
#      `passthru.go.version = 1.26.5` while that consumer's `pkgs.go` stays
#      1.22.8 — no overlay, no replaceVars, no platform.go involved.
#
#   2. SCOPED OVERLAY — `mkGoOverlay { goToolchain = …; }`. Replaces `go` and
#      `buildGoModule` across a whole package set. Useful when a consumer builds
#      many Go packages and wants one answer for all of them, but note this is
#      exactly what lib/build/rust/overlay.nix's header REFUSES to do for
#      rustc/cargo ("DO NOT override system rustc/cargo — this breaks nixpkgs
#      packages (mercurial, librsvg, cryptography, etc.)"). The Go blast radius is
#      the same in kind: every Go package in the closure rebuilds against the
#      substrate toolchain, and `pkgsMusl` inherits the overlay and rebuilds the
#      compiler under musl as well. Secondary by design, never the default.
#
#   3. SELF-BUILT — `mkGoOverlay { }` / `getGoToolchain { pkgs = …; }`. The
#      original behaviour, preserved unchanged. Correct and cheapest when that
#      pkgs is recent enough to carry `replaceVars` and an elaborated
#      `platform.go`, i.e. 25.05+. On an older pin it aborts as shown above,
#      which is now documented rather than discovered.
#
# A HOLE IN ALTITUDE 2, stated because it is invisible from the option names:
# nixpkgs aliases `buildGoModule` to a VERSIONED builder (`buildGo122Module` on
# 24.05, `buildGo126Module` on 26.05). This overlay replaces `buildGoModule` plus
# the alias matching the TOOLCHAIN's own minor, so consumer code that names an
# off-version builder explicitly — `pkgs.buildGo122Module` — silently bypasses
# the pin. That is the whole argument for asserting the resulting binary's
# toolchain version (mkHardenedGoBinary does, on `drv.passthru.go.version`)
# instead of trusting the wiring.
let
  # nixpkgs' own naming for the versioned aliases: go_1_26 / buildGo126Module.
  # Derived from the toolchain's actual version rather than hardcoded, so a minor
  # bump in go-toolchain-pin.json does not silently leave the old alias pointing
  # at the consumer's stale compiler.
  underscored = mm: builtins.replaceStrings [ "." ] [ "_" ] mm;
  squashed = mm: builtins.replaceStrings [ "." ] [ "" ] mm;
in
rec {
  # ── mkGoToolchain — the fenix.toolchainOf analogue ──────────────────────
  #
  # Build the fleet Go toolchain from a GIVEN package set. flake.nix calls this
  # with substrate's own pkgs; that is the entire point of the function existing.
  #
  #   pkgs     the package set to BUILD the toolchain WITH. Must carry
  #            `replaceVars` and an elaborated `targetPlatform.go` (25.05+).
  #            Substrate's own anchor always does.
  #   version  optional explicit version; defaults to the committed fleet pin.
  #   hash     REQUIRED whenever `version` is given. fenix's own `toolchainOf`
  #            falls back to `builtins.fetchurl` when the hash is omitted, which
  #            is a network fetch at EVAL time. That arm is deliberately not
  #            reproduced — substrate's determinism bar does not tolerate it.
  mkGoToolchain =
    { pkgs, version ? null, hash ? null }:
    let
      _hashRequired =
        if version != null && hash == null
        then throw ''
          mkGoToolchain: `hash` is required when `version` is given.

          An explicit version with no hash could only be resolved by fetching at
          eval time — the impure arm of fenix's toolchainOf that substrate does
          not reproduce. Take the sha256 from go.dev's own published manifest and
          convert it to SRI:

            curl -sS 'https://go.dev/dl/?mode=json&include=all'

          Or omit both and take the committed fleet pin
          (lib/build/go/go-toolchain-pin.json), which is the normal case.
        ''
        else true;
    in
    assert _hashRequired;
    pkgs.callPackage ./toolchain.nix (
      if version != null then { inherit version hash; } else { }
    );

  # ── mkGoOverlay — package-set-wide delivery (altitudes 2 and 3) ─────────
  #
  # Returns an overlay function (final: prev: …) providing:
  #   pkgs.goToolchain     the fleet Go toolchain
  #   pkgs.go              overridden to it
  #   pkgs.buildGoModule   overridden to use it
  #
  #   goToolchain  an ALREADY-BUILT toolchain — see
  #                `substrate.goToolchains.${system}.stable`. Pass this on any
  #                consumer older than 25.05, where building in place aborts.
  #                When null, the toolchain is built from the consumer's own
  #                pkgs, preserving the original behaviour byte-for-byte.
  mkGoOverlay = { goToolchain ? null }: final: prev:
    let
      tc = if goToolchain != null then goToolchain else prev.callPackage ./toolchain.nix {};
      mm = prev.lib.versions.majorMinor tc.version;
      # `prev.callPackage <module.nix>` rather than `prev.buildGoModule.override`
      # here, deliberately: nixpkgs aliases buildGoModule = buildGo1XXModule, so
      # overriding both attrs through each other creates a cycle. At the
      # PER-DERIVATION altitude `.override` is correct and preferred, because it
      # does not depend on an internal nixpkgs file path.
      mkBuilder = prev.callPackage
        "${prev.path}/pkgs/build-support/go/module.nix" { go = tc; };
    in
    {
      goToolchain = tc;
      go = tc;
      buildGoModule = mkBuilder;
    }
    // { "go_${underscored mm}" = tc; }
    // { "buildGo${squashed mm}Module" = mkBuilder; };

  # THE one way a substrate entry point constructs a Go-capable package set.
  #
  # Every Go builder used to do `import nixpkgs { inherit system; }` with no
  # overlays, so the compiler was whatever the CONSUMER's nixpkgs shipped — and
  # the compiler, not the go.mod directive, decides which stdlib is linked in.
  # MEASURED 2026-08-06 across 68 substrate-consuming Go repos: 67 compiled with
  # an unpinned go (1.25.4 -> 28 known stdlib vulns on 30 repos; 1.26.3 -> 5 on
  # 36; only 1 repo was clean, and that by coincidence of a fresh lock).
  #
  # The toolchain is built from an UN-OVERLAID pkgs and then injected. Letting
  # mkGoOverlay build it in place (its `goToolchain ? null` arm) recurses through
  # the stdenv booter — measured: "infinite recursion encountered".
  #
  # Scoped to the returned package set only: this does not rebuild the world, it
  # repins `go` / `buildGoModule` for the derivations this entry point creates.
  mkGoPkgs = { nixpkgs, system, goToolchain ? null, overlays ? [ ] }:
    let
      basePkgs = import nixpkgs { inherit system; };
      tc =
        if goToolchain != null then goToolchain
        else getGoToolchain { pkgs = basePkgs; };
    in
      import nixpkgs {
        inherit system;
        overlays = [ (mkGoOverlay { goToolchain = tc; }) ] ++ overlays;
      };

  # Refuse a Go derivation compiled below the fleet CVE floor.
  #
  # mkGoPkgs makes the pinned compiler the DEFAULT; this makes an unpinned one
  # an ERROR. Without it, a seventh entry point that forgets to call mkGoPkgs
  # silently ships a vulnerable stdlib again — which is exactly how the hole
  # existed while tool.nix's header already claimed the toolchain was "the
  # single source of truth".
  #
  # Asserts on drv.passthru.go.version, NOT pkgs.go.version: nixpkgs aliases
  # buildGoModule to buildGo1XXModule, so a caller naming pkgs.buildGo125Module
  # bypasses the overlay while pkgs.go.version still reads the pinned value.
  # Only the derivation knows which compiler actually ran.
  assertGoFloor = { drv, what ? "a Go derivation" }:
    let
      pin = builtins.fromJSON (builtins.readFile ./go-toolchain-pin.json);
      got = drv.passthru.go.version or null;
    in
      if got == null then drv
      else if builtins.compareVersions got pin.cveFloor < 0
      then throw ("substrate: ${what} was compiled with go ${got}, below the fleet CVE "
        + "floor ${pin.cveFloor}. Build it through overlay.nix's mkGoPkgs so the pinned "
        + "toolchain is used, or pass goToolchain explicitly. Lowering the floor needs "
        + "'skip-go-floor: <typed-reason>' in the deviating repo's CLAUDE.md.")
      else drv;

  # Get the Go toolchain without an overlay, built from the given pkgs.
  #
  # NOTE the constraint the name does not carry: this builds the toolchain WITH
  # `pkgs`, so `pkgs` must be 25.05+. On nixos-24.05 it ABORTS — uncatchably — on
  # the missing `replaceVars`. Prefer `mkGoToolchain { pkgs = <substrate's>; }`
  # and hand the result across, which is what flake.nix does.
  getGoToolchain = { pkgs }:
    pkgs.callPackage ./toolchain.nix {};
}
