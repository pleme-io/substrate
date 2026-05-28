# pleme-crate-overrides — residual nixpkgs-side fleet quirks (triple-aware).
#
# Per-crate `CrateQuirk` knowledge MIGRATED to typed Rust at
# `pleme-io/gen/crates/gen-cargo/src/quirks.rs::REGISTRY`. Dispatch
# happens in `./quirk-apply.nix` consumed by lockfile-builder.
#
# This file now only holds overrides for crates whose bug is in
# nixpkgs' own `defaultCrateOverrides` (not in any upstream
# third-party crate), so they can't be expressed as a CrateQuirk.
#
# **Triple-aware**. The file exports a function `triple -> overrides`.
# Both call sites (lockfile-builder.nix:mkBuiltTree and
# tool-release.nix:mkBinary) pass the target triple they're building
# for so overrides can specialize per-target — critical for
# substrate-level safety nets that should only fire on the targets
# they're protecting (e.g. strip apple-only features ONLY for
# non-apple builds, not for apple builds that legitimately need them).
#
# Adding entries: prefer registering a CrateQuirk in the Rust
# registry — it's typed, drift-checked by cse-lint, and
# discoverable by tooling. Use this file only when the bug is in
# nixpkgs' attribute.
triple:
let
  # Detect apple targets (darwin / *-apple-*). Both schema-v5 triples
  # (`aarch64-apple-darwin`, `x86_64-apple-darwin`) and nixpkgs-style
  # short names (`aarch64-darwin`, `x86_64-darwin`) are accepted. The
  # `triple` parameter is required — if a caller passes `null` or
  # omits the arg, the function throws on first use; intentional, so
  # the wiring gap surfaces mechanically rather than silently picking
  # the wrong branch.
  isApple =
    builtins.match ".*apple.*" triple != null
    || builtins.match ".*darwin.*" triple != null;

  # Strip apple-only features from a feature list so non-apple builds
  # of the crate compile cleanly. Cargo's feature unification is
  # crate-global: any consumer enabling `notify[macos_fsevent]` or
  # the default-features (which include macos_fsevent in notify 8.2.0)
  # activates it for EVERY build of notify, including linux ones —
  # where notify's source then includes `mod fsevent;` that requires
  # fsevent-sys (apple-only) and fails to compile.
  #
  # On apple targets, KEEP the apple-only features — they're the
  # correct backend choice and consumers that opted into them should
  # actually get them. Stripping on apple would break ayatsuri and
  # any other consumer whose target-conditional dep adds them.
  #
  # The proper fix is consumer-side (set default-features = false +
  # select cross-platform backends), but that requires every consumer
  # in the fleet's transitive dep tree to update. This filter is the
  # substrate-level safety net that closes the leak class regardless
  # of consumer pin staleness — apple-only features only activate on
  # apple targets via target-conditional features (in target-resolves)
  # OR they're explicitly safe on linux.
  #
  # Uses `builtins.filter` (not `lib.filter`) to avoid requiring an
  # impure `<nixpkgs>` lookup — pleme-crate-overrides.nix is imported
  # in pure-eval flake context where `<nixpkgs>` is unavailable.
  stripAppleOnlyFeatures = features:
    if isApple
    then features
    else
      builtins.filter (f:
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
  # apple-only features ONLY from non-apple builds so linux builds use
  # inotify (auto-selected when macos_fsevent is off). Apple builds
  # keep the features.
  notify = attrs: {
    features = stripAppleOnlyFeatures (attrs.features or []);
  };
}
