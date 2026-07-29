# Tests — iroha.checks (the harness proves itself).
{ lib, iroha }:
let
  inherit (iroha) mkEvalChecks mkSuiteTree mkModuleEvalCheck;

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

  module-eval-check-asserts = {
    expr = (mkEvalChecks { name = "m"; tests = modCheck; }).passed;
    expected = true;
  };
  module-eval-class-reject-is-a-test = {
    expr = (mkEvalChecks { name = "r"; tests = rejectCheck; }).passed;
    expected = true;
  };
}
