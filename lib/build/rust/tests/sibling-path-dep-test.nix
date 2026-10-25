{ lib }:

let
  testHelpers = import ../../../util/test-helpers.nix { inherit lib; };
  delta = import ../lockfile-delta.nix { inherit lib; };
  refused = builtins.tryEval (builtins.deepSeq (delta.reconstruct ./fixtures/sibling-path-dep).crates true);

  tests = [
    (testHelpers.mkTest "a-sibling-path-dep-is-refused"
      (!refused.success)
      "a crate gen keyed as git but Cargo.lock holds as a sourceless path package must be refused, not dropped from the build")
  ];

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  asCheck = testHelpers.mkAsCheck { name = "sibling-path-dep-test"; label = "sibling-path-dep"; } result;
}
