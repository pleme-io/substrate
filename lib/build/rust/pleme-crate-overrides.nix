# pleme-crate-overrides — residual nixpkgs-side fleet quirks.
#
# Per-crate `CrateQuirk` knowledge MIGRATED to typed Rust at
# `pleme-io/gen/crates/gen-cargo/src/quirks.rs::REGISTRY`. Dispatch
# happens in `./quirk-apply.nix` consumed by lockfile-builder.
#
# This file now only holds overrides for crates whose bug is in
# nixpkgs' own `defaultCrateOverrides` (not in any upstream
# third-party crate), so they can't be expressed as a CrateQuirk.
#
# Adding entries: prefer registering a CrateQuirk in the Rust
# registry — it's typed, drift-checked by cse-lint, and
# discoverable by tooling. Use this file only when the bug is in
# nixpkgs' attribute.
{
  # nixpkgs' default override for proc-macro-crate v3.5.0+ tries to
  # `--replace-fail` a literal string that no longer exists. Clearing
  # postPatch defeats the obsolete substitution; the runtime code path
  # is env-only (`CARGO_MANIFEST_DIR`) so the inlining isn't needed.
  proc-macro-crate = _: { postPatch = ""; };
}
