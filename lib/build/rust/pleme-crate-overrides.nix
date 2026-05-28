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
# **Triple-aware with backward-compat shape.** The file exports
# *both*:
#
# 1. A function `triple -> overrides` (new shape, accessed via
#    `__functor` — call as `(import ./pleme-crate-overrides.nix) "x86_64-unknown-linux-musl"`).
#    Both substrate's mkBuiltTree and mkBinary use this path so
#    substrate-level safety nets fire only on the targets they're
#    protecting (e.g. strip apple-only features ONLY for non-apple
#    builds, not for apple builds that legitimately need them).
#
# 2. A legacy attrset (treats the file as the pre-I5 shape) for
#    every external pleme-io consumer that imports this directly
#    (repo-forge, tend, engenho, pleme-linker, kindling, frost,
#    tatara-lisp, cordel, forge, ayatsuri, nix/parts/overlays.nix).
#    These consumers do `defaultCrateOverrides = pkgs.defaultCrateOverrides // plemeCrateOverrides`
#    and need an attrset. The legacy attrset is `(forTriple "")`,
#    which evaluates the apple-detection branch to false (empty
#    triple matches nothing) and strips apple-only features
#    universally — identical to the pre-I5 behavior. Existing
#    consumers see no semantic change.
#
# Operator-side migration to the triple-aware shape is opt-in:
# replace `plemeCrateOverrides = import ...` with
# `plemeCrateOverrides = (import ...) <triple>` to get the
# triple-conditional strip. Done at the consumer's own pace.
#
# Adding entries: prefer registering a CrateQuirk in the Rust
# registry — it's typed, drift-checked by cse-lint, and
# discoverable by tooling. Use this file only when the bug is in
# nixpkgs' attribute.
let
  # Per-triple override factory. Both call shapes (new + legacy)
  # share this implementation.
  forTriple = triple:
    let
      # Detect apple targets (darwin / *-apple-*). Both schema-v5
      # triples (`aarch64-apple-darwin`, `x86_64-apple-darwin`) and
      # nixpkgs-style short names (`aarch64-darwin`, `x86_64-darwin`)
      # are recognized. Empty / null triple resolves to false →
      # strip behavior (the legacy default).
      isApple =
        triple != null
        && triple != ""
        && (
          builtins.match ".*apple.*" triple != null
          || builtins.match ".*darwin.*" triple != null
        );

      # Strip apple-only features from a feature list so non-apple
      # builds of the crate compile cleanly. Cargo's feature
      # unification is crate-global: any consumer enabling
      # `notify[macos_fsevent]` (or its default-features, which
      # include macos_fsevent in notify 8.2.0) activates it for
      # EVERY build of notify, including linux ones — where notify's
      # source then includes `mod fsevent;` that requires fsevent-sys
      # (apple-only) and fails to compile.
      #
      # On apple targets, KEEP the apple-only features — they're the
      # correct backend choice and consumers that opted into them
      # should actually get them. Stripping on apple would break
      # ayatsuri and any other consumer whose target-conditional dep
      # adds them.
      #
      # Uses `builtins.filter` (not `lib.filter`) to avoid requiring
      # an impure `<nixpkgs>` lookup — pleme-crate-overrides.nix is
      # imported in pure-eval flake context where `<nixpkgs>` is
      # unavailable.
      stripAppleOnlyFeatures = features:
        if isApple
        then features
        else
          builtins.filter (f:
            f != "macos_fsevent"
            && f != "fsevent-sys"
          ) features;
    in {
      # nixpkgs' default override for proc-macro-crate v3.5.0+ tries
      # to `--replace-fail` a literal string that no longer exists.
      # Clearing postPatch defeats the obsolete substitution; the
      # runtime code path is env-only (`CARGO_MANIFEST_DIR`) so the
      # inlining isn't needed.
      proc-macro-crate = _: { postPatch = ""; };

      # notify's default feature includes macos_fsevent → pulls
      # fsevent-sys everywhere via cargo's crate-global feature
      # unification. Strip apple-only features ONLY from non-apple
      # builds so linux builds use inotify (auto-selected when
      # macos_fsevent is off). Apple builds keep the features.
      notify = attrs: {
        features = stripAppleOnlyFeatures (attrs.features or []);
      };
    };

  # Legacy attrset: empty triple → false isApple → strip behavior.
  # Identical to the pre-I5 unconditional strip. Existing external
  # consumers see no semantic change at the attrset call site.
  legacy = forTriple "";
in
  # Compose: legacy keys at the top level (so `value.notify` works
  # for backward-compat callers) + `__functor` so `value triple`
  # works for triple-aware callers. The `//` shallow-merge keeps
  # both surfaces visible.
  legacy // {
    __functor = _: triple: forTriple triple;
  }
