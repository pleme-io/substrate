# crate-override-compose-test.nix — eval-time tests for
# crate-override-compose.nix.
#
# Direct-expression shape (not a `{ lib ? … }:` lambda) so a bare
#   nix-instantiate --eval --strict lib/build/rust/crate-override-compose-test.nix
# actually RUNS the assertions and fails closed on `throw` — a lambda
# file would print `<LAMBDA>` and exit 0 without running anything.
# Evaluates to `{ total = N; passed = N; }` on success.
#
# Pins the **winner-wins** semantics that keep fleet safety-net crate
# overrides (pleme-crate-overrides.nix) from being clobbered by a
# caller's raw nixpkgs defaults — the exact regression that blocked every
# gen-built Rust image when nixpkgs' `proc-macro-crate` 3.5.0 postPatch
# `--replace-fail`ed a removed literal and lockfile-builder's old
# caller-wins composition re-introduced it.
let
  pkgs = import <nixpkgs> {};
  lib = pkgs.lib;
  c = import ./crate-override-compose.nix { inherit lib; };

  # assertEq → `true`, or `throw`s with expected/got on mismatch.
  assertEq = name: expected: actual:
    if expected == actual then true
    else throw "✗ ${name}: expected ${builtins.toJSON expected}, got ${builtins.toJSON actual}";

  checks = [
    # 1: neither map has the crate → identity
    (assertEq "absent crate resolves to identity"
      { x = 1; }
      ((c.composeOverrideMaps { base = {}; winner = {}; } "absent") { x = 1; }))

    # 2: only base → base's fn verbatim
    (assertEq "base-only uses base fn"
      { fromBase = true; }
      ((c.composeOverrideMaps { base = { foo = a: a // { fromBase = true; }; }; winner = {}; } "foo") {}))

    # 3: only winner → winner's fn verbatim
    (assertEq "winner-only uses winner fn"
      { fromWinner = true; }
      ((c.composeOverrideMaps { base = {}; winner = { foo = a: a // { fromWinner = true; }; }; } "foo") {}))

    # 4: collision → winner wins on field; base non-collide kept
    (assertEq "collision: winner field wins, base non-collide preserved"
      { x = 1; y = 9; z = 3; }
      ((c.composeOverrideMaps {
        base = { foo = _: { x = 1; y = 2; }; };
        winner = { foo = _: { y = 9; z = 3; }; };
      } "foo") {}))

    # 5: THE regression — safety-net clears nixpkgs' broken postPatch
    (assertEq "safety-net postPatch=\"\" wins over nixpkgs broken --replace-fail"
      ""
      ((c.composeOverrideMaps {
        base = { proc-macro-crate = _: { postPatch = "substituteInPlace src/lib.rs --replace-fail 'env::var(\"CARGO\")' x"; }; };
        winner = { proc-macro-crate = _: { postPatch = ""; }; };
      } "proc-macro-crate") {}).postPatch)

    # 6: mergeOverrideMaps eager form covers the union of keys
    (assertEq "merge covers union of keys"
      [ "a" "b" ]
      (builtins.attrNames (c.mergeOverrideMaps {
        base = { a = _: { v = 1; }; };
        winner = { b = _: { v = 2; }; };
      })))

    # 7: merged entries are callable composed resolvers
    (assertEq "merged entries are callable composed resolvers"
      { v = 1; }
      ((c.mergeOverrideMaps { base = { a = _: { v = 1; }; }; winner = {}; }).a {}))

    # 8: mergeOverrideMaps collision also winner-wins
    (assertEq "merge collision: winner wins, base non-collide kept"
      { p = 1; q = 9; }
      ((c.mergeOverrideMaps {
        base = { k = _: { p = 1; q = 1; }; };
        winner = { k = _: { q = 9; }; };
      }).k {}))
  ];

  n = builtins.length checks;
in
  # Forces every check (each is `true` or throws) → fails closed.
  assert builtins.all (x: x) checks;
  { total = n; passed = n; }
