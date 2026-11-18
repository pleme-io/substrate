{ pkgs }:
let
  inherit (pkgs) lib;
  trio = import ../module-trio.nix { inherit lib; };
  tc = (import ../build/blue { }).toolchain { inherit lib trio; };
  stub = pkgs.runCommand "blue-stub" { } "mkdir -p $out/bin";
  evalWith =
    config:
    (lib.evalModules {
      modules = [
        tc.concept.module
        { pleme.blueToolchain = config; }
      ];
    }).config.pleme.blueToolchain;
  buildable = evalWith { packages.rust = stub; };
  notYet = evalWith {
    selected = "pure";
    packages.rust = stub;
  };
  noPackage = evalWith { };
  badEntry = tc.entryType.check {
    runtime = "native";
    door = "auto";
    front = "blue";
    memory = "counted";
    backend = null;
    seed = null;
    rung = null;
  };
  results = {
    everyDefaultEntryIsCoherent = lib.all (e: tc.coherent ({ door = null; backend = null; seed = null; rung = null; } // e)) (builtins.attrValues tc.entries);
    aDoorUnderNativeIsRefusedByTheType = !badEntry;
    aBackendUnderRustIsIncoherent = !tc.coherent { runtime = "rust"; door = "auto"; front = "rust"; backend = "x64"; seed = null; memory = "counted"; rung = null; };
    aBinarySeedNeedsX64 = !tc.coherent { runtime = "native"; door = null; front = "blue"; backend = "rustc"; seed = "binary"; memory = "inferred"; rung = null; };
    rustIsTheDefaultAndRenders = buildable.selected == "rust" && buildable.refusal == null && buildable.door == "auto";
    aNotYetEntryNamesItsRung = notYet.refusal == "blueToolchain: entry `pure` is not buildable yet: needs S2" && notYet.door == null;
    aMissingDerivationIsNamed = noPackage.refusal == "blueToolchain: entry `rust` has no derivation in packages";
    offByDefault = !buildable.enable;
  };
in
pkgs.runCommand "blue-toolchain-test" { } ''
  ${lib.concatStringsSep "\n" (
    lib.mapAttrsToList (n: ok: if ok then "echo ok ${n}" else "echo FAIL ${n}; exit 1") results
  )}
  touch $out
''
