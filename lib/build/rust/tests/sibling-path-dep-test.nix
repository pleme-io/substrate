{ lib }:

let
  testHelpers = import ../../../util/test-helpers.nix { inherit lib; };
  delta = import ../lockfile-delta.nix { inherit lib; };
  spec = delta.reconstruct ./fixtures/sibling-path-dep;
  key = "sib-0.1.0-eb2af782939479f72a7d9edcef1f62a24934285c";
  refused = builtins.tryEval (builtins.deepSeq spec.crates.${key} true);

  tests = [
    (testHelpers.mkTest "a-sibling-path-dep-is-refused"
      (!refused.success)
      "a crate gen keyed as git but Cargo.lock holds as a sourceless path package must be refused, not dropped from the build")
    (testHelpers.mkTest "the-refusal-is-scoped-to-the-crate"
      (builtins.elem key (builtins.attrNames spec.crates) && spec.crates ? "app-0.1.0" && spec.crates."app-0.1.0".name == "app")
      "the spec and its other crates must still evaluate; only forcing the sibling crate fails")
  ];

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  asCheck = testHelpers.mkAsCheck { name = "sibling-path-dep-test"; label = "sibling-path-dep"; } result;
}
