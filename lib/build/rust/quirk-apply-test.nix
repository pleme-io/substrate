# quirk-apply-test.nix — Nix-side tests for the CrateQuirk dispatch.
#
# Each variant emitted by gen-cargo (`force-cfg`, `fold-normal-into-build`,
# `substitute-source`) is run through `quirk-apply.nix`'s `applyQuirks`
# and the result is asserted against the buildRustCrate-arg shape the
# substrate consumer expects.
#
# Consumed as a substrate flake check (`substrate.checks.quirk-apply`).
# Failure means the Rust enum's serde shape drifted from the Nix
# dispatch arms — exactly the bug class typed-spec contracts exist
# to prevent.
#
# Usage:
#   nix-instantiate --eval substrate/lib/build/rust/quirk-apply-test.nix
{ lib ? (import <nixpkgs> {}).lib }:
let
  q = import ./quirk-apply.nix { inherit lib; };

  # Helpers
  assertEq = name: expected: actual:
    if expected == actual then "✓ ${name}"
    else throw "✗ ${name}: expected ${builtins.toJSON expected}, got ${builtins.toJSON actual}";

  # ── Test 1: ForceCfg ─────────────────────────────────────────────
  forceCfgQuirk = { kind = "force-cfg"; cfg = "supports_64bit_atomics"; };
  forceCfgIn   = { extraRustcOpts = [ "--existing-opt" ]; };
  forceCfgOut  = q.applyQuirks [ forceCfgQuirk ] forceCfgIn;
  test1 = assertEq
    "ForceCfg appends --cfg to extraRustcOpts"
    [ "--existing-opt" "--cfg" "supports_64bit_atomics" ]
    forceCfgOut.extraRustcOpts;

  # ── Test 2: ForceCfg from empty base ─────────────────────────────
  forceCfgFromEmpty = q.applyQuirks [ forceCfgQuirk ] {};
  test2 = assertEq
    "ForceCfg works with no existing extraRustcOpts"
    [ "--cfg" "supports_64bit_atomics" ]
    forceCfgFromEmpty.extraRustcOpts;

  # ── Test 3: FoldNormalIntoBuild without externCrate ──────────────
  foldNoExtern = q.applyQuirks
    [ { kind = "fold-normal-into-build"; extern_crate = null; } ]
    {
      dependencies = [ "dep1" "dep2" ];
      buildDependencies = [ "build1" ];
    };
  test3 = assertEq
    "FoldNormalIntoBuild merges normal deps into buildDependencies"
    [ "build1" "dep1" "dep2" ]
    foldNoExtern.buildDependencies;
  test3b = assertEq
    "FoldNormalIntoBuild without externCrate has no prePatch"
    null
    (foldNoExtern.prePatch or null);

  # ── Test 4: FoldNormalIntoBuild WITH externCrate ─────────────────
  foldWithExtern = q.applyQuirks
    [ { kind = "fold-normal-into-build"; extern_crate = "glob"; } ]
    { dependencies = [ "d" ]; buildDependencies = []; };
  test4 = assertEq
    "FoldNormalIntoBuild with externCrate generates prePatch with extern crate line"
    true
    (lib.hasInfix "extern crate glob;" (foldWithExtern.prePatch or ""));

  # ── Test 5: SubstituteSource ─────────────────────────────────────
  substQuirk = {
    kind = "substitute-source";
    file = "src/foo.rs";
    from = "old code";
    to = "new code";
  };
  substOut = q.applyQuirks [ substQuirk ] {};
  test5 = assertEq
    "SubstituteSource emits substituteInPlace prePatch"
    true
    (lib.hasInfix "substituteInPlace src/foo.rs" (substOut.prePatch or ""));
  test5b = assertEq
    "SubstituteSource preserves from/to as JSON-encoded literals"
    true
    (lib.hasInfix "\"old code\"" (substOut.prePatch or ""));

  # ── Test 6: Empty quirks list = empty result ─────────────────────
  emptyOut = q.applyQuirks [] { existing = "untouched"; };
  test6 = assertEq
    "Empty quirks list produces empty override attrs"
    {}
    emptyOut;

  # ── Test 7: Unknown variant kind throws ──────────────────────────
  unknownTry = builtins.tryEval (
    q.applyQuirks [ { kind = "made-up-variant"; } ] {}
  );
  test7 = assertEq
    "Unknown CrateQuirk variant throws (refuse silent acceptance)"
    false
    unknownTry.success;

  results = [ test1 test2 test3 test3b test4 test5 test5b test6 test7 ];
in
results
