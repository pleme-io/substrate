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
let
  lib = (import <nixpkgs> {}).lib;

  # Strip apple-only features from a feature list so linux builds of
  # the crate compile cleanly. Cargo's feature unification is crate-
  # global: any consumer enabling `notify[macos_fsevent]` or its
  # default-features (which include macos_fsevent in notify 8.2.0)
  # activates it for EVERY build of notify, including linux ones —
  # where notify's source then includes `mod fsevent;` that requires
  # fsevent-sys (apple-only) and fails to compile.
  #
  # The proper fix is consumer-side (set default-features = false +
  # select cross-platform backends), but that requires every consumer
  # in the fleet's transitive dep tree to update. This filter is the
  # substrate-level safety net that closes the leak class regardless
  # of consumer pin staleness — apple-only features only activate on
  # apple targets via target-conditional features (in target-resolves)
  # OR they're explicitly safe on linux.
  stripAppleOnlyFeatures = features:
    lib.filter (f:
      f != "macos_fsevent"
      && f != "fsevent-sys"
    ) features;
in {
  # nixpkgs' default override for proc-macro-crate v3.5.0+ tries to
  # `--replace-fail` a literal string that no longer exists. Clearing
  # postPatch defeats the obsolete substitution; the runtime code path
  # is env-only (`CARGO_MANIFEST_DIR`) so the inlining isn't needed.
  proc-macro-crate = _: { postPatch = ""; };

  # notify's default feature includes macos_fsevent → pulls fsevent-sys
  # everywhere via cargo's crate-global feature unification. Strip
  # apple-only features from any notify build so linux builds use
  # inotify (auto-selected when macos_fsevent is off).
  notify = attrs: {
    features = stripAppleOnlyFeatures (attrs.features or []);
  };
}
