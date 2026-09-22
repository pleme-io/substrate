# Tests for lib/build/rust/workspace-tests.nix — the lockfile path's opt-in
# `cargo test` runner — and for its wiring through lockfile-builder.nix and
# tool-release.nix (the builder behind every `substrate.rust.<shape>`).
#
# ── THREE CHECKS, THREE QUESTIONS ──────────────────────────────────────
#
#   asCheck      (pure eval)  Is the runner's SURFACE right? Config
#                             validation, the exact argv, the receipt, no
#                             injected profile, and — the regression pin —
#                             that `substrate.rust.<shape> { tests.cargo … }`
#                             yields `checks.tests` while an undeclaring
#                             consumer's check set is unchanged.
#   e2e          (build)      Does it RUN? The fixture workspace's tests,
#                             dev-dependencies (a path member AND a registry
#                             crate), the workspace [profile] and a doctest,
#                             under `cargo test --frozen` in the sandbox.
#   negativeControl (build)   Can it FAIL, and did every leg really run? The
#                             same fixture with the lever set must fail with
#                             cargo's exit status, and its log must name each
#                             property's test as having run.
#
# ── WHY THE NEGATIVE CONTROL CARRIES THE EVIDENCE ──────────────────────
#
# A green `e2e` alone is consistent with cargo having run zero tests — a
# fixture that silently lost its tests, a filter that matched nothing. The
# failing run's log is the only place the harness prints every test NAME
# with its verdict, so that is where the anti-vacuity assertions live:
# `profile_is_honoured ... ok`, `dev_dependencies_resolve ... ok`, the
# doctest line, and the lever's `FAILED`. Same fixture, same runner, one env
# var apart — so the green run executed the same set.
#
# Usage (report form):
#   nix eval --impure --file lib/build/rust/tests/workspace-tests-test.nix \
#     --apply 'f: (f { pkgs = import <nixpkgs> {}; }).summary'
# Wired via `asCheck pkgs`, `e2e` and `negativeControl` in substrate's
# flake `checks`.
{
  pkgs,
  lib ? pkgs.lib,
  fixture ? ./fixtures/workspace-tests,
}:

let
  testHelpers = import ../../../util/test-helpers.nix { inherit lib; };

  # The REAL modules, not copies.
  wt = import ../workspace-tests.nix { inherit lib; };
  builder = import ../lockfile-builder.nix { inherit pkgs lib; };
  quirkApply = import ../quirk-apply.nix { inherit lib; };

  throws = expr: !(builtins.tryEval expr).success;
  throwsDeep = expr: !(builtins.tryEval (builtins.deepSeq expr expr)).success;
  # `true` iff the boolean evaluates, fully, to true — so a regression fails
  # the one test by name rather than aborting the suite with an eval error.
  succeeds = expr: let r = builtins.tryEval (builtins.deepSeq expr expr); in r.success && r.value;

  # A CI gate shaped like engenho's test.yml: all targets, then doctests
  # (`--all-targets` excludes doctests, so they are a second run).
  ciRuns = [
    { args = [ "--workspace" "--all-targets" ]; }
    { args = [ "--workspace" "--doc" ]; }
  ];

  # ── The subjects ──────────────────────────────────────────────────────
  e2e = builder.mkWorkspaceTests {
    src = fixture;
    name = "wt-fixture";
    config.runs = ciRuns;
  };

  # Doctests FIRST so their verdict is logged before the failing run, and
  # `--no-fail-fast` so the integration test still runs after the unit
  # tests fail — every property's test name then lands in one log.
  negativeSubject = builder.mkWorkspaceTests {
    src = fixture;
    name = "wt-fixture-red";
    config = {
      runs = [
        { args = [ "--workspace" "--doc" ]; }
        { args = [ "--workspace" "--all-targets" "--no-fail-fast" ]; }
      ];
      env.WT_FIXTURE_MUST_FAIL = "1";
    };
  };

  negativeControl = pkgs.testers.testBuildFailure' {
    drv = negativeSubject;
    name = "rust-workspace-tests-negative-control";
    # cargo test's own status for "tests failed" — propagated, not
    # re-mapped, which is what proves the phase has no discarding pipe.
    expectedBuilderExitCode = 101;
    expectedBuilderLogEntries = [
      "wt-core/src/lib.rs - answer (line 3) ... ok"
      "test tests::profile_is_honoured ... ok"
      "test dev_dependencies_resolve ... ok"
      "test tests::negative_control_lever_is_unset ... FAILED"
    ];
  };

  # Constants restated rather than recomputed, so an assertion cannot pass by
  # comparing the subject with itself.
  expectedCiArgv = [
    [ "test" "--frozen" "--workspace" "--all-targets" ]
    [ "test" "--frozen" "--workspace" "--doc" ]
  ];

  defaultCfg = wt.normalize "demo" { };

  # tool-release.nix is the builder every `substrate.rust.<shape>` lands in.
  # Driven directly (gen = null, crate2nix unused on this path) so the pin
  # does not depend on fetching gen.
  toolRelease = import ../tool-release.nix {
    nixpkgs = pkgs.path;
    system = pkgs.stdenv.hostPlatform.system;
    crate2nix = null;
  };
  outputsFor = extra: toolRelease ({
    toolName = "wt-fixture";
    src = fixture;
    repo = "pleme-io/substrate";
    shape = "workspace";
  } // extra);
  consumer = extra: (outputsFor extra).checks;
  undeclared = consumer { };
  optedIn = consumer { tests.cargo.runs = ciRuns; };

  # Every package name the dev shell puts in front of a developer — and in
  # front of CI, which runs the tests INSIDE it (`nix develop … -c nextest`).
  shellNames = extra: let shell = (outputsFor extra).devShells.default; in
    map (d: d.name or "?") ((shell.buildInputs or [ ]) ++ (shell.nativeBuildInputs or [ ]));
  declaringSystemLibs = {
    runs = ciRuns;
    nativeBuildInputs = [ "pkg-config" ];
    buildInputs = [ "openssl" ];
  };

  tests = [
    # ── Config: defaults and the exact argv ────────────────────────────
    (testHelpers.mkTest "default-is-one-workspace-run"
      (defaultCfg.runs == [ { args = [ "--workspace" ]; harnessArgs = [ ]; } ])
      "an empty `tests.cargo = { }` must mean exactly `cargo test --workspace`")

    (testHelpers.mkTest "argv-is-frozen-and-ordered"
      (map wt.argvFor (wt.normalize "demo" { runs = ciRuns; }).runs == expectedCiArgv)
      "every run must be `cargo test --frozen <args>`, in declaration order")

    (testHelpers.mkTest "harness-args-follow-double-dash"
      (wt.argvFor (builtins.head (wt.normalize "demo" {
        runs = [ { args = [ "-p" "x" ]; harnessArgs = [ "--test-threads=1" ]; } ];
      }).runs) == [ "test" "--frozen" "-p" "x" "--" "--test-threads=1" ])
      "harness arguments must reach the test binary, after `--`, never cargo")

    (testHelpers.mkTest "quirk-tools-fold-through-the-build-dispatcher"
      (wt.quirkToolNames quirkApply.applyQuirks {
        a = { quirks = [
          { kind = "native-build-inputs"; packages = [ "protobuf" ]; }
          { kind = "force-cfg"; cfg = "not_a_tool"; }
        ]; };
        b = { quirks = [ { kind = "native-build-inputs"; packages = [ "protobuf" "cmake" ]; } ]; };
        c = { };
      } == [ "protobuf" "cmake" ])
      "every native-build-inputs quirk's tools must reach the runner, once each, and no other quirk kind")

    # ── The derivation: what actually executes ─────────────────────────
    (testHelpers.mkTest "build-phase-runs-each-declared-invocation"
      (lib.hasInfix "cargo test --frozen --workspace --all-targets\ncargo test --frozen --workspace --doc" e2e.buildPhase)
      "the build phase must be exactly one `cargo test` line per run, in order, with nothing between them")

    (testHelpers.mkTest "no-pipe-in-build-phase"
      (!(lib.hasInfix "|" e2e.buildPhase))
      "a pipe in the phase would report the last stage's status, not cargo's")

    (testHelpers.mkTest "runner-injects-no-profile"
      (!(lib.hasInfix "--release" e2e.buildPhase)
        && !(lib.hasInfix "--profile" e2e.buildPhase)
        && !(lib.any (n: lib.hasPrefix "CARGO_PROFILE_" n) (builtins.attrNames e2e.drvAttrs)))
      "the runner must not choose a profile — cargo reads the workspace's [profile.*] itself")

    (testHelpers.mkTest "vendors-from-the-workspace-lock"
      (toString e2e.cargoDeps.lockFile == toString (fixture + "/Cargo.lock"))
      "the vendor dir must be built from the workspace's own Cargo.lock")

    (testHelpers.mkTest "receipt-records-the-invocations"
      ((builtins.fromJSON e2e.receipt).invocations == map (a: [ "cargo" ] ++ a) expectedCiArgv
        && (builtins.fromJSON e2e.receipt).runner == "cargo-test-vendored")
      "the receipt must name exactly the commands the phase ran")

    (testHelpers.mkTest "lockfile-builder-exports-the-same-runner"
      ((builder.mkWorkspaceTests { src = fixture; name = "same"; }).drvPath
        == (wt.mkWorkspaceTests pkgs { src = fixture; name = "same"; }).drvPath)
      "lockfile-builder's export must be this runner, not a second copy")

    (testHelpers.mkTest "unnamed-workspace-gets-a-valid-store-name"
      (lib.hasSuffix "-cargo-test-0" (builder.mkWorkspaceTests { src = fixture; name = "<unnamed-workspace>"; }).name)
      "mkProject's default name must not produce an invalid store path")

    # ── THE REGRESSION PIN: substrate.rust.<shape> → checks.tests ──────
    (testHelpers.mkTest "opted-in-consumer-gets-checks-tests"
      (succeeds (optedIn ? tests && optedIn.tests.passthru.argv == expectedCiArgv))
      "`substrate.rust.workspace { tests.cargo … }` must emit checks.tests running the declared cargo invocations")

    (testHelpers.mkTest "opted-in-tests-come-from-lockfile-builder-runTests"
      (succeeds (optedIn ? tests && lib.hasPrefix "wt-fixture-cargo-test" optedIn.tests.name))
      "on the lockfile path checks.tests must be lockfile-builder's runner for this workspace")

    (testHelpers.mkTest "undeclared-consumer-is-unchanged"
      (builtins.attrNames undeclared == [ "build" ])
      "a consumer that did not opt in must get exactly the pre-runner check set")

    # ── THE SECOND CONSUMER OF THE SAME DECLARATION: the dev shell ─────
    # `tests.cargo.{nativeBuildInputs,buildInputs}` reached checks.tests and
    # stopped there, while CI runs those tests inside `nix develop` — so a
    # declared system library was present exactly where it was not needed.
    # Measured 2026-09-22 on pleme-io/engenho: pkg-config + openssl declared,
    # neither in the shell, openssl-sys fell through to ubuntu's /usr/include,
    # and auto-release was red for 100 consecutive runs with checks.tests green.
    (testHelpers.mkTest "declared-test-system-libs-reach-the-dev-shell"
      (let names = shellNames { tests.cargo = declaringSystemLibs; }; in
        lib.any (lib.hasPrefix "pkg-config") names
        && lib.any (lib.hasPrefix "openssl") names)
      "a system library `tests.cargo` declares must be in the dev shell too — CI compiles those tests there")

    (testHelpers.mkTest "an-undeclaring-consumer-gets-no-system-libs"
      (let names = shellNames { }; in
        !(lib.any (lib.hasPrefix "openssl") names)
        && !(lib.any (lib.hasPrefix "pkg-config") names))
      "the negative control: the shell carries what was declared, so the test above cannot pass on a library that was there anyway")

    # ── Loud over silent ───────────────────────────────────────────────
    (testHelpers.mkTest "rejects-no-run"
      (throws (wt.normalize "demo" { runs = [ { args = [ "--no-run" ]; } ]; }))
      "`--no-run` compiles tests and runs none — a compile check under a test check's name")

    (testHelpers.mkTest "rejects-owned-hermeticity-flags"
      (throws (wt.normalize "demo" { runs = [ { args = [ "--offline" ]; } ]; })
        && throws (wt.normalize "demo" { runs = [ { args = [ "--locked" ]; } ]; }))
      "the runner owns --frozen; a restated hermeticity flag must throw")

    (testHelpers.mkTest "rejects-empty-runs"
      (throws (wt.normalize "demo" { runs = [ ]; }))
      "zero runs is a test check over an empty subject set")

    (testHelpers.mkTest "rejects-unknown-config-field"
      (throws (wt.normalize "demo" { run = [ ]; }))
      "a misspelled field must throw, not silently fall back to the default run")

    (testHelpers.mkTest "rejects-unknown-run-field"
      (throws (wt.normalize "demo" { runs = [ { arg = [ "--workspace" ]; } ]; }))
      "a misspelled run field must throw")

    (testHelpers.mkTest "rejects-non-string-args"
      (throws (wt.normalize "demo" { runs = [ { args = "--workspace"; } ]; }))
      "args must be a list of strings")

    (testHelpers.mkTest "rejects-unknown-nixpkgs-name"
      (throwsDeep (builder.mkWorkspaceTests {
        src = fixture;
        name = "demo";
        config.nativeBuildInputs = [ "no-such-nixpkgs-attribute-xyzzy" ];
      }).nativeBuildInputs)
      "a nativeBuildInputs name that is not a nixpkgs attribute must throw, naming it")

    (testHelpers.mkTest "rejects-missing-cargo-lock"
      (throws (builder.mkWorkspaceTests { src = fixture + "/wt-core"; name = "demo"; }).name)
      "without a Cargo.lock there is nothing to vendor or pin; the runner must refuse")
  ];

  result = testHelpers.runTests tests;
in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result e2e negativeControl;

  # Derivation form for `nix flake check`. Builds iff every test passes;
  # on failure the message names each failing test.
  asCheck = pkgs:
    if result.allPassed
    then pkgs.runCommand "rust-workspace-tests-test" { } ''
      echo "rust workspace-tests: ${result.summary}" > $out
    ''
    else throw ''
      rust workspace-tests tests FAILED (${result.summary}):
        - ${builtins.concatStringsSep "\n  - " result.failures}'';
}
