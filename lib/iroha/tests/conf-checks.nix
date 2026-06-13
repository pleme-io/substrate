# Tests — iroha.conf-checks (assert option VALUES on a BUILT config:
# expected/satisfies/present resolution, dotted-vs-list paths, the
# missing-path-is-a-failing-case-not-an-abort contract verified through
# iroha.mkEvalChecks, mkConfChecksFor across many configs, typed throws).
{ lib, iroha }:
let
  inherit (iroha) mkConfChecks mkConfChecksFor mkEvalChecks;

  # A fake "built config" — exactly the shape a nixosSystem `.config`
  # presents to an assertion: nested option values, already evaluated.
  builtConfig = {
    services.foo.enable = true;
    networking.hostName = "rio";
    systemd.services = {
      a = { };
    };
  };

  # Second fake config for the mkConfChecksFor case.
  builtConfig2 = {
    services.foo.enable = false;
    networking.hostName = "plo";
    systemd.services = {
      b = { };
    };
  };

  # ── canonical suites under test ───────────────────────────────────────
  # expected (pass), dotted path.
  expectedPass = mkConfChecks {
    name = "c";
    config = builtConfig;
    asserts = [
      {
        path = "services.foo.enable";
        expected = true;
      }
    ];
  };

  # expected (fail) — value differs.
  expectedFail = mkConfChecks {
    name = "c";
    config = builtConfig;
    asserts = [
      {
        path = "networking.hostName";
        expected = "wrong";
      }
    ];
  };

  # satisfies (pass + fail) over DISTINCT paths (so both cases survive the
  # listToAttrs key set and the mixed-aggregate is genuinely exercised).
  satisfies = mkConfChecks {
    name = "c";
    config = builtConfig;
    asserts = [
      {
        path = [
          "networking"
          "hostName"
        ];
        satisfies = v: lib.stringLength v == 3;
      }
      {
        path = "services.foo.enable";
        satisfies = v: v == false;
      }
    ];
  };

  # present — true for a set path, false for an absent one.
  presence = mkConfChecks {
    name = "c";
    config = builtConfig;
    asserts = [
      {
        path = "services.foo.enable";
        present = true;
      }
      {
        path = "services.absent.enable";
        present = false;
      }
    ];
  };

  # Missing path UNDER an expected assert -> a FAILING case (not an abort).
  missingUnderExpected = mkConfChecks {
    name = "c";
    config = builtConfig;
    asserts = [
      {
        path = "services.ghost.enable";
        expected = true;
      }
    ];
  };

  # Missing path UNDER a satisfies assert -> a FAILING case (and the
  # predicate is NEVER invoked on a sentinel — a predicate that throws on
  # any input must still yield a clean failing case, not an abort).
  missingUnderSatisfies = mkConfChecks {
    name = "c";
    config = builtConfig;
    asserts = [
      {
        path = "services.ghost.enable";
        satisfies = _: throw "must-never-be-called";
      }
    ];
  };

  # mkConfChecksFor across 2 configs — the assert fn reads each config.
  acrossConfigs = mkConfChecksFor {
    name = "fleet";
    configs = {
      rio = builtConfig;
      plo = builtConfig2;
    };
    asserts = cfg: [
      {
        path = "services.foo.enable";
        expected = cfg.services.foo.enable;
      }
    ];
  };
in
{
  # ── expected resolution: pass ────────────────────────────────────────
  expected-pass-emits-passing-case = {
    expr = (mkEvalChecks {
      name = "x";
      tests = expectedPass;
    }).passed;
    expected = true;
  };
  expected-case-name-is-name-colon-dotted-path = {
    expr = builtins.attrNames expectedPass;
    expected = [ "c:services.foo.enable" ];
  };
  expected-case-pair-shape = {
    expr = expectedPass."c:services.foo.enable";
    expected = {
      expr = true;
      expected = true;
    };
  };

  # ── expected resolution: fail (value differs) ────────────────────────
  expected-fail-emits-failing-case = {
    expr =
      let
        s = mkEvalChecks {
          name = "x";
          tests = expectedFail;
        };
      in
      {
        passed = s.passed;
        names = map (f: f.name) s.failures;
      };
    expected = {
      passed = false;
      names = [ "test:c:networking.hostName" ];
    };
  };

  # ── satisfies: predicate over the value ──────────────────────────────
  satisfies-pass-pair = {
    expr = satisfies."c:networking.hostName";
    expected = {
      expr = true;
      expected = true;
    };
  };
  satisfies-mixed-collects-only-the-failure = {
    # The first assert ("rio" len == 3) passes; the second (foo.enable ==
    # false, but it is true) fails. Aggregate reports exactly the one fail.
    expr =
      let
        s = mkEvalChecks {
          name = "x";
          tests = satisfies;
        };
      in
      {
        passed = s.passed;
        names = map (f: f.name) s.failures;
      };
    expected = {
      passed = false;
      names = [ "test:c:services.foo.enable" ];
    };
  };

  # ── present: true for set path, false for absent ─────────────────────
  present-true-for-set-path = {
    expr = presence."c:services.foo.enable";
    expected = {
      expr = true;
      expected = true;
    };
  };
  present-false-for-absent-path = {
    expr = presence."c:services.absent.enable";
    expected = {
      expr = false;
      expected = false;
    };
  };
  present-suite-passes = {
    expr = (mkEvalChecks {
      name = "x";
      tests = presence;
    }).passed;
    expected = true;
  };

  # ── missing path under expected -> FAILING case, NOT an abort ────────
  missing-under-expected-is-failing-case = {
    expr =
      let
        s = mkEvalChecks {
          name = "x";
          tests = missingUnderExpected;
        };
      in
      {
        passed = s.passed;
        names = map (f: f.name) s.failures;
        marker = missingUnderExpected."c:services.ghost.enable".expr;
      };
    expected = {
      passed = false;
      names = [ "test:c:services.ghost.enable" ];
      marker = "<iroha.conf-checks:MISSING:services.ghost.enable>";
    };
  };

  # ── missing path under satisfies -> failing case, predicate untouched ─
  missing-under-satisfies-never-calls-predicate = {
    expr =
      let
        s = mkEvalChecks {
          name = "x";
          tests = missingUnderSatisfies;
        };
      in
      {
        passed = s.passed;
        # if the predicate were invoked on the sentinel this would abort;
        # a clean false here proves it never ran.
        marker = missingUnderSatisfies."c:services.ghost.enable".expr;
      };
    expected = {
      passed = false;
      marker = "<iroha.conf-checks:MISSING:services.ghost.enable>";
    };
  };

  # ── mkConfChecksFor across 2 configs ─────────────────────────────────
  for-across-configs-names = {
    expr = builtins.sort builtins.lessThan (builtins.attrNames acrossConfigs);
    expected = [
      "fleet:plo:services.foo.enable"
      "fleet:rio:services.foo.enable"
    ];
  };
  for-across-configs-each-passes = {
    expr = (mkEvalChecks {
      name = "x";
      tests = acrossConfigs;
    }).passed;
    expected = true;
  };
  for-per-config-expected-reads-its-own-config = {
    expr = {
      rio = acrossConfigs."fleet:rio:services.foo.enable";
      plo = acrossConfigs."fleet:plo:services.foo.enable";
    };
    expected = {
      rio = {
        expr = true;
        expected = true;
      };
      plo = {
        expr = false;
        expected = false;
      };
    };
  };

  # ── dotted-string and list paths normalize identically ───────────────
  dotted-and-list-path-equivalent = {
    expr =
      let
        d = mkConfChecks {
          name = "c";
          config = builtConfig;
          asserts = [
            {
              path = "networking.hostName";
              expected = "rio";
            }
          ];
        };
        l = mkConfChecks {
          name = "c";
          config = builtConfig;
          asserts = [
            {
              path = [
                "networking"
                "hostName"
              ];
              expected = "rio";
            }
          ];
        };
      in
      d == l;
    expected = true;
  };

  # ── typed throws (lazy — force the throwing field) ───────────────────
  empty-asserts-throws = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq (mkConfChecks {
          name = "c";
          config = builtConfig;
          asserts = [ ];
        }) true
      )).success;
    expected = false;
  };
  missing-config-throws = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq (mkConfChecks {
          name = "c";
          asserts = [
            {
              path = "x";
              expected = 1;
            }
          ];
        }) true
      )).success;
    expected = false;
  };
  missing-name-throws = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq (mkConfChecks {
          config = builtConfig;
          asserts = [
            {
              path = "x";
              expected = 1;
            }
          ];
        }) true
      )).success;
    expected = false;
  };
  no-discriminant-throws = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq (mkConfChecks {
          name = "c";
          config = builtConfig;
          asserts = [ { path = "x"; } ];
        }) true
      )).success;
    expected = false;
  };
  two-discriminants-throws = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq (mkConfChecks {
          name = "c";
          config = builtConfig;
          asserts = [
            {
              path = "x";
              expected = 1;
              present = true;
            }
          ];
        }) true
      )).success;
    expected = false;
  };
  missing-path-key-throws = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq (mkConfChecks {
          name = "c";
          config = builtConfig;
          asserts = [ { expected = 1; } ];
        }) true
      )).success;
    expected = false;
  };
  satisfies-not-a-function-throws = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq (mkConfChecks {
          name = "c";
          config = builtConfig;
          asserts = [
            {
              path = "x";
              satisfies = 7;
            }
          ];
        }) true
      )).success;
    expected = false;
  };
  present-not-a-bool-throws = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq (mkConfChecks {
          name = "c";
          config = builtConfig;
          asserts = [
            {
              path = "x";
              present = "yes";
            }
          ];
        }) true
      )).success;
    expected = false;
  };
  for-empty-configs-throws = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq (mkConfChecksFor {
          name = "f";
          configs = { };
          asserts = _: [
            {
              path = "x";
              expected = 1;
            }
          ];
        }) true
      )).success;
    expected = false;
  };
  for-asserts-not-a-function-throws = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq (mkConfChecksFor {
          name = "f";
          configs = {
            a = builtConfig;
          };
          asserts = [
            {
              path = "x";
              expected = 1;
            }
          ];
        }) true
      )).success;
    expected = false;
  };
}
