# quirk-apply-test.nix — Nix-side tests for the CrateQuirk dispatch.
#
# Each variant emitted by gen-cargo (`force-cfg`, `fold-normal-into-build`,
# `substitute-source`) is run through `quirk-apply.nix`'s `applyQuirks`
# and the result is asserted against the buildRustCrate-arg shape the
# substrate consumer expects.
#
# Wired into CI via .github/workflows/nix-tests.yml (rust-overrides job).
# Failure means the Rust enum's serde shape drifted from the Nix
# dispatch arms — exactly the bug class typed-spec contracts exist
# to prevent.
#
# Direct-expression shape (not a `{ lib ? … }:` lambda) so that
#   nix-instantiate --eval --strict substrate/lib/build/rust/quirk-apply-test.nix
# actually RUNS the assertions and fails closed on `throw`; a lambda file
# would print `<LAMBDA>` and exit 0 without running anything. Evaluates to
# `{ total = N; passed = N; }` on success.
let
  lib = (import <nixpkgs> {}).lib;
  q = import ./quirk-apply.nix { inherit lib; };

  # Helpers
  assertEq = name: expected: actual:
    if expected == actual then true
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

  # ── Test 2b: TWO ForceCfg quirks on one crate both survive ───────
  # Regression for the wgpu-hal incident (nix run .#rebuild,
  # 2026-07-17): wgpu-hal/wgpu-core/wgpu/wgpu-types are each
  # registered with BOTH `supports_64bit_atomics` AND
  # `supports_ptr_atomics` ForceCfg quirks. The shared fold used to
  # apply each quirk against the pristine base attrs instead of the
  # running accumulator, so the second ForceCfg silently clobbered
  # the first's `--cfg` instead of appending to it — wgpu-hal built
  # with only `supports_ptr_atomics` set, took the portable-atomic
  # fallback arm, and failed E0432 (unresolved `portable_atomic`).
  twoForceCfg = q.applyQuirks
    [
      { kind = "force-cfg"; cfg = "supports_64bit_atomics"; }
      { kind = "force-cfg"; cfg = "supports_ptr_atomics"; }
    ]
    { extraRustcOpts = [ "--existing-opt" ]; };
  test2b = assertEq
    "two ForceCfg quirks on one crate both accumulate, neither clobbers the other"
    [ "--existing-opt" "--cfg" "supports_64bit_atomics" "--cfg" "supports_ptr_atomics" ]
    twoForceCfg.extraRustcOpts;

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

  results = [ test1 test2 test2b test3 test3b test4 test5 test5b test6 test7 ];
  n = builtins.length results;
in
  # Forces every check (each is `true` or throws) → fails closed.
  assert builtins.all (x: x) results;
  { total = n; passed = n; }
