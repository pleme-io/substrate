# Pure eval tests for lib/util/claude-md-gate.nix.
#
# NOT VACUOUS: `over-limit-throws` feeds the gate a file one byte over a small
# ceiling and requires an eval error; a gate that stopped comparing would pass
# every file and fail this case.
{ lib }:

let
  testHelpers = import ../test-helpers.nix { inherit lib; };
  gate = import ../claude-md-gate.nix { inherit lib; };

  small = builtins.toFile "CLAUDE.md" "0123456789";
  fakePkgs = { runCommand = name: _: _: name; };

  tests = [
    (testHelpers.mkTest "measures-bytes"
      ((gate.measure { file = small; }).bytes == 10)
      "measure must report the file's byte length")

    (testHelpers.mkTest "at-limit-passes"
      (gate.check fakePkgs { name = "t"; file = small; limit = 10; } == "claude-md-size-t")
      "a file exactly at the ceiling must pass")

    (testHelpers.mkTest "over-limit-throws"
      (!(builtins.tryEval (gate.check fakePkgs { name = "t"; file = small; limit = 9; })).success)
      "a file one byte over the ceiling must be an eval error")

    (testHelpers.mkTest "default-is-the-harness-limit"
      (gate.defaultLimit == 40000)
      "the default ceiling is Claude Code's 40,000 limit")
  ];

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  asCheck = testHelpers.mkAsCheck { name = "claude-md-gate-test"; label = "claude-md-gate"; } result;
}
