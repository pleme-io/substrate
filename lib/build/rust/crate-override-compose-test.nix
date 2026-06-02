# crate-override-compose-test.nix — tests for composeOverrideMaps /
# mergeOverrideMaps (./crate-override-compose.nix).
#
# Pins the **winner-wins** semantics that keep fleet safety-net crate
# overrides (pleme-crate-overrides.nix) from being clobbered by a caller's
# raw nixpkgs defaults — the exact regression that blocked every gen-built
# Rust image when nixpkgs' `proc-macro-crate` 3.5.0 postPatch
# `--replace-fail`ed a removed literal and lockfile-builder's old
# caller-wins composition re-introduced it.
#
# Usage:
#   nix-instantiate --eval substrate/lib/build/rust/crate-override-compose-test.nix
{ lib ? (import <nixpkgs> {}).lib }:
let
  c = import ./crate-override-compose.nix { inherit lib; };

  assertEq = name: expected: actual:
    if expected == actual then "✓ ${name}"
    else throw "✗ ${name}: expected ${builtins.toJSON expected}, got ${builtins.toJSON actual}";

  # ── Test 1: neither map has the crate → identity ──────────────────
  r1 = c.composeOverrideMaps { base = {}; winner = {}; } "absent";
  test1 = assertEq "absent crate resolves to identity" { x = 1; } (r1 { x = 1; });

  # ── Test 2: only base → base's fn verbatim ────────────────────────
  baseOnly = { foo = a: a // { fromBase = true; }; };
  r2 = c.composeOverrideMaps { base = baseOnly; winner = {}; } "foo";
  test2 = assertEq "base-only uses base fn" { fromBase = true; } (r2 {});

  # ── Test 3: only winner → winner's fn verbatim ────────────────────
  winOnly = { foo = a: a // { fromWinner = true; }; };
  r3 = c.composeOverrideMaps { base = {}; winner = winOnly; } "foo";
  test3 = assertEq "winner-only uses winner fn" { fromWinner = true; } (r3 {});

  # ── Test 4: collision → winner wins on field; base non-collide kept
  baseFn = { foo = _: { x = 1; y = 2; }; };
  winFn  = { foo = _: { y = 9; z = 3; }; };
  r4 = c.composeOverrideMaps { base = baseFn; winner = winFn; } "foo";
  test4 = assertEq "collision: winner field wins, base non-collide preserved"
    { x = 1; y = 9; z = 3; } (r4 {});

  # ── Test 5: THE regression — safety-net clears nixpkgs' broken postPatch
  nixpkgsLike = {
    proc-macro-crate = _: {
      postPatch = "substituteInPlace src/lib.rs --replace-fail 'env::var(\"CARGO\")' x";
    };
  };
  plemeLike = { proc-macro-crate = _: { postPatch = ""; }; };
  r5 = c.composeOverrideMaps { base = nixpkgsLike; winner = plemeLike; } "proc-macro-crate";
  test5 = assertEq "safety-net postPatch=\"\" wins over nixpkgs broken --replace-fail"
    "" ((r5 {}).postPatch);

  # ── Test 6: mergeOverrideMaps eager form covers union of keys ─────
  merged = c.mergeOverrideMaps {
    base = { a = _: { v = 1; }; };
    winner = { b = _: { v = 2; }; };
  };
  # attrNames is always lexicographically sorted in Nix.
  test6 = assertEq "merge covers union of keys" [ "a" "b" ] (builtins.attrNames merged);
  test6b = assertEq "merged entries are callable composed resolvers" { v = 1; } (merged.a {});

  # ── Test 7: mergeOverrideMaps collision also winner-wins ──────────
  merged2 = c.mergeOverrideMaps {
    base = { k = _: { p = 1; q = 1; }; };
    winner = { k = _: { q = 9; }; };
  };
  test7 = assertEq "merge collision: winner wins, base non-collide kept" { p = 1; q = 9; } (merged2.k {});

  results = [ test1 test2 test3 test4 test5 test6 test6b test7 ];
in
results
