# Tests — iroha.checks (the harness proves itself).
{ lib, iroha }:
let
  inherit (iroha)
    mkEvalChecks
    mkSuiteTree
    mkModuleEvalCheck
    mkBuildChecks
    buildAssert
    ;

  # A stand-in for `pkgs` in the build-tier tests. These assert on the
  # SHAPE and the REFUSALS of the declaration, which are decided at eval
  # time; actually running a builder is what `checks.<system>.iroha-build-checks`
  # in flake.nix does.
  fakePkgs = {
    runCommand = drvName: attrs: script: {
      inherit drvName attrs script;
    };
  };

  buildSuite = mkBuildChecks {
    name = "sample";
    assertions = [
      (buildAssert.succeeds {
        name = "true-succeeds";
        cmd = "true";
      })
      (buildAssert.fails {
        name = "false-fails";
        cmd = "false";
      })
    ];
  };

  buildDrv = buildSuite.asCheck fakePkgs;

  # `count` is the forcing position: any of mkBuildChecks' four structural
  # refusals fires when it is forced. `success = false` ⇒ refused.
  constructs = args: (builtins.tryEval (mkBuildChecks args).count).success;

  passing = mkEvalChecks {
    name = "passing";
    tests = {
      one = {
        expr = 1 + 1;
        expected = 2;
      };
      testAlreadyPrefixed = {
        expr = "x";
        expected = "x";
      };
    };
  };

  failing = mkEvalChecks {
    name = "failing";
    tests = {
      bad = {
        expr = 1 + 1;
        expected = 3;
      };
      good = {
        expr = true;
        expected = true;
      };
    };
  };

  tree = mkSuiteTree {
    name = "t";
    suites = {
      a = {
        ok = {
          expr = 1;
          expected = 1;
        };
      };
      b = {
        ok = {
          expr = 2;
          expected = 2;
        };
      };
    };
  };

  modCheck = mkModuleEvalCheck {
    name = "mod";
    modules = [
      {
        options.foo = lib.mkOption {
          type = lib.types.int;
          default = 4;
        };
      }
    ];
    asserts = [
      {
        path = [ "foo" ];
        expected = 4;
      }
    ];
  };

  rejectCheck = mkModuleEvalCheck {
    name = "reject";
    class = "nixos";
    modules = [
      (iroha.tag iroha.classes.homeManager {
        options.x = lib.mkOption {
          type = lib.types.int;
          default = 1;
        };
      })
    ];
    expectClassReject = true;
  };
in
{
  passing-suite-passes = {
    expr = passing.passed;
    expected = true;
  };
  passing-summary = {
    expr = passing.summary;
    expected = "2/2 passed";
  };
  name-normalization = {
    expr = builtins.sort builtins.lessThan (builtins.attrNames passing.tests);
    expected = [
      "test:one"
      "testAlreadyPrefixed"
    ];
  };
  failing-suite-fails = {
    expr = failing.passed;
    expected = false;
  };
  failing-collects-only-failures = {
    expr = map (f: f.name) failing.failures;
    expected = [ "test:bad" ];
  };
  failure-carries-expected-and-result = {
    expr =
      let
        f = builtins.head failing.failures;
      in
      {
        inherit (f) expected result;
      };
    expected = {
      expected = 3;
      result = 2;
    };
  };
  suite-tree-aggregates = {
    expr = tree.passed && tree.all.summary == "2/2 passed";
    expected = true;
  };
  suite-tree-flat-names = {
    expr = builtins.sort builtins.lessThan (builtins.attrNames tree.all.tests);
    expected = [
      "test:a:ok"
      "test:b:ok"
    ];
  };
  suite-tree-name-collision-throws = {
    # `foo` and `test:foo` normalize to one name — silently dropping a
    # case would be an unsound total, so the tree throws instead.
    expr =
      (builtins.tryEval
        (mkSuiteTree {
          name = "c";
          suites.s = {
            foo = {
              expr = 1;
              expected = 1;
            };
            "test:foo" = {
              expr = 2;
              expected = 2;
            };
          };
        }).summary
      ).success;
    expected = false;
  };
  # ── gate: the eval-time face of the same verdict ────────────────────
  # `asCheck` decides nothing until a derivation is BUILT. `gate` decides
  # on selection, so a consumer can seq it onto a shipping output where no
  # command has to be run. Three directions, all required — a gate that
  # throws on everything is as useless as one that never throws.
  gate-passes-and-counts = {
    # Green: yields the assertion count, so `builtins.seq` is cheap and
    # the value itself says how many subjects were actually checked.
    expr = passing.gate;
    expected = 2;
  };
  gate-throws-on-a-failing-suite = {
    expr = (builtins.tryEval failing.gate).success;
    expected = false;
  };
  gate-refuses-an-EMPTY-suite = {
    # ★ THE LOAD-BEARING HALF. `lib.runTests { }` returns `[ ]`, so an
    # empty suite is `passed = true` — the strongest-looking evidence
    # available, proving nothing (★★ UNREPRESENTABILITY tier ⊥, "vacuous"
    # subclass). Without this arm a fleet with zero invariants sails
    # through the gate green.
    expr =
      let
        empty = mkEvalChecks {
          name = "empty";
          tests = { };
        };
      in
      {
        # The trap, stated as data: `passed` really is true here.
        passedIsVacuouslyTrue = empty.passed;
        gateRefuses = (builtins.tryEval empty.gate).success;
      };
    expected = {
      passedIsVacuouslyTrue = true;
      gateRefuses = false;
    };
  };
  suite-tree-exposes-the-gate = {
    expr = tree.gate;
    expected = 2;
  };

  asCheck-refuses-an-EMPTY-suite = {
    # ★ The sibling of `gate-refuses-an-EMPTY-suite`, and it was MISSING
    # until 2026-07-28 — `gate` refused an empty suite while `asCheck`
    # happily emitted the green "0/0 passed" derivation. Since `asCheck`
    # is the documented way to reach `checks.<system>.*`, the refusal
    # covered the face consumers mostly do NOT use. Both faces, or the
    # guard is decided by which one the caller picked.
    expr =
      let
        empty = mkEvalChecks {
          name = "empty";
          tests = { };
        };
      in
      (builtins.tryEval (empty.asCheck { runCommand = _: _: _: null; })).success;
    expected = false;
  };
  asCheck-still-builds-a-NON-empty-suite = {
    # The other direction: a refusal that fires on everything is as
    # useless as one that never fires.
    expr = (builtins.tryEval (passing.asCheck { runCommand = n: _: _: n; })).value;
    expected = "iroha-check-passing";
  };

  # ── mkBuildChecks — the BUILD-tier sibling ──────────────────────────
  build-checks-counts-its-assertions = {
    expr = buildSuite.count;
    expected = 2;
  };
  build-checks-gate-yields-the-count = {
    expr = buildSuite.gate;
    expected = 2;
  };
  build-checks-refuses-an-EMPTY-assertion-list = {
    # Same tier ⊥ "vacuous" subclass the eval tier refuses: a build check
    # over zero subjects always succeeds.
    expr = constructs {
      name = "empty";
      assertions = [ ];
    };
    expected = false;
  };
  build-checks-refuses-duplicate-assertion-names = {
    # mkSuiteTree's reason: a silently-collapsed case is an unsound total.
    expr = constructs {
      name = "dup";
      assertions = [
        (buildAssert.succeeds { name = "same"; cmd = "true"; })
        (buildAssert.succeeds { name = "same"; cmd = "true"; })
      ];
    };
    expected = false;
  };
  build-checks-refuses-a-non-record-assertion = {
    # A raw shell string is exactly the hand-rolled shape this replaces.
    expr = constructs {
      name = "raw";
      assertions = [ "grep -q thing file" ];
    };
    expected = false;
  };
  build-checks-accepts-a-well-formed-declaration = {
    expr = constructs {
      name = "ok";
      assertions = [ (buildAssert.succeeds { name = "a"; cmd = "true"; }) ];
    };
    expected = true;
  };
  build-checks-owns-dollar-out = {
    # ★ THE STRUCTURAL HALF. The caller never writes `$out`; the helper
    # does, and ONLY after the failure counter has been tested. So the
    # `touch $out` regardless-of-the-verdict shape has no code path at a
    # call site. Assert the generated script really has that order.
    expr =
      let
        s = buildDrv.script;
        failExit = ''if [ "$_iroha_fail" -ne 0 ]'';
      in
      {
        exitsOnFailure = lib.hasInfix failExit s;
        writesOut = lib.hasInfix ''mkdir -p "$out"'' s;
        # The ONLY $out write is after the exit branch.
        outWriteIsAfterTheExit =
          (builtins.length (lib.splitString failExit (lib.head (lib.splitString ''mkdir -p "$out"'' s)))) == 2;
      };
    expected = {
      exitsOnFailure = true;
      writesOut = true;
      outWriteIsAfterTheExit = true;
    };
  };
  build-checks-runs-every-assertion-before-failing = {
    # Aggregate-before-assert: the exit is once, at the end — not inside
    # the per-assertion branch, which would report only the first break.
    expr =
      let
        s = buildDrv.script;
      in
      {
        bothPresent = lib.hasInfix "true-succeeds" s && lib.hasInfix "false-fails" s;
        countsRatherThanExits = lib.hasInfix "_iroha_fail=$((_iroha_fail + 1))" s;
        exitCountIsOne = (builtins.length (lib.splitString "exit 1" s)) == 2;
      };
    expected = {
      bothPresent = true;
      countsRatherThanExits = true;
      exitCountIsOne = true;
    };
  };
  build-assert-fails-inverts-the-exit-status = {
    expr = (buildAssert.fails { name = "n"; cmd = "grep -q x f"; }).run;
    expected = "! { grep -q x f ; }";
  };
  build-assert-quotes-its-arguments = {
    # A pattern with shell metacharacters must reach grep intact rather
    # than being re-interpreted by the builder's shell.
    expr = (buildAssert.fileContains {
      name = "q";
      path = "a b.txt";
      pattern = "foo|bar";
    }).run;
    expected = "grep -Eq -- 'foo|bar' 'a b.txt'";
  };

  module-eval-check-asserts = {
    expr = (mkEvalChecks { name = "m"; tests = modCheck; }).passed;
    expected = true;
  };
  module-eval-class-reject-is-a-test = {
    expr = (mkEvalChecks { name = "r"; tests = rejectCheck; }).passed;
    expected = true;
  };
}
