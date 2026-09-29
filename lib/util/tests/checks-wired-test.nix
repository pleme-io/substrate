# Pure eval tests for lib/util/checks-wired.nix.
#
# NOT VACUOUS: `unwired-check-throws` requires an eval error when one declared
# check has no step; `prefix-is-not-wiring` stops `rust-shape` from counting
# as wiring for `rust`.
{ lib }:

let
  testHelpers = import ../test-helpers.nix { inherit lib; };
  gate = import ../checks-wired.nix { inherit lib; };
  fakePkgs = { runCommand = name: _: _: name; };
  wf = ''
    run: nix build --no-link -L '.#checks.x86_64-linux.alpha'
    run: nix build --no-link -L ".#checks.x86_64-linux.beta"
    run: nix build --no-link -L '.#checks.x86_64-linux.rust-shape'
  '';
  sys = "x86_64-linux";

  tests = [
    (testHelpers.mkTest "all-wired-passes"
      (gate.check fakePkgs { names = [ "alpha" "beta" ]; system = sys; workflowText = wf; } == "checks-wired")
      "both quote styles count as a build step")

    (testHelpers.mkTest "missing-lists-the-gap"
      (gate.missing { names = [ "alpha" "gamma" ]; system = sys; workflowText = wf; } == [ "gamma" ])
      "missing must name exactly the checks with no step")

    (testHelpers.mkTest "unwired-check-throws"
      (!(builtins.tryEval (gate.check fakePkgs { names = [ "gamma" ]; system = sys; workflowText = wf; })).success)
      "a declared check with no step must be an eval error")

    (testHelpers.mkTest "prefix-is-not-wiring"
      (gate.missing { names = [ "rust" ]; system = sys; workflowText = wf; } == [ "rust" ])
      "a longer check name must not count as wiring a shorter one")
  ];

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;
  asCheck = testHelpers.mkAsCheck { name = "checks-wired-test"; label = "checks-wired"; } result;
}
