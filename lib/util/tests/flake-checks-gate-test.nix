# Pure eval tests for lib/util/flake-checks-gate.nix.
#
# This gate exists to catch a vacuous guard, so it must not be one itself.
# The two load-bearing tests are:
#
#   * `empty-check-set-throws` — the gate FAILS on the exact input it
#     exists to reject. A gate that returns a friendly string on zero
#     checks would be green over the defect.
#   * `gate-parses` — the file evaluates at all. The first version of this
#     policy lived inline in a YAML block scalar inside a shell
#     single-quoted argument and silently lost its Nix string delimiters,
#     i.e. it would have failed to PARSE in CI. A guard that cannot parse
#     never runs, which is indistinguishable from passing until you break
#     something on purpose and no red arrives.
#
# Usage:
#   nix eval -f lib/util/tests/flake-checks-gate-test.nix …
# Wired as a derivation via `asCheck pkgs` in substrate's flake checks.
{ lib }:

let
  testHelpers = import ../test-helpers.nix { inherit lib; };
  gatePath = ../flake-checks-gate.nix;
  gate = args: import gatePath args;

  sys = "x86_64-linux";
  populated = { ${sys} = { build = "/nix/store/B"; tests = "/nix/store/T"; }; };
  otherSystemOnly = { "aarch64-darwin" = { build = "/nix/store/B"; }; };

  throws = expr: !(builtins.tryEval (builtins.deepSeq expr expr)).success;

  verdict = checks: gate { system = sys; inherit checks; strict = false; };

  tests = [
    (testHelpers.mkTest "gate-parses"
      (builtins.isAttrs (verdict populated))
      "the gate file must evaluate — a policy that cannot parse never runs")

    # ── The defect it exists to catch ─────────────────────────────────
    (testHelpers.mkTest "empty-check-set-throws"
      (throws (gate { system = sys; checks = { }; }))
      "zero checks must be a LOUD failure — this is the whole point of the gate")

    (testHelpers.mkTest "absent-checks-output-throws"
      (throws (gate { system = sys; }))
      "a flake with no `checks` output at all must fail the same way, not error obscurely")

    (testHelpers.mkTest "checks-for-a-different-system-throws"
      (throws (gate { system = sys; checks = otherSystemOnly; }))
      "checks declared only for another system leave THIS runner's build unverified")

    (testHelpers.mkTest "empty-per-system-attrset-throws"
      (throws (gate { system = sys; checks = { ${sys} = { }; }; }))
      "an explicitly-empty per-system set is the flake-wrapper default and must fail too")

    # ── A green run states what it verified ───────────────────────────
    (testHelpers.mkTest "populated-check-set-passes"
      ((verdict populated).ok)
      "a flake with real checks must pass")

    (testHelpers.mkTest "success-message-names-every-check"
      (let m = (verdict populated).message;
       in lib.hasInfix "build" m && lib.hasInfix "tests" m && lib.hasInfix sys m)
      "the green must PRINT the checks it built — an opaque green is unauditable")

    (testHelpers.mkTest "strict-mode-returns-the-success-string"
      (lib.hasInfix "checks built by" (gate { system = sys; checks = populated; }))
      "strict mode must yield the summary string, so `nix eval --raw` prints it")

    # ── The failure message has to be actionable ──────────────────────
    (testHelpers.mkTest "failure-message-names-the-root-cause"
      (let m = (verdict { }).message;
       in lib.hasInfix "BUILDS only" m && lib.hasInfix "never compiled" m)
      "the refusal must explain WHY a zero-check flake is a false green, not just that it is")

    (testHelpers.mkTest "failure-message-names-the-fix"
      (let m = (verdict { }).message;
       in lib.hasInfix "checks.build" m && lib.hasInfix "flake-wrapper" m)
      "the refusal must name the concrete fixes, including the wrapper that forwards checks")

    (testHelpers.mkTest "failure-message-forbids-the-easy-out"
      (lib.hasInfix "Do not silence this" (verdict { }).message)
      "the refusal must close the obvious escape (deleting the workflow) explicitly")

    (testHelpers.mkTest "failure-message-names-the-system"
      (lib.hasInfix sys (verdict { }).message)
      "the refusal must name which system had no checks")
  ];

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  asCheck = pkgs:
    if result.allPassed
    then pkgs.runCommand "flake-checks-gate-test" { } ''
      echo "flake-checks-gate: ${result.summary}" > $out
    ''
    else throw ''
      flake-checks-gate tests FAILED (${result.summary}):
        - ${builtins.concatStringsSep "\n  - " result.failures}'';
}
