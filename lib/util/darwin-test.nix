# darwin-test.nix — Nix-side tests for mkDarwinBuildInputs (lib/util/darwin.nix).
#
# Seals the 2026-07-17 regression: an ayatsuri flake minimization (crate2nix →
# `substrate.rust.library { src = ./.; }`) silently dropped the inline crate
# override that added `apple-sdk.privateFrameworksHook`, so every darwin GUI
# crate that `#[link]`s a private framework (SkyLight/CGS — window management)
# failed final-link with `Undefined symbols … _SLSMainConnectionID …`. The fix
# moved the hook INTO mkDarwinBuildInputs so every darwin consumer gets it at
# the existing tool-release.nix call site with zero per-consumer flake wiring.
# This pins that invariant so a future refactor can't drop it silently again.
#
# Direct-expression shape (NOT a `{ lib ? … }:` lambda) so that
#   nix-instantiate --eval --strict substrate/lib/util/darwin-test.nix
# actually RUNS the assertions and fails closed on `throw`; a lambda file would
# print `<LAMBDA>` and exit 0 without running anything. Evaluates to
# `{ total = N; passed = N; }` on success. Wired into CI via
# .github/workflows/nix-tests.yml.
let
  realLib = (import <nixpkgs> {}).lib;
  darwin = import ./darwin.nix;

  # Mock modern-nixpkgs darwin pkgs — only the surface mkDarwinBuildInputs reads.
  # Sentinel strings make `builtins.elem` comparisons unambiguous.
  mkMockPkgs = { isDarwin ? true, hasHook ? true }: {
    lib = realLib;
    stdenv = { inherit isDarwin; };
    libiconv = "LIBICONV";
    apple-sdk = { sdk = "APPLE_SDK"; }
      // (if hasHook then { privateFrameworksHook = "PRIVATE_FRAMEWORKS_HOOK"; } else {});
  };

  assertTrue = name: cond:
    if cond then true else throw "✗ ${name}";
  assertContains = name: needle: haystack:
    assertTrue "${name}: list should contain ${builtins.toJSON needle}, got ${builtins.toJSON haystack}"
      (builtins.elem needle haystack);
  assertNotContains = name: needle: haystack:
    assertTrue "${name}: list should NOT contain ${builtins.toJSON needle}, got ${builtins.toJSON haystack}"
      (!(builtins.elem needle haystack));

  withHook    = darwin.mkDarwinBuildInputs (mkMockPkgs { hasHook = true; });
  withoutHook = darwin.mkDarwinBuildInputs (mkMockPkgs { hasHook = false; });
  nonDarwin   = darwin.mkDarwinBuildInputs (mkMockPkgs { isDarwin = false; });

  # Test 1 (the invariant): modern nixpkgs exposing the hook → hook is wired.
  # This is exactly what a future minimization must not regress.
  test1 = assertContains "hook wired when apple-sdk.privateFrameworksHook present"
    "PRIVATE_FRAMEWORKS_HOOK" withHook;

  # Test 2: apple-sdk (the PUBLIC frameworks) stays present alongside the hook.
  test2 = assertContains "apple-sdk still present"
    { sdk = "APPLE_SDK"; privateFrameworksHook = "PRIVATE_FRAMEWORKS_HOOK"; } withHook;

  # Test 3 (the safety guard): a nixpkgs WITHOUT the hook attr degrades to a
  # no-op — no throw, no dangling reference. This is why the fix is safe fleet-wide.
  test3 = assertNotContains "no hook when apple-sdk lacks privateFrameworksHook"
    "PRIVATE_FRAMEWORKS_HOOK" withoutHook;

  # Test 4: non-darwin → empty (the hook never leaks onto linux builds).
  test4 = assertTrue "empty on non-darwin" (nonDarwin == []);

  tests = [ test1 test2 test3 test4 ];
in {
  total = builtins.length tests;
  passed = builtins.length (builtins.filter (x: x) tests);
}
