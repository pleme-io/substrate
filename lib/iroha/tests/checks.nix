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
  module-eval-check-asserts = {
    expr = (mkEvalChecks { name = "m"; tests = modCheck; }).passed;
    expected = true;
  };
  module-eval-class-reject-is-a-test = {
    expr = (mkEvalChecks { name = "r"; tests = rejectCheck; }).passed;
    expected = true;
  };
}
