# mkBuildSpec — resolve Cargo.build-spec.json, or IFD.
#
# ── ★ THIS IS THE PREDECESSOR PATH. READ THIS FIRST. ────────────────────
#
# The consumer's repository commits **`Cargo.gen.lock`** — the slim delta —
# and NOT `Cargo.build-spec.json`. ./lockfile-delta.nix reconstructs the
# full BuildSpec from that delta in PURE NIX, IFD-free and ~3.4× smaller,
# and ./lockfile-builder.nix short-circuits to it (`useDelta`, :449) BEFORE
# this file is consulted. So for a repo on the standard, nothing here runs.
#
# Measured 2026-08-17 over the local checkout: 425 repos track
# Cargo.gen.lock, 11 track Cargo.build-spec.json. substrate's own release
# bot commits "delta-only (build-spec retired)", and `gen` itself ships only
# Cargo.gen.lock at the rev ./gen-pin.json pins.
#
# This file is still reached in exactly three cases, all real:
#   1. no valid gen.lock triple (gen.lock + Cargo.lock + Cargo.toml)
#   2. a VARIANT spec name — `Cargo.<variant>.build-spec.json` sets
#      useDelta = false by design, so a variant spec MUST be committed
#      (pangea-operator is the live case)
#   3. the mk-rust-tool-flake metadata path for a workspace root with no
#      `[package]` table
#
# It therefore has two cases: a committed spec exists → use it; otherwise
# IFD `gen build .` in the sandbox. There is NO freshness gate here — a
# stale delta throws in lockfile-delta.nix long before this point.
#
# ## Why this primitive — SUPERSEDED, kept for history
#
# The section below describes a three-variant freshness gate
# (`Fresh`/`Drifted`/`Absent`, keyed on an embedded `cargo_lock_sha256`)
# that **is no longer implemented in this file**. :88 records why it was
# removed; :80-92 describes what the code actually does. Read those, not
# this. Kept rather than deleted because the reasoning explains how the
# delta's freshness tie inherited the problem.
#
# Pure IFD (the previous shape) is correct but slow:
#  - every consumer rebuild blocks eval on a `gen build` sandbox
#  - IFD is disabled in many CI contexts and on cached evaluation
#    hosts, so consumers couldn't share the spec across machines
#  - cargo metadata inside the sandbox needs network (`__noChroot`),
#    further slowing evaluation
#
# Pure committed-spec is fast but unsafe — operators forget to regen
# after a `cargo update`, the committed spec drifts from Cargo.lock,
# and substrate silently builds against a stale resolve graph. The
# bug surfaces deep inside an unrelated `nixos-rebuild` failure.
#
# The freshness gate composes both: **committed spec when provably
# fresh (BLAKE-3-equivalent SHA-256 of Cargo.lock matches the embedded
# `cargo_lock_sha256`), IFD as the safety net otherwise.** Operators
# get fast evaluation in the steady state AND a self-healing fallback
# when they forget to regen. CI auto-commit (gen's
# `.github/workflows/gen-spec-autocommit.yml`) keeps the steady state
# fresh by construction.
#
# ## Typed dispatcher rationale
#
# The decision space is a closed three-variant enum:
#
#   - `Fresh`    — committed spec exists + cargo_lock_sha256 matches
#                  current Cargo.lock hash → use committed, no IFD
#   - `Drifted`  — committed spec exists but cargo_lock_sha256 differs
#                  → fall back to IFD with `builtins.trace` warning so
#                  operator sees the drift on next build
#   - `Missing`  — no committed spec → fall back to IFD silently
#
# Mirrors gen-cargo's `Freshness` enum (`gen.cargo.freshness` catalog
# entry) so Rust + Nix sides reason about the same closed set.
#
# ## Inputs
#
# - `hostPkgs` — explicit because pkgsStatic's `.buildPackages` is itself,
#                not the darwin/linux host. The IFD always runs on the
#                build machine.
# - `gen`      — substrate-bound gen package.
# - `src`      — consumer's workspace root (path).
# - `target`   — optional cross-spec emission target triple.
#
# ## Output
#
# A derivation whose output `$out/Cargo.build-spec.json` is the typed
# build-spec ready to feed into `lockfile-builder.mkProject`. Substrate's
# wrappers do this transparently — consumers never see the freshness
# gate machinery.
{
  hostPkgs,
  gen,
  src,
  target ? null,
}:

let
  targetArg = if target == null then "" else "--filter-platform=${target}";

  # ── Spec source dispatch (operator-surface doctrine, aligned) ────
  #
  # Substrate trusts the committed spec unconditionally when present.
  # Spec freshness is gen's responsibility — gen's auto-commit CI in
  # bootstrap-exception repos keeps committed specs synced with
  # Cargo.lock changes. Substrate's only job is to consume the
  # artifact gen produced.
  #
  # Two cases only:
  #   1. Committed spec exists → use it. Fast path, no IFD, near-
  #      instant evaluation, cache-friendly across hosts.
  #   2. No committed spec → IFD via `gen build .` inside the
  #      sandbox. The operator-surface doctrine default: every
  #      consumer self-derives from Cargo.toml + Cargo.lock.
  #
  # The previous `cargo_lock_sha256` freshness comparison was the
  # wrong primitive — it compared two derived artifacts (Cargo.lock
  # + the spec) against each other, then asked operators to manually
  # re-run gen and commit. The CI auto-commit pattern eliminates
  # that toil at the source.

  committedSpecPath = src + "/Cargo.build-spec.json";
  hasCommittedSpec = builtins.pathExists committedSpecPath;

  # ── Fast path: committed spec exists ────────────────────────────
  committedDerivation = hostPkgs.runCommand "cargo-build-spec-committed" {
    passthru.source = "committed";
  } ''
    mkdir -p $out
    cp ${committedSpecPath} $out/Cargo.build-spec.json
  '';

  # ── Fallback: IFD ────────────────────────────────────────────────
  ifdDerivation = hostPkgs.runCommand "cargo-build-spec-ifd" {
    nativeBuildInputs = [
      gen
      hostPkgs.cargo
      hostPkgs.rustc
      hostPkgs.cacert
      hostPkgs.git
    ];
    SSL_CERT_FILE = "${hostPkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    NIX_SSL_CERT_FILE = "${hostPkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    __noChroot = true;
    src = src;
    passthru.source = "ifd";
  } ''
    cp -r $src/* .
    chmod -R u+w .
    mkdir -p $out
    export CARGO_HOME=$PWD/.cargo
    export HOME=$PWD
    gen build . ${targetArg} > /dev/null
    if [ ! -f Cargo.build-spec.json ]; then
      echo "mkBuildSpec: gen build did not produce Cargo.build-spec.json" >&2
      exit 1
    fi
    cp Cargo.build-spec.json $out/
  '';

  # ── Deterministic-performance visibility ─────────────────────────
  # The committed spec is the fast, network-free, cache-shared path; the
  # IFD fallback runs `gen build .` (cargo metadata over the network,
  # __noChroot) DURING EVAL — variable latency, not shared across hosts:
  # the literal "evaluating derivation is taking a while" cost. Falling to
  # IFD was SILENT, so the eval-time tax was invisible. Emit a loud trace
  # naming the source so every IFD repo is visible + actionable.
  #
  # ── ★ THE REMEDY IS THE DELTA, NOT THIS FILE'S ARTIFACT ────────────────
  # This trace used to end "commit its `gen build .` output
  # (Cargo.build-spec.json)". That advice was stale and actively harmful: it
  # names the artifact ./lockfile-delta.nix replaced, and because a stuck
  # operator does literally what the error says, it kept re-arming a trap
  # the fleet had otherwise retired (measured 2026-08-17: 425 repos track
  # Cargo.gen.lock, 11 track the spec — and one of those 11 was created that
  # same day by an author following this very message). Commit
  # Cargo.gen.lock instead; the delta reconstructs the full BuildSpec in
  # pure Nix and this IFD becomes unreachable.
  ifdDerivationTraced = builtins.trace
    "mkBuildSpec[IFD]: no committed Cargo.gen.lock for ${toString src} → eval-time `gen build` (network). Run `gen build .` and commit the Cargo.gen.lock delta (NOT Cargo.build-spec.json) for a deterministic no-IFD build."
    ifdDerivation;

in
  if hasCommittedSpec then committedDerivation else ifdDerivationTraced
