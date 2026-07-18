# typed-dispatcher-test.nix — exercises the canonical
# `mk-typed-dispatcher.nix` entrypoint directly (not via the
# back-compat `mk-quirk-applier.nix` shim). Sister test to
# `quirk-applier-test.nix`; that one verifies the v0.1 callers
# still work, this one verifies the v0.2 surface.
#
# Usage:
#   nix-instantiate --eval --strict --json -E \
#     'import ./substrate/lib/build/shared/typed-dispatcher-test.nix {}'
{ lib ? (import <nixpkgs> {}).lib }:
let
  mk = helpers: import ./mk-typed-dispatcher.nix { inherit lib helpers; };

  assertEq = name: expected: actual:
    if expected == actual then "✓ ${name}"
    else throw "✗ ${name}: expected ${builtins.toJSON expected}, got ${builtins.toJSON actual}";

  # ── Test 1: applyVariants exists as new canonical name ──────────
  d1 = mk { "noop" = _: _: {}; };
  test1 = assertEq
    "exports applyVariants under new canonical name"
    true
    (d1 ? applyVariants);

  # ── Test 2: back-compat applyQuirks alias still exists ──────────
  test2 = assertEq
    "still exports applyQuirks alias for v0.1 callers"
    true
    (d1 ? applyQuirks);

  # ── Test 3: applyVariants and applyQuirks behave identically ────
  d3 = mk {
    "add-flag" = variant: attrs: {
      flags = (attrs.flags or []) ++ [ variant.flag ];
    };
  };
  ins = [ { kind = "add-flag"; flag = "-O3"; } ];
  base = { flags = [ "-g" ]; };
  test3 = assertEq
    "applyVariants and applyQuirks produce identical output"
    (d3.applyVariants ins base)
    (d3.applyQuirks ins base);

  # ── Test 4: empty variants list returns empty attrset ───────────
  test4 = assertEq
    "empty variants list returns empty attrset"
    {}
    (d1.applyVariants [] {});

  # ── Test 5: fold is left-associative ────────────────────────────
  d5 = mk {
    "set-x" = variant: _: { x = variant.value; };
  };
  test5 = assertEq
    "fold is left-associative — last variant wins"
    { x = 3; }
    (d5.applyVariants [
      { kind = "set-x"; value = 1; }
      { kind = "set-x"; value = 2; }
      { kind = "set-x"; value = 3; }
    ] {});

  # ── Test 6: throw on unknown kind ───────────────────────────────
  d6 = mk { "real-kind" = _: _: {}; };
  unknownThrows =
    let r = builtins.tryEval (d6.applyVariants [ { kind = "ghost"; } ] {});
    in r.success == false;
  test6 = assertEq
    "throws on unknown variant kind (refuse silent acceptance)"
    true
    unknownThrows;

  # ── Test 7: helpers receive the full variant, including kind ────
  d7 = mk {
    "capture" = variant: _: { captured = variant; };
  };
  test7 = assertEq
    "helpers receive the full variant (kind + payload)"
    { kind = "capture"; payload = "hi"; }
    (d7.applyVariants [ { kind = "capture"; payload = "hi"; } ] {}).captured;

  # ── Test 8: two same-kind variants ACCUMULATE onto one key ──────
  # Regression for the wgpu-hal incident (nix run .#rebuild,
  # 2026-07-17): two ForceCfg-shaped quirks both append onto
  # `extraRustcOpts`. Each must see the PRIOR variant's contribution,
  # not the pristine base attrs — otherwise the second overwrites the
  # first instead of accumulating.
  d8 = mk {
    "add-flag" = variant: attrs: {
      flags = (attrs.flags or []) ++ [ variant.flag ];
    };
  };
  test8 = assertEq
    "two same-kind variants accumulate onto the same key, neither clobbers the other"
    { flags = [ "-g" "-O3" "-O2" ]; }
    (d8.applyVariants [
      { kind = "add-flag"; flag = "-O3"; }
      { kind = "add-flag"; flag = "-O2"; }
    ] { flags = [ "-g" ]; });
in [
  test1 test2 test3 test4 test5 test6 test7 test8
]
