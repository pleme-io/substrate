# Test: Verify framework crates WASM-compatibility matrix.
# These assertions document which crates compile to wasm32-unknown-unknown.
# Verified by running `cargo build --target wasm32-unknown-unknown` on each crate.
#
# ⚠ pending-vacuous-guard: infra/wasm-compat
#
# DELIBERATELY NOT WIRED INTO CI (2026-07-28), while the other 22
# report-returning suites were. It is not broken and it is not red — it is
# a TAUTOLOGY, which is worse, because wiring it would manufacture 13
# units of coverage that verify nothing.
#
# Every assertion below reads `wasmCompat.<crate>` and compares it to the
# literal written into `wasmCompat` a few lines above. The file imports
# nothing, reads no crate, invokes no builder, and touches no substrate
# code. `assertEqual "egaku WASM" wasmCompat.egaku true` restates its own
# input. It cannot go red unless someone edits one half of a
# same-file literal and not the other, and it will stay green forever
# after `garasu` starts or stops compiling to wasm32.
#
# The header line above is the tell: the real verification was a one-off
# manual `cargo build --target wasm32-unknown-unknown`. What is committed
# here is the RESULT of that act transcribed as Nix, plus assertions that
# the transcription equals itself. That is a record, not a test —
# ★★ UNREPRESENTABILITY §II.3 tier ⊥, "vacuous" subclass.
#
# WHAT WOULD MAKE IT REAL: the subject has to come from outside the file.
# Either (a) derive the matrix from each crate's own Cargo.toml / flake
# (target lists, `wasm32` cfg gates) so a crate that gains a native-only
# dep flips the value, or (b) make it a BUILD check — one derivation per
# crate doing the wasm32 build — which belongs in `checks.<system>.*`
# rather than in an eval suite. Until one of those lands, the file stays
# here (★★ MODULARIZE, DON'T DELETE: the matrix is a real record of a real
# measurement) and stays out of the catalog in lib/util/eval-suites.nix.
#
# Do not "fix" this by adding it to the catalog. A green step here would
# be indistinguishable in the CI log from the 830 assertions that do work.
{ lib ? (import <nixpkgs> {}).lib }:

let
  assertEqual = name: actual: expected:
    if actual == expected then true
    else builtins.throw "${name}: expected ${builtins.toJSON expected}, got ${builtins.toJSON actual}";

  # Document the WASM compatibility matrix.
  # true = compiles to wasm32-unknown-unknown.
  # false = requires native targets (wgpu, filesystem, sockets, etc.).
  wasmCompat = {
    # Pure Rust -- compiles everywhere
    egaku = true;
    irodori = true;
    irodzuki = true;
    kenshou = true;
    hayai = true;
    tsuuchi = true;
    awase = true;
    sekkei = true;
    pleme-app-core = true;

    # Leptos web -- compiles to wasm32-unknown-unknown
    pleme-mui = true;
    lilitu-web = true;

    # GPU -- requires native targets (wgpu + winit)
    garasu = false;
    madori = false;

    # Desktop/system -- requires native targets
    shikumi = false;   # filesystem, inotify
    tsunagu = false;   # Unix sockets
    denshin = false;   # tokio networking
    todoku = false;    # reqwest (partial WASM, needs feature flags)
  };

  # Run all individual assertions
  testEgakuWasm = assertEqual "egaku WASM" wasmCompat.egaku true;
  testIrodoriWasm = assertEqual "irodori WASM" wasmCompat.irodori true;
  testIrodzukiWasm = assertEqual "irodzuki WASM" wasmCompat.irodzuki true;
  testKenshouWasm = assertEqual "kenshou WASM" wasmCompat.kenshou true;
  testHayaiWasm = assertEqual "hayai WASM" wasmCompat.hayai true;
  testTsuuchiWasm = assertEqual "tsuuchi WASM" wasmCompat.tsuuchi true;
  testAwaseWasm = assertEqual "awase WASM" wasmCompat.awase true;
  testSekkeiWasm = assertEqual "sekkei WASM" wasmCompat.sekkei true;
  testAppCoreWasm = assertEqual "pleme-app-core WASM" wasmCompat.pleme-app-core true;
  testPlemeMuiWasm = assertEqual "pleme-mui WASM" wasmCompat.pleme-mui true;
  testLilituWebWasm = assertEqual "lilitu-web WASM" wasmCompat.lilitu-web true;
  testGarasuNotWasm = assertEqual "garasu not WASM" wasmCompat.garasu false;
  testMadoriNotWasm = assertEqual "madori not WASM" wasmCompat.madori false;

in {
  # Re-export individual test results
  inherit testEgakuWasm testIrodoriWasm testIrodzukiWasm
          testKenshouWasm testHayaiWasm testTsuuchiWasm testAwaseWasm testSekkeiWasm
          testAppCoreWasm testPlemeMuiWasm testLilituWebWasm
          testGarasuNotWasm testMadoriNotWasm;

  # Count WASM-safe vs native-only
  wasmSafe = builtins.length (builtins.filter (x: x) (builtins.attrValues wasmCompat));
  nativeOnly = builtins.length (builtins.filter (x: !x) (builtins.attrValues wasmCompat));

  allPassed = builtins.all (x: x == true) [
    testEgakuWasm testIrodoriWasm testIrodzukiWasm
    testKenshouWasm testHayaiWasm testTsuuchiWasm testAwaseWasm testSekkeiWasm
    testAppCoreWasm testPlemeMuiWasm testLilituWebWasm
    testGarasuNotWasm testMadoriNotWasm
  ];
}
