# iroha.checks — the alphabet's proof harness (self-hosting: every other
# letter's test suite is expressed through this letter).
#
# Exports (pure { lib }, zero pkgs; pkgs is bound late, only in asCheck):
#
#   mkEvalChecks :: { name, tests } -> suite
#     tests :: attrsOf { expr, expected }   (nix-unit shape; names need NOT
#                                            start with "test" — normalized)
#     suite = {
#       tests     — normalized tests (every name prefixed "test", nix-unit
#                   compatible: `nix-unit --expr ...` runs them unchanged);
#       results   — lib.runTests output (list of failed cases);
#       failures  — [ { name, expected, result } ];
#       passed    — bool;
#       summary   — "N/M passed";
#       asCheck   — pkgs -> derivation. Builds iff all pass; on failure the
#                   build log lists EVERY failed case (aggregate-before-
#                   assert, per the verification-matrix forcing rule).
#       gate      — the SAME verdict as a pure EVAL-time value. Forcing it
#                   throws (naming every failing case, and refusing an
#                   EMPTY suite) or yields the assertion count. `asCheck`
#                   only decides something when a derivation is BUILT;
#                   `gate` decides on selection, so it can be seq'd onto a
#                   shipping output where no command has to be run.
#                   TIER: eval-rejected, not truly-unrepresentable.
#     }
#
#   mkSuiteTree :: { name, suites :: attrsOf (attrsOf { expr, expected }) } -> tree
#     Aggregates per-letter suites: flattens "<suite>.<case>" into one
#     mkEvalChecks with names "test:<suite>:<case>"; carries per-suite
#     results too.
#     tree = { suites, all (a suite), passed, summary, gate, asCheck }.
#
#   mkBuildChecks :: { name, assertions, prelude ? "", nativeBuildInputs ? …,
#                      env ? {} } -> { assertions, count, gate, asCheck }
#     The BUILD-tier sibling of mkEvalChecks: proves properties of a real
#     ARTIFACT (a built image's layers, a generated file's bytes, a tool's
#     exit status) rather than of a pure value. The caller declares WHAT
#     must hold as typed `assertion` records and NEVER writes `$out` —
#     see the block above the implementation for why that is the whole
#     point.
#
#   buildAssert :: the typed assertion constructors fed to mkBuildChecks
#     (predicate / succeeds / fails / fileExists / fileContains /
#     fileLacks / outputContains).
#
#   mkModuleEvalCheck :: {
#     name,
#     modules            — list of modules under test;
#     class ? null       — evalModules class (rejects mismatched _class);
#     universe ? []      — option-universe modules (stubs or real HM/NixOS);
#     specialArgs ? {};
#     expectClassReject ? false — assert that evaluation THROWS (the _class
#                          rejection is itself a tested behavior);
#     asserts ? []       — [ { path :: [str], expected } ] checked against
#                          eval.config;
#   } -> attrsOf { expr, expected }    (feed into mkEvalChecks tests)
{ lib }:
let
  normalizeName = n: if lib.hasPrefix "test" n then n else "test:${n}";

  normalize = tests: lib.mapAttrs' (n: v: lib.nameValuePair (normalizeName n) v) tests;

  mkEvalChecks =
    { name, tests }:
    let
      tests' = normalize tests;
      results = lib.runTests tests';
      failures = map (f: {
        inherit (f) name;
        expected = f.expected;
        result = f.result;
      }) results;
      passed = results == [ ];
      total = builtins.length (builtins.attrNames tests');
      summary = "${toString (total - builtins.length results)}/${toString total} passed";
      renderFailure =
        f:
        "  FAIL ${f.name}\n    expected: ${builtins.toJSON f.expected}\n    got:      ${builtins.toJSON f.result}";
      report = lib.concatStringsSep "\n" (map renderFailure failures);

      # ── THE GATE — the verdict, forced at EVAL time ──────────────────
      #
      # `asCheck` is a DERIVATION: it decides nothing until something
      # BUILDS it (`nix flake check`, `nix build .#checks.<sys>.<name>`).
      # A repo that never runs those commands gets no verdict at all — a
      # private fleet with no CI, a `nixos-rebuild` that never looks at
      # `checks`. A declared-but-uninvoked check is not a weak gate; it is
      # nothing. `gate` is the same verdict as a pure VALUE, so a consumer
      # can force it on the way into a shipping output
      # (`builtins.seq suite.gate v`) where the workflow cannot route
      # around it: selecting the output throws, before a byte is built, on
      # any host, with no CI, no builder and no matching system.
      #
      # ★ NON-EMPTY SUBJECT SET is the load-bearing half, not a flourish.
      # `lib.runTests { }` returns `[ ]`, so `passed` is TRUE over zero
      # assertions — a suite with nothing in it reports the
      # strongest-looking evidence available while proving nothing
      # (★★ UNREPRESENTABILITY tier ⊥, "vacuous" subclass). Refuse it
      # rather than report it green.
      #
      # TIER: eval-rejected. Stronger than a CI gate (only-mitigated, and
      # vacuous wherever Actions never run — which is why this must not
      # depend on CI); weaker than truly-unrepresentable, because a Nix
      # `throw` is not a compile error. Do not round it up.
      gate =
        if total == 0 then
          throw "iroha gate (${name}): the suite is EMPTY — a gate over zero assertions proves nothing while looking like the strongest possible evidence. Refusing to evaluate."
        else if !passed then
          throw "iroha gate (${name}): FAILED — ${summary}\n${report}"
        else
          total;
    in
    {
      tests = tests';
      inherit
        results
        failures
        passed
        summary
        gate
        ;
      asCheck =
        pkgs:
        # ★ THE EMPTY ARM IS LOAD-BEARING HERE TOO, and it was missing until
        # 2026-07-28. `gate` refused an empty suite from the day it landed;
        # `asCheck` did not — and `passed = results == [ ]` is vacuously TRUE
        # over zero tests, so `mkEvalChecks { tests = { }; }` emitted the
        # GREEN derivation printing "0/0 passed". A consumer that wires
        # `asCheck` into `checks.<system>.*` (which is the documented way to
        # use this harness) and never forces `gate` therefore got the exact
        # vacuity `gate` exists to refuse, reported as the strongest-looking
        # evidence a CI log can show. Refuse it on BOTH faces of the verdict
        # or the refusal is only as good as which face the consumer happened
        # to pick. (★★ UNREPRESENTABILITY tier ⊥, "vacuous" subclass.)
        if total == 0 then
          throw "iroha check (${name}): the suite is EMPTY — a check derivation over zero assertions always builds green, which proves nothing. Refusing to construct it."
        else if passed then
          pkgs.runCommand "iroha-check-${name}" { } ''
            echo "iroha ${name}: ${summary}" > $out
          ''
        else
          pkgs.runCommand "iroha-check-${name}" { failureReport = "iroha ${name}: ${summary}\n${report}"; } ''
            echo "$failureReport" >&2
            exit 1
          '';
    };

  mkSuiteTree =
    { name, suites }:
    let
      # Collision guard: two cases in one suite that normalize to the same
      # flattened name (e.g. `foo` and `test:foo`) would silently collapse
      # into one — an unsound total in an aggregate-before-assert harness.
      # Detect by comparing counts before/after flattening and throw.
      normalizeSuite =
        suiteName: tests:
        let
          renamed = lib.mapAttrs' (
            n: v: lib.nameValuePair (lib.removePrefix "test:" (normalizeName n)) v
          ) tests;
        in
        if builtins.length (builtins.attrNames renamed) != builtins.length (builtins.attrNames tests) then
          throw "iroha.checks.mkSuiteTree: suite '${suiteName}' has case names that collide after normalization (a `foo` next to a `test:foo`) — rename one; a silently dropped case is an unsound total."
        else
          renamed;
      flat = lib.concatMapAttrs (
        suiteName: tests:
        lib.mapAttrs' (caseName: v: lib.nameValuePair "test:${suiteName}:${caseName}" v) (
          normalizeSuite suiteName tests
        )
      ) suites;
      all = mkEvalChecks {
        inherit name;
        tests = flat;
      };
    in
    {
      suites = lib.mapAttrs (
        suiteName: tests:
        mkEvalChecks {
          name = "${name}-${suiteName}";
          inherit tests;
        }
      ) suites;
      inherit all;
      inherit (all) passed summary gate;
      asCheck = all.asCheck;
    };

  # ── buildAssert — the typed verdict vocabulary ───────────────────────
  #
  # An assertion is a RECORD, never a line of prose: `{ name; run; detail }`
  # where `run` is shell whose EXIT STATUS is the verdict (0 = pass). The
  # caller says what must hold; mkBuildChecks generates the reporting, the
  # aggregation and the `exit 1`.
  #
  # `predicate` is the escape hatch for a genuinely bespoke shell test.
  # Reach for a named constructor first: a constructor cannot be written
  # with its verdict already discarded, and `predicate` can (`run = "grep
  # x f || true"` always exits 0). That residual is why this helper is
  # tier-honest about closing the DISCARDED subclass at the derivation
  # boundary, not inside an arbitrary shell fragment.
  buildAssert = rec {
    predicate =
      {
        name,
        run,
        detail ? "",
      }:
      {
        inherit name run detail;
      };

    succeeds =
      {
        name,
        cmd,
        detail ? "",
      }:
      predicate {
        inherit name detail;
        run = cmd;
      };

    # Negative controls are first-class: a suite of only-positive
    # assertions cannot tell "the property holds" from "the harness sees
    # nothing" (★★ UNREPRESENTABILITY tier ⊥).
    fails =
      {
        name,
        cmd,
        detail ? "",
      }:
      predicate {
        inherit name;
        detail = if detail != "" then detail else "expected a NON-ZERO exit, got 0";
        run = "! { ${cmd} ; }";
      };

    fileExists =
      {
        name,
        path,
        detail ? "",
      }:
      predicate {
        inherit name;
        detail = if detail != "" then detail else "expected file to exist: ${path}";
        run = "test -e ${lib.escapeShellArg path}";
      };

    fileContains =
      {
        name,
        path,
        pattern,
        detail ? "",
      }:
      predicate {
        inherit name;
        detail = if detail != "" then detail else "expected ${path} to match /${pattern}/";
        run = "grep -Eq -- ${lib.escapeShellArg pattern} ${lib.escapeShellArg path}";
      };

    fileLacks =
      {
        name,
        path,
        pattern,
        detail ? "",
      }:
      predicate {
        inherit name;
        detail = if detail != "" then detail else "expected ${path} NOT to match /${pattern}/";
        run = "! grep -Eq -- ${lib.escapeShellArg pattern} ${lib.escapeShellArg path}";
      };

    outputContains =
      {
        name,
        cmd,
        pattern,
        detail ? "",
      }:
      predicate {
        inherit name;
        detail = if detail != "" then detail else "expected the output of `${cmd}` to match /${pattern}/";
        run = "{ ${cmd} ; } 2>&1 | grep -Eq -- ${lib.escapeShellArg pattern}";
      };
  };

  # ── mkBuildChecks — the BUILD-tier sibling of mkEvalChecks ───────────
  #
  # mkEvalChecks proves properties of pure VALUES. This proves properties
  # of REAL ARTIFACTS — the cases that need a builder, a sandbox and a
  # shell, which is exactly where a verdict gets DISCARDED. The hand-rolled
  # shape is:
  #
  #     pkgs.runCommand "x-check" { } ''
  #       grep -q thing file        # ← the verdict
  #       echo ok > $out            # ← thrown away, unconditionally
  #     ''
  #
  # That derivation is INDISTINGUISHABLE IN A CI LOG from one that works:
  # it is green, and it would be green if the subject were completely
  # broken. Reading the source finds it correct-looking; running the gate
  # finds it green. (★★ UNREPRESENTABILITY §II.3 tier ⊥, "discarded"
  # subclass.) The cure named there is a NON-IGNORABLE TYPED VERDICT, so:
  #
  #   • THE CALLER NEVER WRITES `$out`. This helper owns it and writes it
  #     ONLY on the pass branch, so `touch $out` regardless of the verdict
  #     has no code path at a call site. That is the structural half.
  #   • A verdict is a typed `buildAssert` record, not prose.
  #   • An EMPTY assertion list is REFUSED at eval time — a check over zero
  #     subjects reports the strongest-looking evidence available while
  #     proving nothing (the same tier ⊥, "vacuous" subclass, that
  #     `mkEvalChecks`'s `gate` refuses).
  #   • Duplicate assertion names are refused, for `mkSuiteTree`'s reason:
  #     a silently-collapsed case is an unsound total.
  #
  # Aggregate-before-assert, same rule as `asCheck`: EVERY assertion runs,
  # EVERY failure prints with its captured output, then the build fails
  # once — so one run reports every broken predicate, not just the first.
  #
  # TIER: only-mitigated-but-real (a build-phase `exit 1`), with the
  # structural discard closed at the derivation boundary and the vacuous
  # subject set eval-rejected. NOT truly-unrepresentable: `predicate` takes
  # shell, and shell can always be written to swallow its own verdict. Do
  # not round this up.
  mkBuildChecks =
    {
      name,
      assertions,
      prelude ? "",
      nativeBuildInputs ? (_: [ ]),
      env ? { },
    }:
    let
      isAssertion =
        a: builtins.isAttrs a && a ? name && a ? run && builtins.isString a.name && builtins.isString a.run;
      names = map (a: a.name) assertions;
      validated =
        if !(builtins.isList assertions) then
          throw "iroha.mkBuildChecks (${name}): `assertions` must be a LIST of buildAssert records — got ${builtins.typeOf assertions}."
        else if assertions == [ ] then
          throw "iroha.mkBuildChecks (${name}): the assertion list is EMPTY — a build check over zero subjects always succeeds, which is the strongest-looking evidence available and proves nothing. Refusing to construct it."
        else if !(builtins.all isAssertion assertions) then
          throw "iroha.mkBuildChecks (${name}): every assertion must be a `{ name :: str; run :: str; detail ? str }` record — build one with `iroha.buildAssert.*` rather than by hand."
        else if builtins.length (lib.unique names) != builtins.length names then
          throw "iroha.mkBuildChecks (${name}): duplicate assertion names (${lib.concatStringsSep ", " names}) — a silently-collapsed case is an unsound total; rename one."
        else
          assertions;
      count = builtins.length validated;

      renderOne = a: ''
        if ( set -e
        ${a.run}
        ) > "$_iroha_out" 2>&1; then
          echo "  PASS ${a.name}"
        else
          echo "  FAIL ${a.name}${lib.optionalString (a.detail or "" != "") " — ${a.detail}"}"
          sed 's/^/        /' "$_iroha_out" || true
          _iroha_fail=$((_iroha_fail + 1))
        fi
      '';

      script = ''
        set -uo pipefail
        _iroha_fail=0
        _iroha_out="$(mktemp)"
        echo "== iroha build-check ${name}: ${toString count} assertion(s) =="

        # The prelude runs under `set -e`: a failed SETUP must abort rather
        # than let every assertion fail confusingly against a half-built
        # subject. Filesystem effects and shell variables it sets survive
        # into the assertions (it is not a subshell).
        set -e
        ${prelude}
        set +e

        ${lib.concatStringsSep "\n" (map renderOne validated)}

        if [ "$_iroha_fail" -ne 0 ]; then
          echo "== ${name}: $_iroha_fail of ${toString count} assertion(s) FAILED =="
          exit 1
        fi
        echo "== ${name}: ${toString count}/${toString count} passed =="
        mkdir -p "$out"
        echo "iroha build-check ${name}: ${toString count}/${toString count} passed" > "$out/result"
      '';
    in
    {
      assertions = validated;
      inherit count script;
      # The eval-time face: forcing it validates the declaration (empty /
      # malformed / duplicate-named) without needing a builder.
      gate = count;
      asCheck =
        pkgs:
        pkgs.runCommand "iroha-build-check-${name}" (
          {
            nativeBuildInputs = nativeBuildInputs pkgs;
          }
          // env
        ) script;
    };

  mkModuleEvalCheck =
    {
      name,
      modules,
      class ? null,
      universe ? [ ],
      specialArgs ? { },
      expectClassReject ? false,
      asserts ? [ ],
    }:
    let
      eval = lib.evalModules (
        {
          modules = universe ++ modules;
          inherit specialArgs;
        }
        // lib.optionalAttrs (class != null) { inherit class; }
      );
      # Force enough of the evaluation that a class mismatch (a throw inside
      # module collection) surfaces under tryEval. NOTE this probe is
      # SHALLOW by design: it proves the module graph merges and the option
      # names resolve — an option whose VALUE throws still passes
      # "<name>:evaluates". Deep value proof is what `asserts` entries are
      # for; assert every load-bearing path.
      forced = builtins.tryEval (builtins.seq (builtins.attrNames eval.config) true);
    in
    if expectClassReject then
      {
        "${name}:class-rejected" = {
          expr = forced.success;
          expected = false;
        };
      }
    else
      lib.listToAttrs (
        map (
          a:
          lib.nameValuePair "${name}:${lib.concatStringsSep "." a.path}" {
            expr = lib.attrByPath a.path (throw "iroha.mkModuleEvalCheck(${name}): config path ${lib.concatStringsSep "." a.path} does not exist") eval.config;
            expected = a.expected;
          }
        ) asserts
      )
      // {
        "${name}:evaluates" = {
          expr = forced.success;
          expected = true;
        };
      };
in
{
  inherit
    mkEvalChecks
    mkSuiteTree
    mkModuleEvalCheck
    mkBuildChecks
    buildAssert
    ;
}
