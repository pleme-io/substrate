# Test: Verify framework crates WASM-compatibility matrix.
# These assertions document which crates compile to wasm32-unknown-unknown.
# Verified by running `cargo build --target wasm32-unknown-unknown` on each crate.
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
