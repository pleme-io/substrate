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
# COMPOSITION (the `composition-*` block at the bottom)
#
#   Everything above tests `retireApps` in ISOLATION — it never asks whether a
#   retirement survives being composed. mutating-verbs.nix's own header calls
#   that out ("Retire at the SOURCE app set, before any composed verb inlines
#   another verb's `program`") and gated-pangea-workspace.nix implements it,
#   but for 20 tests nothing checked it: a change that retired only the
#   RETURNED set would have left `deploy` / `cycle` splicing the live cloud
#   mutation behind a top-level app that reads as refusing, and this suite
#   would have stayed green. The composition block drives the two real
#   composition layers end to end — gated-pangea-workspace.nix (`deploy`) and
#   infra-sdlc.nix (`cycle`) — and asserts the retirement reaches both.
#
#   It ships WITH ITS CONTROL. `composition-control-*` asserts the OPEN build
#   *does* splice the real apply program, which is what makes the two
#   "no-longer-splices" negatives falsifiable rather than an artifact of a
#   harness that can see nothing.
#
#   BOTH DIRECTIONS WERE VERIFIED RED, not merely observed green:
#
#     break 1 — the property. Replacing `base = retire rawBase` with
#       `base = rawBase` in gated-pangea-workspace.nix (retire only the
#       RETURNED set — the exact defect that file's header warns about) →
#       24/30, failing composition-retirement-reaches-{deploy,apply-ungated,
#       sdlc-cycle}, composition-apply-ungated-is-the-refusal and both
#       -drops-real-apply negatives. Every one of the 20 pre-existing tests
#       stayed green, which is the whole reason this block exists.
#       `composition-retirement-reaches-composed-apply` also stayed green —
#       top-level `apply` IS retireable, so the outer pass still replaces it.
#       That test is the weak one by construction; the load is carried by the
#       five that cover verbs the outer pass cannot reach.
#
#     break 2 — the harness. Keying `compositionPkgs.writeShellScript` on the
#       NAME only (a fake that cannot see script bodies) → 26/30, failing
#       BOTH controls. Note what stayed green under it: the two
#       -drops-real-apply negatives, vacuously, because a blind harness finds
#       nothing everywhere. That is precisely the failure the controls exist
#       to catch, and they caught it.
#
# Usage:
#   nix eval -f lib/infra/tests/mutating-verbs-test.nix --arg lib '(import <nixpkgs> {}).lib' --json
#
# Wired as a derivation via `asCheck pkgs` into `checks.<system>.mutating-verbs`
# in flake.nix — and, since 2026-07-28, RUN BY CI: the `flake-checks` job in
# .github/workflows/nix-tests.yml builds that check, triggered by `lib/infra/**`.
#
# Both halves of that sentence had to land together, and the reason is worth
# keeping. Before that commit these 30 tests ran in NO job on ANY trigger:
# nothing in .github/ executed `nix flake check` or built `checks.<system>.*`,
# and the three jobs that did exist only ran argument-free `nix-instantiate`
# files, which cannot run a suite that takes `lib`. Meanwhile `lib/infra/**` —
# the only tree whose changes can break these tests — was absent from the path
# filter. Adding the path WITHOUT the job would have fired a workflow that
# verified nothing here while the trigger list read as coverage; adding the job
# without the path would have left it blind to the code it guards.
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

  # ── Composition harness ───────────────────────────────────────────────
  #
  # A second `pkgs` stand-in, and the difference from `fakePkgs` above is
  # load-bearing rather than stylistic. The real store is CONTENT-addressed:
  # change a script's text and its path changes. `fakePkgs` keys only on the
  # NAME, which is correct for the isolation tests (they compare app values,
  # not script bodies) but would make every composition assertion vacuous —
  # `${name}-deploy` is the same name whether or not the apply it splices was
  # retired, so "the composed verb changed" would read FALSE under a build
  # that is in fact correct, and equally false under one that is broken.
  #
  # So this fake makes the returned "path" a function of the text, exactly as
  # the real writer does. Embedding the text verbatim rather than hashing it
  # keeps the second question answerable too — not just "did deploy change?"
  # but "does deploy still invoke the REAL apply program?", which is the
  # property that actually matters.
  compositionPkgs = {
    inherit lib;
    writeText = n: text: "/nix/store/${n}<<${text}>>";
    writeShellScript = n: text: "/nix/store/${n}.sh<<${text}>>";
    opentofu = "/nix/store/opentofu";
  };

  # `ruby` is passed explicitly so the builder never reaches for
  # `pkgs.ruby_3_3`; `pangea` / `bundler` / `inspecProfile` stay null, which
  # keeps every remaining `pkgs` reference inside the four attrs above.
  mkGatedWorkspace = import ../gated-pangea-workspace.nix {
    pkgs = compositionPkgs;
    ruby = "/nix/store/ruby";
  };
  mkInfraSdlc = import ../infra-sdlc.nix {
    pkgs = compositionPkgs;
    ruby = "/nix/store/ruby";
  };

  wsArgs = {
    name = "demo";
    architecture = "demo_arch";
    architecturesSrc = "/nix/store/architectures";
  };

  retireApplyDecl = {
    enable = false;
    retiredOn = "2026-07-27";
    executes = "pangea workspace apply demo -> OpenTofu apply against S3 state";
  };

  # The same builder, twice, differing ONLY in the retirement declaration.
  openWs = mkGatedWorkspace wsArgs;
  retiredWs = mkGatedWorkspace (wsArgs // { mutatingVerbs.apply = retireApplyDecl; });
  openSdlc = mkInfraSdlc wsArgs;
  retiredSdlc = mkInfraSdlc (wsArgs // { mutatingVerbs.apply = retireApplyDecl; });

  # The live program a composed verb splices when nothing is retired. Every
  # "does the composition still reach the real thing?" question below is
  # `hasInfix` of THIS string.
  openBaseApply = openWs.apply-ungated.program;

  # Independently-built oracle: what the refusal app for `apply` must be,
  # constructed straight from mutating-verbs.nix rather than read back out of
  # the builder under test.
  expectedRefusal = mv.mkRetiredApp {
    pkgs = compositionPkgs;
    name = "demo";
    verb = "apply";
    decl = mv.normalize "demo" "apply" retireApplyDecl;
  };

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

    # ── Composition: does a retirement SURVIVE being composed? ─────────
    #
    # Layer 1 — gated-pangea-workspace.nix. `deploy` and `apply-ungated`
    # are NOT in `retireableVerbs`, so the outer (returned-set) retire pass
    # cannot touch them: the only thing that can change them is retirement
    # having been applied to the SOURCE app set before they were composed.
    # That is exactly the property under test.

    (testHelpers.mkTest "composition-retirement-reaches-composed-apply"
      (retiredWs.apply.program != openWs.apply.program)
      "retiring `apply` must change the workspace's composed `apply` app")

    (testHelpers.mkTest "composition-retirement-reaches-deploy"
      (retiredWs.deploy.program != openWs.deploy.program)
      ''retiring `apply` must change `deploy`, which splices
        base.apply.program — `deploy` is not itself retireable, so this can
        only hold if retirement ran BEFORE composition'')

    (testHelpers.mkTest "composition-retirement-reaches-apply-ungated"
      (retiredWs.apply-ungated.program != openBaseApply)
      "retiring `apply` must change `apply-ungated`, which IS the base app")

    (testHelpers.mkTest "composition-apply-ungated-is-the-refusal"
      (retiredWs.apply-ungated.program == expectedRefusal.program)
      ''`apply-ungated` must be the refusal app itself, byte-for-byte with
        one built straight from mutating-verbs.nix — not merely "changed"'')

    (testHelpers.mkTest "composition-retired-deploy-drops-real-apply"
      (!(lib.hasInfix openBaseApply retiredWs.deploy.program))
      ''the retired build's `deploy` must NOT contain the real apply
        program — a deploy that still runs it behind a refusing `apply` is a
        guard that reads green and gates nothing'')

    (testHelpers.mkTest "composition-control-open-deploy-keeps-real-apply"
      (lib.hasInfix openBaseApply openWs.deploy.program)
      ''CONTROL for the two drops-real-apply tests: with nothing retired,
        `deploy` DOES contain the real apply program. Without this a harness
        that could see nothing at all would report both negatives as
        passing'')

    # Layer 2 — infra-sdlc.nix, one composition deeper. `cycle` splices
    # `gated.apply-ungated.program`, and infra-sdlc applies no retirement of
    # its own, so a retirement can only reach `cycle` by having been baked
    # into the base app set two layers down.

    (testHelpers.mkTest "composition-retirement-reaches-sdlc-cycle"
      (retiredSdlc.cycle.program != openSdlc.cycle.program)
      "retiring `apply` must reach infra-sdlc's `cycle`, two layers up")

    (testHelpers.mkTest "composition-retired-cycle-drops-real-apply"
      (!(lib.hasInfix openBaseApply retiredSdlc.cycle.program))
      ''the retired build's `cycle` must NOT contain the real apply program
        — otherwise `nix run .#cycle` routes around a declared retirement'')

    (testHelpers.mkTest "composition-control-open-cycle-keeps-real-apply"
      (lib.hasInfix openBaseApply openSdlc.cycle.program)
      "CONTROL: with nothing retired, `cycle` DOES contain the real apply")

    # And the other direction — retirement must be SCOPED, not a blanket
    # rebuild. `plan` is a sibling retireable verb left enabled;
    # `cycle-destroy` composes destroy/show/test and never touches apply.
    # Both must come out byte-identical, or "it changed" above proves
    # nothing about apply in particular.
    (testHelpers.mkTest "composition-untouched-verbs-are-byte-identical"
      (retiredWs.plan.program == openWs.plan.program
        && retiredSdlc.cycle-destroy.program == openSdlc.cycle-destroy.program)
      ''retiring `apply` must leave `plan` and `cycle-destroy` untouched —
        without this the change-detection tests could pass on a builder that
        simply rebuilds everything'')
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
