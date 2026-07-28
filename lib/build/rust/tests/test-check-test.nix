# Pure eval tests for lib/build/rust/test-check.nix.
#
# WHAT THIS GUARDS. `nix flake check` builds `checks.<system>.*` and
# nothing else, so the presence of those two attrs is the whole difference
# between a gate and a green lie. These tests are the forcing function that
# a substrate Rust builder keeps emitting them: a refactor that drops
# `checks.build`, or that starts emitting an always-green `checks.tests` on
# a build path that cannot run tests, turns this red.
#
# The load-bearing one is `lockfile-never-forces-mkTests`: on the build
# path where substrate CANNOT run tests, the test derivation must not even
# be evaluated. It is asserted by passing `mkTests = _: throw "…"` — the
# same poisoned-argument trick `lib/infra/tests/mutating-verbs-test.nix`
# uses for `pkgs`. If `surface` ever starts forcing that thunk (which on a
# real consumer would be a `.override { runTests = true; }` against a
# nixpkgs `buildRustCrate` that has no such argument, i.e. an eval error
# for every tool-release consumer in the fleet), this test goes red instead
# of the fleet.
#
# NOT VACUOUS: every negative test asserts that a deliberately-broken
# declaration THROWS, so a validator that stops validating fails the
# assertion rather than passing it.
#
# Usage:
#   nix eval -f lib/build/rust/tests/test-check-test.nix \
#     --arg lib '(import <nixpkgs> {}).lib' --json
# Wired as a derivation via `asCheck pkgs` in substrate's flake checks.
{ lib }:

let
  testHelpers = import ../../../util/test-helpers.nix { inherit lib; };
  tc = import ../test-check.nix { inherit lib; };

  # Opaque stand-ins. Identity is what we assert, so these must not be
  # attrsets the surface could plausibly rebuild.
  fakeBuild = "/nix/store/BUILD-DRV";
  fakeTests = "/nix/store/TESTS-DRV";
  fakeExtra = { gen-confirm = "/nix/store/GEN-CONFIRM"; };

  # Forcing this is a test failure by construction.
  poisonTests = _: throw
    "test-check: mkTests was forced on a build path that cannot run tests";

  throws = expr: !(builtins.tryEval expr).success;
  throwsDeep = expr: !(builtins.tryEval (builtins.deepSeq expr expr)).success;

  cargoNixSurface = tc.surface {
    who = "demo";
    mode = "cargo-nix";
    buildDrv = fakeBuild;
    mkTests = _: fakeTests;
    extra = fakeExtra;
  };

  lockfileSurface = tc.surface {
    who = "demo";
    mode = "lockfile";
    buildDrv = fakeBuild;
    mkTests = poisonTests;
    extra = fakeExtra;
  };

  optedOutSurface = tc.surface {
    who = "demo";
    mode = "cargo-nix";
    decl = { enable = false; reason = "REASON-SENTINEL"; };
    buildDrv = fakeBuild;
    mkTests = poisonTests;
  };

  tests = [
    # ── The floor: a build check, always, on every path ─────────────────
    (testHelpers.mkTest "build-check-always-emitted-cargo-nix"
      (cargoNixSurface.build == fakeBuild)
      "checks.build must be emitted on the cargo-nix path — without it `nix flake check` never compiles the crate")

    (testHelpers.mkTest "build-check-always-emitted-lockfile"
      (lockfileSurface.build == fakeBuild)
      "checks.build must be emitted on the lockfile path too — it is the whole floor for tool-release consumers")

    (testHelpers.mkTest "build-check-emitted-even-when-tests-opted-out"
      (optedOutSurface.build == fakeBuild)
      "opting out of tests must never also drop the compile check")

    # ── Tests are emitted exactly where they can genuinely run ─────────
    (testHelpers.mkTest "tests-check-emitted-on-cargo-nix"
      (cargoNixSurface ? tests && cargoNixSurface.tests == fakeTests)
      "the crate2nix path carries devDependencies + crateWithTest, so checks.tests must be emitted there")

    (testHelpers.mkTest "no-tests-check-on-lockfile"
      (!(lockfileSurface ? tests))
      "the lockfile path has no dev-dependency graph; a green checks.tests that ran nothing is worse than none")

    (testHelpers.mkTest "lockfile-never-forces-mkTests"
      (builtins.deepSeq lockfileSurface true)
      "the unavailable path must not even EVALUATE the test derivation (poisoned mkTests must stay unforced)")

    (testHelpers.mkTest "opt-out-drops-tests-check"
      (!(optedOutSurface ? tests))
      "a typed opt-out must actually remove checks.tests")

    (testHelpers.mkTest "opt-out-never-forces-mkTests"
      (builtins.deepSeq optedOutSurface true)
      "an opted-out declaration must not evaluate the test derivation either")

    # ── Builder-specific checks compose, never get clobbered ───────────
    (testHelpers.mkTest "extra-checks-merge-through"
      (cargoNixSurface.gen-confirm == fakeExtra.gen-confirm
        && lockfileSurface.gen-confirm == fakeExtra.gen-confirm)
      "a builder's own checks (gen-confirm) must survive the surface merge")

    (testHelpers.mkTest "surface-emits-exactly-the-expected-names"
      (builtins.attrNames cargoNixSurface == [ "build" "gen-confirm" "tests" ]
        && builtins.attrNames lockfileSurface == [ "build" "gen-confirm" ])
      "the emitted check set must be exactly build (+tests where available) plus the builder's extras")

    # ── Availability is a typed verdict carrying its reason ────────────
    (testHelpers.mkTest "lockfile-unavailable-carries-a-reason"
      (let a = tc.availability "lockfile";
       in !a.ok && lib.hasInfix "dev-dependency" a.reason
          && lib.hasInfix "pending-rust-test-check" a.reason)
      "the unavailable verdict must name WHY and carry the pending token, so the gap is greppable")

    (testHelpers.mkTest "cargo-nix-is-available"
      (tc.availability "cargo-nix").ok
      "the crate2nix path must report available")

    (testHelpers.mkTest "explain-names-the-unavailable-reason"
      (lib.hasInfix "no `tests` check" (tc.explain { who = "demo"; mode = "lockfile"; }))
      "explain must state plainly that no test check is emitted, and why")

    (testHelpers.mkTest "explain-names-the-opt-out-reason"
      (lib.hasInfix "REASON-SENTINEL"
        (tc.explain {
          who = "demo";
          mode = "cargo-nix";
          decl = { enable = false; reason = "REASON-SENTINEL"; };
        }))
      "an opt-out's typed reason must reach the operator-facing explanation")

    # ── Loud over silent (negative tests) ──────────────────────────────
    (testHelpers.mkTest "rejects-unknown-field"
      (throws (tc.normalize "demo" { enabled = false; }))
      "a misspelled field must throw, not silently leave the gate on")

    (testHelpers.mkTest "rejects-non-bool-enable"
      (throws (tc.normalize "demo" { enable = "false"; }))
      "a stringly-typed enable must throw — that is how a gate silently stops gating")

    (testHelpers.mkTest "rejects-opt-out-without-reason"
      (throws (tc.normalize "demo" { enable = false; }))
      "turning the test gate off without a typed reason must throw")

    (testHelpers.mkTest "rejects-opt-out-with-empty-reason"
      (throws (tc.normalize "demo" { enable = false; reason = ""; }))
      "an empty-string reason is not a reason")

    (testHelpers.mkTest "rejects-bad-declaration-through-surface"
      (throwsDeep (tc.surface {
        who = "demo";
        mode = "cargo-nix";
        decl = { enable = false; };
        buildDrv = fakeBuild;
        mkTests = _: fakeTests;
      }))
      "the validator must fire through `surface`, not only when normalize is called directly")

    (testHelpers.mkTest "default-declaration-is-tests-on"
      (tc.defaultDecl.enable && (tc.normalize "demo" { }).enable)
      "the default must be tests-ON; a default-off gate is the defect this file exists to close")
  ];

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  # Derivation form for `nix flake check`. Builds iff every test passes;
  # on failure the message names each failing test.
  asCheck = pkgs:
    if result.allPassed
    then pkgs.runCommand "rust-test-check-test" { } ''
      echo "rust test-check: ${result.summary}" > $out
    ''
    else throw ''
      rust test-check tests FAILED (${result.summary}):
        - ${builtins.concatStringsSep "\n  - " result.failures}'';
}
