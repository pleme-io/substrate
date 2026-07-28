# Pure eval tests for lib/infra/mutating-verbs.nix.
#
# The load-bearing one is `backward-compat-*`: with no declaration (or one
# that enables everything) `retireApps` must return the app set it was given
# BY IDENTITY and must not force `pkgs` at all. Both facts are asserted by
# passing `pkgs = throw "…"` — if the enabled path ever starts building a
# wrapper, these tests turn red instead of silently moving every consumer's
# store path.
#
# NOT VACUOUS: each negative test asserts that a deliberately-broken
# declaration THROWS. `tryEval` catching nothing would fail the assertion, so
# a validator that stopped validating goes red rather than green.
#
# Usage:
#   nix eval -f lib/infra/tests/mutating-verbs-test.nix --arg lib '(import <nixpkgs> {}).lib' --json
# Wired as a derivation via `asCheck pkgs` in substrate's flake checks.
{ lib }:

let
  testHelpers = import ../../util/test-helpers.nix { inherit lib; };
  mv = import ../mutating-verbs.nix { inherit lib; };

  # A stand-in app set. Values are opaque on purpose — identity is what we
  # assert, so they must not be attrsets the transformer could rebuild.
  fakeApps = {
    plan = { type = "app"; program = "/nix/store/PLAN"; };
    apply = { type = "app"; program = "/nix/store/APPLY"; };
    destroy = { type = "app"; program = "/nix/store/DESTROY"; };
  };
  verbs = [ "plan" "apply" "destroy" ];

  # Forcing this is a test failure by construction.
  poisonPkgs = throw
    "mutating-verbs: pkgs was forced on the all-enabled path — backward compatibility is broken";

  throws = expr: !(builtins.tryEval expr).success;

  # `deepSeq` so a lazily-deferred throw inside the result still counts.
  throwsDeep = expr: !(builtins.tryEval (builtins.deepSeq expr expr)).success;

  # A `pkgs` stand-in that WORKS. Used wherever the test needs retirement to
  # actually happen, so the only thing that can throw is the guard under test
  # — passing `poisonPkgs` there would make a negative test pass for the wrong
  # reason (verified: with the stray-verb check deleted, a poisoned-pkgs
  # version of `rejects-unknown-verb` stayed GREEN).
  fakePkgs = {
    writeText = n: _t: "/nix/store/text-${n}";
    writeShellScript = n: _t: "/nix/store/script-${n}";
  };

  retired = mv.retireApps {
    pkgs = fakePkgs;
    name = "demo";
    inherit verbs;
    mutatingVerbs.apply = {
      enable = false;
      retiredOn = "2026-07-27";
      executes = "pangea bulk apply -> OpenTofu apply against S3 state";
    };
  } fakeApps;

  noticeWithReason = mv.retirementNotice {
    name = "demo";
    verb = "apply";
    decl = mv.defaultDecl // {
      enable = false;
      retiredOn = "2026-07-27";
      executes = "pangea bulk apply";
      reason = "REASON-SENTINEL";
    };
  };

  tests = [
    # ── Backward compatibility (the non-negotiable) ────────────────────
    (testHelpers.mkTest "backward-compat-no-declaration-is-identity"
      (mv.retireApps {
        pkgs = poisonPkgs;
        name = "demo";
        inherit verbs;
      } fakeApps == fakeApps)
      "retireApps with no mutatingVerbs must return the app set unchanged")

    (testHelpers.mkTest "backward-compat-empty-declaration-is-identity"
      (mv.retireApps {
        pkgs = poisonPkgs;
        name = "demo";
        inherit verbs;
        mutatingVerbs = {};
      } fakeApps == fakeApps)
      "an empty mutatingVerbs attrset must be identity")

    (testHelpers.mkTest "backward-compat-all-enabled-is-identity"
      (mv.retireApps {
        pkgs = poisonPkgs;
        name = "demo";
        inherit verbs;
        mutatingVerbs = {
          plan.enable = true;
          apply.enable = true;
          destroy.enable = true;
        };
      } fakeApps == fakeApps)
      "explicitly enabling every verb must be identity")

    (testHelpers.mkTest "backward-compat-default-is-enabled"
      mv.defaultDecl.enable
      "the default declaration must be enable = true")

    (testHelpers.mkTest "backward-compat-enabled-verb-passes-through-untouched"
      (retired.plan == fakeApps.plan && retired.destroy == fakeApps.destroy)
      "verbs that stay enabled must keep their original app value verbatim")

    # ── Retirement actually happens ────────────────────────────────────
    (testHelpers.mkTest "retired-verb-still-exists"
      (retired ? apply && retired.apply.type == "app")
      "a retired verb's app must still exist and resolve (not be deleted)")

    (testHelpers.mkTest "retired-verb-program-is-different"
      (retired.apply.program != fakeApps.apply.program)
      "a retired verb's program must be a different store path (eval-time flag)")

    (testHelpers.mkTest "retired-verb-set-is-otherwise-unchanged"
      (builtins.attrNames retired == builtins.attrNames fakeApps)
      "retirement must not add or drop app names")

    # ── Notice is derived from the declaration ─────────────────────────
    (testHelpers.mkTest "notice-names-the-verb"
      (lib.hasInfix "nix run .#apply" noticeWithReason)
      "the refusal must name the verb the operator ran")

    (testHelpers.mkTest "notice-carries-retired-on"
      (lib.hasInfix "2026-07-27" noticeWithReason)
      "the refusal must carry retiredOn from the declaration")

    (testHelpers.mkTest "notice-carries-executes"
      (lib.hasInfix "pangea bulk apply" noticeWithReason)
      "the refusal must say what the verb would have run")

    (testHelpers.mkTest "notice-carries-optional-reason"
      (lib.hasInfix "REASON-SENTINEL" noticeWithReason)
      "an optional reason must appear in the refusal")

    (testHelpers.mkTest "notice-names-the-reenable-path"
      (lib.hasInfix "mutatingVerbs.apply.enable = true" noticeWithReason)
      "the refusal must tell the operator exactly how to restore the verb")

    (testHelpers.mkTest "notice-names-declare-and-observe"
      (lib.hasInfix "DECLARE" noticeWithReason
        && lib.hasInfix "OBSERVE" noticeWithReason)
      "the refusal must name the declare-and-observe replacement path")

    # ── Loud over silent (negative tests) ──────────────────────────────
    (testHelpers.mkTest "rejects-unknown-field"
      (throws (mv.normalize "demo" "apply" { enabled = false; }))
      "a misspelled field must throw, not be silently ignored")

    (testHelpers.mkTest "rejects-non-bool-enable"
      (throws (mv.normalize "demo" "apply" { enable = "false"; }))
      "a stringly-typed enable must throw")

    (testHelpers.mkTest "rejects-retirement-without-date"
      (throws (mv.normalize "demo" "apply" {
        enable = false;
        executes = "pangea bulk apply";
      }))
      "enable = false without retiredOn must throw")

    (testHelpers.mkTest "rejects-retirement-without-executes"
      (throws (mv.normalize "demo" "apply" {
        enable = false;
        retiredOn = "2026-07-27";
      }))
      "enable = false without executes must throw")

    (testHelpers.mkTest "rejects-unknown-verb"
      (throwsDeep (mv.retireApps {
        pkgs = fakePkgs;
        name = "demo";
        inherit verbs;
        mutatingVerbs.aply = {
          enable = false;
          retiredOn = "2026-07-27";
          executes = "typo";
        };
      } fakeApps))
      "a declaration naming a verb this builder does not produce must throw")

    (testHelpers.mkTest "accepts-enabled-declaration-of-known-verb"
      (mv.normalize "demo" "apply" { enable = true; } ? retiredOn)
      "an enabled declaration normalizes without requiring retirement fields")
  ];

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  # Derivation form for `nix flake check`. Builds iff every test passes;
  # on failure the message names each failing test.
  asCheck = pkgs:
    if result.allPassed
    then pkgs.runCommand "mutating-verbs-test" { } ''
      echo "mutating-verbs: ${result.summary}" > $out
    ''
    else throw ''
      mutating-verbs tests FAILED (${result.summary}):
        - ${builtins.concatStringsSep "\n  - " result.failures}'';
}
