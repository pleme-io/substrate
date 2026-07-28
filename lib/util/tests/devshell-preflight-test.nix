# Pure eval tests for lib/util/devshell-preflight.nix.
#
# This gate's whole job is to convert an opaque `nix develop` crash into a
# named, actionable verdict, so the load-bearing tests are:
#
#   * `devenv-backed-throws` — it FAILS on the exact shape it exists to
#     diagnose (a devShell whose derivation name is "devenv-shell", which is
#     what a substrate pin older than e232917 still produces). A gate that
#     returned a friendly string here would be green over the defect.
#   * `unevaluable-devshell-throws` — a devShell that THROWS when forced is
#     classified rather than propagated. This is the state the stale-pin case
#     is actually in under a pure eval, and an unhandled throw here would
#     surface as the same raw trace the gate exists to replace.
#   * `ok-message-names-the-shell-it-checked` — a green states its subject.
#     Same discipline as flake-checks-gate.nix printing the checks it built:
#     an opaque green is unauditable.
#   * `gate-parses` — the file evaluates at all. A policy that cannot parse
#     never runs, which is indistinguishable from passing until you break
#     something on purpose and no red arrives.
#
# Usage:
#   nix eval -f lib/util/tests/devshell-preflight-test.nix …
# Wired as a derivation via `asCheck pkgs` in substrate's flake checks.
{ lib }:

let
  testHelpers = import ../test-helpers.nix { inherit lib; };
  gatePath = ../devshell-preflight.nix;
  gate = args: import gatePath args;

  sys = "x86_64-linux";

  # A plain `pkgs.mkShell` devShell — what substrate's Rust builders emit
  # since e232917 (`devenv = null` -> the plain fenix branch).
  fixed = { ${sys} = { default = { name = "nix-shell"; }; }; };

  # A devenv-backed devShell — what a substrate pin older than e232917
  # still produces, and what cannot be entered by the CI job.
  devenvBacked = { ${sys} = { default = { name = "devenv-shell"; }; }; };

  # A devShell that throws when forced. This is the PURE-eval face of the
  # same stale pin: `nix eval .#devShells.<sys>.default.name` threw
  # "devenv was not able to determine the current directory" on shikumi at
  # substrate fcd3514.
  exploding = { ${sys} = { default = { name = throw "devenv was not able to determine the current directory"; }; }; };

  # Declared, but under a different name than the job will ask for.
  otherName = { ${sys} = { ruby-eval = { name = "nix-shell"; }; }; };

  otherSystemOnly = { "aarch64-darwin" = { default = { name = "nix-shell"; }; }; };

  throws = expr: !(builtins.tryEval (builtins.deepSeq expr expr)).success;

  verdict = devShells:
    gate { system = sys; devshell = "default"; inherit devShells; strict = false; };

  tests = [
    (testHelpers.mkTest "gate-parses"
      (builtins.isAttrs (verdict fixed))
      "the gate file must evaluate — a policy that cannot parse never runs")

    # ── The defects it exists to catch ────────────────────────────────
    (testHelpers.mkTest "devenv-backed-throws"
      (throws (gate { system = sys; devshell = "default"; devShells = devenvBacked; }))
      "a devenv-backed devShell must be a LOUD, named failure — this is the whole point of the gate")

    (testHelpers.mkTest "unevaluable-devshell-throws"
      (throws (gate { system = sys; devshell = "default"; devShells = exploding; }))
      "a devShell that throws when forced must be classified, not propagated as a raw trace")

    (testHelpers.mkTest "missing-devshell-throws"
      (throws (gate { system = sys; devshell = "default"; devShells = otherName; }))
      "asking for a devShell this flake does not declare must fail before `nix develop` does")

    (testHelpers.mkTest "absent-devshells-output-throws"
      (throws (gate { system = sys; devshell = "default"; }))
      "a flake with no `devShells` output at all must fail the same way, not error obscurely")

    (testHelpers.mkTest "devshells-for-another-system-throws"
      (throws (gate { system = sys; devshell = "default"; devShells = otherSystemOnly; }))
      "a devShell declared only for another system leaves THIS runner unable to enter one")

    # ── Verdicts are typed, not stringly guessed ──────────────────────
    (testHelpers.mkTest "verdict-devenv-backed-is-classified"
      ((verdict devenvBacked).verdict == "DevenvBacked")
      "the devenv case must be its own verdict so the message can name its specific cure")

    (testHelpers.mkTest "verdict-unevaluable-is-classified"
      ((verdict exploding).verdict == "Unevaluable")
      "a throwing devShell is a distinct verdict from a devenv-named one")

    (testHelpers.mkTest "verdict-missing-is-classified"
      ((verdict otherName).verdict == "Missing")
      "a wrong `devshell:` input is a distinct verdict from a broken shell")

    (testHelpers.mkTest "verdict-ok-on-a-plain-nix-shell"
      ((verdict fixed).ok && (verdict fixed).verdict == "Ok")
      "the shape substrate emits today must pass")

    # ── A green states what it verified ───────────────────────────────
    (testHelpers.mkTest "ok-message-names-the-shell-it-checked"
      (let m = (verdict fixed).message;
       in lib.hasInfix "default" m && lib.hasInfix "nix-shell" m && lib.hasInfix sys m)
      "the green must PRINT the devShell, its derivation name and the system — an opaque green is unauditable")

    (testHelpers.mkTest "strict-mode-returns-the-success-string"
      (lib.hasInfix "devShell preflight OK"
        (gate { system = sys; devshell = "default"; devShells = fixed; }))
      "strict mode must yield the summary string, so `nix eval --raw` prints it")

    # ── Every failure names the subject set it looked at ──────────────
    (testHelpers.mkTest "missing-message-lists-the-devshells-that-do-exist"
      (lib.hasInfix "ruby-eval" (verdict otherName).message)
      "a Missing verdict must list what IS declared — the subject-set witness is how an operator picks the right name")

    (testHelpers.mkTest "missing-message-names-the-input-to-change"
      (lib.hasInfix "devshell:" (verdict otherName).message)
      "the refusal must name the workflow input the operator edits")

    # ── The failure messages have to be actionable ────────────────────
    (testHelpers.mkTest "devenv-message-names-the-relock-cure"
      (lib.hasInfix "nix flake update substrate" (verdict devenvBacked).message)
      "the refusal must name the ONE command that fixes the common case")

    (testHelpers.mkTest "devenv-message-names-the-fixing-commit"
      (lib.hasInfix "e232917" (verdict devenvBacked).message)
      "naming the commit lets an operator check their pin against it instead of guessing")

    (testHelpers.mkTest "devenv-message-gives-a-verification-command"
      (lib.hasInfix "devShells.${sys}.default.name" (verdict devenvBacked).message)
      "the refusal must tell the operator how to CONFIRM the fix landed, not just what to type")

    (testHelpers.mkTest "devenv-message-names-the-deliberate-devenv-escape"
      (let m = (verdict devenvBacked).message;
       in lib.hasInfix "devshell-args" m && lib.hasInfix "rust-overlay" m)
      "a repo whose devenv shell is intentional must be given its lever, including the input --impure alone does not supply")

    (testHelpers.mkTest "devenv-message-says-impure-alone-is-insufficient"
      (lib.hasInfix "NOT sufficient" (verdict devenvBacked).message)
      "measured: --impure clears the directory assertion and then surfaces the missing input behind it — the message must not imply otherwise")

    (testHelpers.mkTest "devenv-message-explains-the-skew"
      (let m = (verdict devenvBacked).message;
       in lib.hasInfix "@main" m && lib.hasInfix "flake.lock" m)
      "the refusal must explain WHY a repo that changed nothing suddenly went red")

    (testHelpers.mkTest "unevaluable-message-carries-the-same-cures"
      (lib.hasInfix "nix flake update substrate" (verdict exploding).message)
      "the pure-eval face of the same defect must carry the same fix, not a thinner message")

    (testHelpers.mkTest "failure-messages-forbid-the-easy-out"
      (lib.hasInfix "Do not \"fix\" this by deleting" (verdict devenvBacked).message)
      "the refusal must close the obvious escape (deleting the job) explicitly")

    (testHelpers.mkTest "failure-message-states-nothing-was-verified"
      (lib.hasInfix "did not run and did not fail" (verdict exploding).message)
      "the operator must be told the tests did not merely fail — they never ran, so nothing was verified")
  ];

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  asCheck = pkgs:
    if result.allPassed
    then pkgs.runCommand "devshell-preflight-test" { } ''
      echo "devshell-preflight: ${result.summary}" > $out
    ''
    else throw ''
      devshell-preflight tests FAILED (${result.summary}):
        - ${builtins.concatStringsSep "\n  - " result.failures}'';
}
