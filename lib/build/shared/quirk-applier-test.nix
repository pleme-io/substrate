# quirk-applier-test.nix — typed-quirk dispatcher regression test
# across every ecosystem's quirk-apply.nix. Verifies:
#
#   1. Every quirk-apply.nix evaluates to an attrset with applyQuirks.
#   2. Empty quirks list returns {}.
#   3. The shared mk-quirk-applier throws on unknown variant kind
#      (refuse silent acceptance — typed-spec invariant).
#
# Usage:
#   nix-instantiate --eval --strict --json -E \
#     'import ./substrate/lib/build/shared/quirk-applier-test.nix {}'
{ lib ? (import <nixpkgs> {}).lib }:
let
  ecosystems = [
    "rust" "npm" "bundler" "helm"
    "pip" "poetry" "gomod" "ansible" "swift"
  ];

  loadEco = name: import (../. + "/${name}/quirk-apply.nix") { inherit lib; };

  assertEq = name: expected: actual:
    if expected == actual then "✓ ${name}"
    else throw "✗ ${name}: expected ${builtins.toJSON expected}, got ${builtins.toJSON actual}";

  # Test each ecosystem.
  perEco = name:
    let
      eco = loadEco name;
      hasApply = builtins.isAttrs eco && eco ? applyQuirks;
      empty = if hasApply then eco.applyQuirks [] {} else null;
    in [
      (assertEq "${name}: exports applyQuirks" true hasApply)
      (assertEq "${name}: empty quirks list returns empty attrset" {} empty)
    ];

  # Verify unknown-kind throw via the shared combinator directly.
  shared = import ./mk-quirk-applier.nix {
    inherit lib;
    helpers = { "real-kind" = _: _: {}; };
  };
  unknownThrows =
    let r = builtins.tryEval (shared.applyQuirks [ { kind = "ghost"; } ] {});
    in r.success == false;

  unknownTest =
    assertEq "shared dispatcher throws on unknown quirk kind" true unknownThrows;
in
(lib.lists.flatten (map perEco ecosystems)) ++ [ unknownTest ]
