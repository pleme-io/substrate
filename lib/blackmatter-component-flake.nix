# blackmatter-component-flake.nix — DELEGATION SHIM (since 2026-06-12).
#
# THE BLACKMATTER SWALLOW, landed: this file no longer carries an
# implementation. It is a thin shim over iroha.mkComponentFlake
# (lib/iroha/component-flake.nix), so the ~20 blackmatter-* sub-repos that
# import this path get the v2 implementation with ZERO consumer edits.
#
# Legacy surface preserved:
#   - same import path, same call shape (one attrset argument), same output
#     attr names (homeManagerModules/nixosModules/darwinModules .default,
#     packages.<system>.default, overlays.default, devShells.<system>.default,
#     checks.<system>.*, blackmatter.component metadata) — proven by the
#     parity suite at lib/iroha/tests/component-flake.nix, which compares v2
#     against the frozen TRUE legacy implementation kept at
#     lib/iroha/tests/fixtures/legacy-component-flake.nix.
#
# v2 semantics (deliberate upgrades over the retired implementation):
#   1. TYPED THROWS replace silent drops — unknown top-level argument keys
#      and unknown modules.* keys (e.g. `modules.homemanager`, a typo that
#      legacy silently discarded) are now iroha-prefixed eval errors.
#   2. The eval-nixos-module check WORKS — the legacy per-kind nixos stub
#      layer prefix-conflicted with its own commonStubs and threw by
#      construction; v2 ships one permissive stub universe for all three
#      module classes.
#   3. Check derivations aggregate-before-assert via iroha.checks — a failing
#      module eval is a failing check BUILD with a full failure report, not a
#      flake-eval-time throw.
#
# Consumer docs (argument surface, defaults, throws) live in the v2 header:
# lib/iroha/component-flake.nix.
#
# lib threading: identical to the retired implementation, which bound
# `lib = nixpkgs.lib` from its own argument attrset — the shim threads
# `args.nixpkgs.lib` lazily, so the v2 typed throws for a missing `nixpkgs`
# still surface (the error message never forces `lib`).

args:
(import ./iroha/component-flake.nix { lib = args.nixpkgs.lib; }).mkComponentFlake args
