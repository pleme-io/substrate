{ lib }:

let
  testHelpers = import ../../../util/test-helpers.nix { inherit lib; };
  resolve = import ../fenix-resolve.nix;
  substrateFenix = { marker = "substrate-fenix"; };
  explicitFenix = { marker = "explicit-fenix"; };
  consumer = { inputs.substrate.inputs.fenix = substrateFenix; };
  consumerWithoutFenix = { inputs.substrate.inputs = { }; };

  tests = [
    (testHelpers.mkTest "explicit-fenix-wins-with-the-option-on"
      (resolve { fenix = explicitFenix; src = consumer; fenixFromSubstrate = true; } == explicitFenix)
      "a consumer that passes fenix keeps it")
    (testHelpers.mkTest "explicit-fenix-wins-with-the-option-off"
      (resolve { fenix = explicitFenix; src = consumer; fenixFromSubstrate = false; } == explicitFenix)
      "a consumer that passes fenix keeps it")
    (testHelpers.mkTest "option-off-keeps-nixpkgs-rustc"
      (resolve { fenix = null; src = consumer; fenixFromSubstrate = false; } == null)
      "off is today's behaviour: no fenix, nixpkgs rustc")
    (testHelpers.mkTest "option-on-takes-the-consumers-substrate-fenix"
      (resolve { fenix = null; src = consumer; fenixFromSubstrate = true; } == substrateFenix)
      "on takes the fenix of the substrate the consumer already follows")
    (testHelpers.mkTest "option-on-without-a-substrate-fenix-stays-null"
      (resolve { fenix = null; src = consumerWithoutFenix; fenixFromSubstrate = true; } == null)
      "a substrate with no fenix input falls back to nixpkgs rustc")
    (testHelpers.mkTest "option-on-with-a-path-src-stays-null"
      (resolve { fenix = null; src = ./.; fenixFromSubstrate = true; } == null)
      "a src that is a path has no inputs")
    (testHelpers.mkTest "option-on-with-a-null-src-stays-null"
      (resolve { fenix = null; src = null; fenixFromSubstrate = true; } == null)
      "no src, no inputs")
  ];

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  asCheck = testHelpers.mkAsCheck { name = "rust-fenix-resolve-test"; label = "rust/fenix-resolve"; } result;
}
