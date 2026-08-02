# eval-suites.nix — the catalog of substrate's report-returning eval test
# suites, plus the gate that turns one into a pass/fail verdict.
#
# ── WHY THIS FILE EXISTS ────────────────────────────────────────────────
#
# substrate ships three families of eval test, and only two of them could
# be gated before this file:
#
#   A. self-evaluating   — `throw`s on the first failure, so
#      `nix-instantiate --eval --strict <file>` fails closed all by itself.
#      Already run by nix-tests.yml's first three jobs.
#
#   B. `{ lib }` + `asCheck pkgs` — wired into `checks.<system>.*` and run
#      by `nix build .#checks.<system>.<name>`. Wired 2026-07-28.
#
#   C. REPORT-RETURNING — the suite evaluates to a VALUE describing the
#      run (`{ total; passCount; failCount; allPassed; failures; }` from
#      util/test-helpers.nix's `runTests`, or an `allPassed` attr, or
#      `{ passed; total; }`). This family is the reason for this file, and
#      it carries a trap that families A and B do not:
#
#        `runTests` DOES NOT THROW ON FAILURE.
#
#      It returns `allPassed = false` and keeps going. So
#      `nix-instantiate --eval --strict lib/hm/tests.nix` exits 0 whether
#      65 tests pass or 65 tests fail — it only catches an EVALUATION
#      error. Wiring family C the way family A is wired would have added a
#      job that runs 830 assertions and gates on none of them: a guard that
#      is green because it never looks at the answer (★★ UNREPRESENTABILITY
#      tier ⊥, "discarded verdict" subclass). This gate reads the verdict.
#
# ── WHY A CATALOG AND NOT 22 INLINE `--expr`s ───────────────────────────
#
# Same reasoning as lib/util/flake-checks-gate.nix, which was first written
# inline in a workflow and silently lost its string delimiters: a Nix
# expression nested inside a YAML block scalar inside a shell-quoted
# argument has three layers of quoting, and a gate that fails to PARSE is a
# gate that never runs. Twenty-two such expressions is twenty-two chances
# to make that mistake. Here the policy is one reviewable Nix file and each
# workflow step is a single flat `--expr` naming one suite.
#
# It also buys the forcing-function below: because the catalog knows every
# suite's name, it can read the workflow and refuse to pass when a suite
# has been added here but never given a step. That is the exact defect this
# whole file repairs, made unable to recur.
#
# ── THE ANTI-VACUITY FLOOR (`min`) ─────────────────────────────────────
#
# Every entry declares `min` — the assertion count measured when it was
# wired. The gate fails when `total < min`, not only when a test fails, so
# a suite that silently SHRINKS (a `map` over a list that became empty, a
# block deleted in a refactor) turns red instead of reporting a smaller
# green. A suite that grows is fine; bump `min` when you mean it.
#
# ── CONSUMPTION ────────────────────────────────────────────────────────
#
#   nix-instantiate --eval --strict --expr \
#     'import ./lib/util/eval-suites.nix { only = "types/tests"; }'
#
# Throws (non-zero exit) on a failing assertion, on a shrunken suite, or on
# an unknown name. Returns a one-line summary on success. With `only =
# null` it returns the catalog's names, which is what the coverage
# forcing-function consumes.
{
  lib ? (import <nixpkgs> { }).lib,
  # Which suite to run. `null` returns catalog metadata instead.
  only ? null,
  # Set false to get the verdict as data rather than a throw. Used to
  # exercise the failure path without the caller having to die.
  strict ? true,
  # The workflow that must carry a step per catalog entry. Overridable so
  # the coverage check can be pointed at a fixture.
  workflow ? ../../.github/workflows/nix-tests.yml,
}:

let
  # ── Verdict extractors, one per result shape ────────────────────────
  #
  # Each returns `{ total; ok; failures; }`. `total` is how many assertions
  # were actually FORCED — the number `min` is compared against.

  # `runTests` from util/test-helpers.nix. The shape that does not throw.
  fromRunTests = r: {
    inherit (r) total failures;
    ok = r.allPassed;
  };

  # An attrset whose individual `test*` attrs each evaluate to `true` or
  # THROW, aggregated by an `allPassed` that forces every one of them.
  # `allPassed` here can only ever be `true` or die, so `ok` carries no
  # information on its own — `total` is what makes the entry meaningful,
  # which is why every such entry declares a `min`.
  fromAllPassed = r: {
    total = builtins.length (
      builtins.filter (n: builtins.substring 0 4 n == "test") (builtins.attrNames r)
    );
    ok = r.allPassed;
    failures = [ ];
  };

  # Same, but the suite counts its own assertions (they are generated, so
  # the attribute names do not enumerate them).
  fromAllPassedWithCount = countAttr: r: {
    total = r.${countAttr};
    ok = r.allPassed;
    failures = [ ];
  };

  # `{ passed; total; }`.
  fromPassedTotal = r: {
    inherit (r) total;
    ok = r.passed == r.total;
    failures = lib.optional (r.passed != r.total) "${toString (r.total - r.passed)} assertion(s) failed";
  };

  # A list of success strings; every element throws on failure, so reaching
  # a list at all means they all held. `--strict` is what forces them.
  fromThrowList = r: {
    total = builtins.length r;
    ok = true;
    failures = [ ];
  };

  # ── The catalog ─────────────────────────────────────────────────────
  #
  # `min` values were measured on 2026-07-28, the day each was wired.
  # DELIBERATELY ABSENT — see the header of the excluded suite for why:
  #   lib/infra/tests/wasm-compat-test.nix  (pending-vacuous-guard)
  suites = {
    # ── lib/types ────────────────────────────────────────────────────
    # ── wiring invariants ────────────────────────────────────────────
    # Seals the defect this campaign hand-fixed SEVEN times: a forge-push
    # provider that does not export DOCA_BIN. See the suite's own header.
    "util/forge-tool-env" = {
      min = 5;
      verdict = fromRunTests (import ./forge-tool-env-tests.nix { inherit lib; });
    };
    "types/tests" = {
      min = 79;
      verdict = fromRunTests (import ../types/tests.nix { inherit lib; });
    };
    "types/assertion-tests" = {
      min = 47;
      verdict = fromRunTests (import ../types/assertion-tests.nix);
    };
    # property-tests.nix is a LIBRARY of property checkers plus two
    # ready-to-run suites; `testRenderer` and `checkAllArchetypes` are
    # functions awaiting a renderer and are not runnable from here.
    "types/property-information-flow" = {
      min = 8;
      verdict = fromRunTests (import ../types/property-tests.nix).testInformationFlow;
    };
    "types/property-convergence-stages" = {
      min = 10;
      verdict = fromRunTests (import ../types/property-tests.nix).testConvergenceStages;
    };

    # ── lib/kube ─────────────────────────────────────────────────────
    "kube/tests" = {
      min = 57;
      verdict = fromAllPassed (import ../kube/tests.nix);
    };

    # ── lib/hm + lib/util ────────────────────────────────────────────
    "hm/tests" = {
      min = 65;
      verdict = fromRunTests (import ../hm/tests.nix);
    };
    "util/tests" = {
      min = 22;
      verdict = fromRunTests (import ./tests.nix);
    };

    # ── lib/infra ────────────────────────────────────────────────────
    "infra/tests" = {
      min = 105;
      verdict = fromRunTests (import ../infra/tests.nix);
    };
    "infra/convergence-improvements" = {
      min = 26;
      verdict = fromRunTests (import ../infra/tests/convergence-improvements-test.nix);
    };
    "infra/leptos-deploy" = {
      min = 30;
      verdict = fromRunTests (import ../infra/tests/leptos-deploy-test.nix { inherit lib; });
    };
    "infra/all-scaffolds" = {
      min = 26;
      verdict = fromAllPassed (import ../infra/tests/all-scaffolds-test.nix { inherit lib; });
    };
    "infra/scaffold" = {
      min = 15;
      verdict = fromAllPassed (import ../infra/tests/scaffold-test.nix { inherit lib; });
    };
    "infra/scaffold-completeness" = {
      min = 32;
      verdict = fromAllPassed (import ../infra/tests/scaffold-completeness-test.nix { inherit lib; });
    };
    "infra/scaffold-snapshot" = {
      min = 12;
      verdict = fromAllPassed (import ../infra/tests/scaffold-snapshot-test.nix { inherit lib; });
    };
    "infra/scaffold-compile" = {
      min = 52;
      verdict = fromAllPassedWithCount "testCount" (
        import ../infra/tests/scaffold-compile-test.nix { inherit lib; }
      );
    };

    # ── lib/build/shared ─────────────────────────────────────────────
    # These read `lib/build/<ecosystem>/quirk-apply.nix` across ecosystems,
    # which is why the workflow's path filter watches `lib/build/**` rather
    # than the three subtrees it used to name.
    "build/shared/dispatcher-coverage" = {
      min = 49;
      verdict = fromThrowList (import ../build/shared/dispatcher-coverage-test.nix { inherit lib; });
    };
    "build/shared/fleet-catalog-coverage" = {
      min = 103;
      verdict = fromThrowList (import ../build/shared/fleet-catalog-coverage-test.nix { inherit lib; });
    };
    "build/shared/quirk-applier" = {
      min = 19;
      verdict = fromThrowList (import ../build/shared/quirk-applier-test.nix { inherit lib; });
    };
    "build/shared/typed-dispatcher" = {
      min = 8;
      verdict = fromThrowList (import ../build/shared/typed-dispatcher-test.nix { inherit lib; });
    };

    # ── lib/build, remaining ─────────────────────────────────────────
    "build/nixos/tests" = {
      min = 38;
      verdict = fromRunTests (import ../build/nixos/tests.nix { });
    };
    "build/rust/spec-invariants" = {
      min = 11;
      verdict = fromPassedTotal (import ../build/rust/tests/spec-invariants-test.nix);
    };
    # The freshness tie for a committed crate2nix Cargo.nix. Three of its
    # 20 assertions are the RED RUN against a deliberately-stale fixture,
    # and five more pin the cases a freshness gate goes silently green on:
    # the empty subject set, a parser gap, and a directory-shaped generated
    # artifact. See the suite's own header.
    "build/rust/cargo-nix-tie" = {
      min = 20;
      verdict = fromPassedTotal (import ../build/rust/tests/cargo-nix-tie-test.nix);
    };
    "build/go/package-builder-ferrite" = {
      min = 16;
      verdict = fromPassedTotal (import ../build/go/tests/package-builder-ferrite-test.nix);
    };
  };

  names = builtins.attrNames suites;

  # ── The coverage forcing-function ───────────────────────────────────
  #
  # A catalog entry with no workflow step is invisible, which is the
  # original defect. Reading the workflow here makes "added to the catalog,
  # never wired" a red gate rather than a silent omission. Same trick as
  # `rust-shape`'s `known-set-covers-every-flake-call-site`, which reads
  # flake.nix to catch the closed set drifting from its call sites.
  workflowText = builtins.readFile workflow;
  unwired = builtins.filter (n: !(lib.hasInfix "only = \"${n}\"" workflowText)) names;
  coverage =
    if unwired == [ ] then
      {
        total = builtins.length names;
        ok = true;
        failures = [ ];
      }
    else
      {
        total = builtins.length names;
        ok = false;
        failures = map (n: "${n}: in the catalog, but no step in nix-tests.yml runs it") unwired;
      };

  # ── The gate ────────────────────────────────────────────────────────
  run =
    name:
    let
      entry =
        suites.${name} or (throw ''
          eval-suites: no suite named "${name}".
          Known: ${builtins.concatStringsSep ", " names}, coverage
        '');
      v = entry.verdict;
      shrunk = v.total < entry.min;
      ok = v.ok && !shrunk;
      detail =
        if shrunk then
          ''
            ${name}: the suite SHRANK — ${toString v.total} assertions ran, but
            ${toString entry.min} ran when it was wired. A suite that quietly
            loses tests reports a smaller green, which is why this is a
            failure and not a note. If the shrink is intended, lower `min` in
            lib/util/eval-suites.nix in the same commit.
          ''
        else
          ''
            ${name}: ${toString (builtins.length v.failures)} of ${toString v.total} assertions failed.
            ${builtins.concatStringsSep "\n" (map (f: "  - ${f}") v.failures)}
          '';
      success = "${name}: ${toString v.total} assertions passed (floor ${toString entry.min})";
    in
    if !strict then
      {
        inherit ok;
        inherit (v) total;
        message = if ok then success else detail;
      }
    else if ok then
      success
    else
      throw detail;

in
if only == null then
  {
    inherit names;
    count = builtins.length names;
  }
else if only == "coverage" then
  (
    if coverage.ok then
      "eval-suites: all ${toString coverage.total} catalogued suites have a step in nix-tests.yml"
    else if !strict then
      coverage
    else
      throw ''
        eval-suites: ${toString (builtins.length coverage.failures)} catalogued suite(s) run in NO job.

        ${builtins.concatStringsSep "\n" (map (f: "  - ${f}") coverage.failures)}

        A suite in the catalog with no workflow step is exactly the state
        this catalog exists to end: it looks wired and runs nowhere. Add a
        step to .github/workflows/nix-tests.yml, or remove the entry.
      ''
  )
else
  run only
