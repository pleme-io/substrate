# test-check.nix — the ONE typed surface deciding what `checks.<system>.*`
# a substrate Rust builder emits.
#
# ── WHY THIS FILE EXISTS ────────────────────────────────────────────────
#
# `nix flake check` builds `checks.<system>.*` and NOTHING ELSE. Packages,
# devShells and apps are only *evaluated* (nix checks they are derivations;
# it never realises them). So a flake that declares zero checks makes
# `nix flake check` a pure EVALUATION check — it goes green over a crate
# that was never compiled, let alone tested.
#
# Measured on `forge` (2026-07-27), exit status read directly:
#   clean tree                                    -> exit 0, 8.66s
#   `compile_error!` inside #[cfg(test)] mod tests -> exit 0
#   literal non-Rust garbage in a function body    -> exit 0
# and a temporary `checks.probe-red = runCommand … "exit 1"` DID fail the
# gate. The mechanism was sound; the ingredient was missing.
#
# This module is that ingredient, stated once so both `library.nix` and
# `tool-release.nix` emit the same shape rather than each growing its own.
#
# ── THE TWO CHECKS ──────────────────────────────────────────────────────
#
#   checks.build  — the crate COMPILES. Always emitted. This is the floor:
#                   after it, no substrate-built flake can be green over an
#                   unbuilt crate.
#   checks.tests  — the crate's tests RUN. Emitted only where substrate can
#                   genuinely run them (see `availability` below). Never
#                   faked: a check that cannot run tests is ABSENT, not
#                   green-and-empty, because a green guard over an empty
#                   subject set is the worst round-up available
#                   (UNREPRESENTABILITY §II.3, tier ⊥).
#
# ── AVAILABILITY IS A PROPERTY OF THE BUILD PATH, NOT A PREFERENCE ──────
#
# `crate2nix` path (a generated/committed `Cargo.nix`): the generated file
#   carries `devDependencies` per crate and ships `crateWithTest` +
#   `buildRustCrateWithFeatures { runTests }` behind `lib.makeOverridable`.
#   `.override { runTests = true; }` is crate2nix's own documented API and
#   really compiles + executes the crate's test targets. AVAILABLE.
#
# `lockfile` path (gen's `Cargo.build-spec.json` / `Cargo.gen.lock` via
#   lockfile-builder.nix): the spec has NO dev-dependency graph at all. A
#   crate record carries `runtime_dependencies` + `build_dependencies` and
#   nothing else, and `spec-invariants.nix` actively FAILS a spec whose
#   runtime/build edges contain a `kind = "dev"` dep
#   ("dev-dep-in-runtime-or-build"). nixpkgs' bare `buildRustCrate` also has
#   no `runTests` argument (only `buildTests`, which compiles test binaries
#   but never runs them and still has no dev-dep externs to compile
#   against). 12 of 13 surveyed consumers declare `[dev-dependencies]`, so
#   "compile the test target with no dev-deps on the extern path" fails for
#   essentially all of them. UNAVAILABLE — and the fix belongs UPSTREAM in
#   gen-cargo (emit `dev_dependencies` edges into the spec, per the
#   ★★ GEN TYPED-SPEC CONTRACT), not in a Nix-side re-derivation of cargo's
#   resolver. Tracked as `pending-rust-test-check: lockfile-dev-deps`.
#
# ── OPT-OUT IS TYPED, NEVER A BARE BOOLEAN ─────────────────────────────
#
# Same grammar as `lib/infra/mutating-verbs.nix`: disabling requires a
# typed reason, so an opt-out is always a recorded decision rather than a
# silent flip. `{ enable = false; }` with no `reason` THROWS.
{ lib }:

let
  knownFields = [ "enable" "reason" ];
in
rec {
  # The default: tests are ON wherever substrate can run them.
  defaultDecl = {
    enable = true;
    reason = null;
  };

  # Validate + fill a consumer's `tests = { … }` declaration.
  # `who` is the builder/crate name, used only in error messages.
  normalize = who: decl:
    let
      unknown = builtins.filter (f: !(builtins.elem f knownFields))
        (builtins.attrNames decl);
      merged = defaultDecl // decl;
    in
      if unknown != [ ]
      then throw ''
        substrate/rust: ${who} — unknown field(s) in `tests`: ${builtins.concatStringsSep ", " unknown}.
        Known fields: ${builtins.concatStringsSep ", " knownFields}.
      ''
      else if !(builtins.isBool merged.enable)
      then throw ''
        substrate/rust: ${who} — `tests.enable` must be a bool, got
        ${builtins.typeOf merged.enable}. A stringly-typed flag is how a
        gate silently stops gating.
      ''
      else if !merged.enable && (merged.reason == null || merged.reason == "")
      then throw ''
        substrate/rust: ${who} — `tests.enable = false` requires a typed
        `reason`. Turning the test gate off is a decision that must be
        recorded at the declaration, not an undocumented flip.

          tests = {
            enable = false;
            reason = "<why this crate genuinely cannot run tests in a nix sandbox>";
          };

        Time pressure is not an acceptable reason.
      ''
      else merged;

  # Can substrate genuinely RUN this crate's tests on the given build path?
  # Returns a typed record; never a bare bool, so the reason travels with
  # the verdict to whatever surfaces it.
  availability = mode:
    if mode == "cargo-nix"
    then {
      ok = true;
      mode = "cargo-nix";
      reason = null;
    }
    else {
      ok = false;
      mode = mode;
      reason =
        "the gen lockfile build path carries no dev-dependency graph "
        + "(Cargo.build-spec.json has runtime_dependencies + "
        + "build_dependencies only, and spec-invariants.nix rejects a "
        + "dev-dep appearing in either), so a test target cannot be "
        + "compiled; the fix is gen-cargo emitting dev_dependencies edges "
        + "— pending-rust-test-check: lockfile-dev-deps";
    };

  # Assemble the `checks` attrset a builder returns.
  #
  #   who        — builder/crate name, for error messages
  #   decl       — the consumer's raw `tests = { … }` declaration
  #   mode       — "cargo-nix" | "lockfile"
  #   buildDrv   — the derivation proving the crate COMPILES
  #   mkTests    — thunk producing the derivation that RUNS the tests;
  #                forced ONLY when it will actually be emitted, so the
  #                unavailable path never evaluates a `.override` that
  #                would throw.
  #   extra      — builder-specific checks merged in (e.g. gen-confirm)
  surface = {
    who,
    decl ? { },
    mode,
    buildDrv,
    mkTests,
    extra ? { },
  }:
    let
      d = normalize who decl;
      avail = availability mode;
    in
      { build = buildDrv; }
      // (if d.enable && avail.ok then { tests = mkTests { }; } else { })
      // extra;

  # Human-readable statement of what a given (decl, mode) pair yields.
  # Used by the surface tests and available to any operator-facing report,
  # so "why is there no tests check here?" is answerable without reading
  # this file.
  explain = { who, decl ? { }, mode }:
    let
      d = normalize who decl;
      avail = availability mode;
    in
      if !d.enable
      then "${who}: no `tests` check — opted out: ${d.reason}"
      else if !avail.ok
      then "${who}: no `tests` check — unavailable on the ${avail.mode} build path: ${avail.reason}"
      else "${who}: `tests` check emitted (${avail.mode} build path)";
}
