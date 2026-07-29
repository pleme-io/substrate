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
        if passed then
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
  inherit mkEvalChecks mkSuiteTree mkModuleEvalCheck;
}
