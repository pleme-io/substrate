# pleme-crate-overrides — fleet-wide buildRustCrate quirks.
#
# Layered on top of nixpkgs' `pkgs.defaultCrateOverrides` via attrset
# merge. Each entry follows the same `oldAttrs: newAttrs` shape nixpkgs
# uses, so consumers compose:
#
#   pkgs.defaultCrateOverrides // plemeCrateOverrides // userOverrides
#
# Adding a new fleet-wide quirk is a one-line edit here. No spec
# regeneration, no schema bump — the override mechanism is Nix-native.
{
  # rmcp 0.15 reads env!("CARGO_CRATE_NAME") at compile time
  # (src/model.rs:860). nixpkgs' buildRustCrate only exports
  # CARGO_PKG_* / CARGO_CFG_* / CARGO_MANIFEST_* — not a top-level
  # attr. `preBuild` runs in the same shell as buildCrate, so exporting
  # there reaches rustc.
  rmcp = _: { preBuild = "export CARGO_CRATE_NAME=rmcp"; };

  # alloc-no-stdlib / alloc-stdlib / brotli / brotli-decompressor
  # all ship example/CLI binaries under `src/bin/*.rs`. Previously
  # each was hand-listed here with `crateBin = []`. As of substrate
  # rev 2843381 the lockfile-builder suppresses bin auto-detection
  # for ALL transitive deps uniformly, making these entries
  # redundant. Kept commented as documentation of the bug class.
  # alloc-no-stdlib = _: { crateBin = []; };
  # alloc-stdlib = _: { crateBin = []; };
  # brotli = _: { crateBin = []; };
  # brotli-decompressor = _: { crateBin = []; };

  # ring 0.17.x's build.rs asserts that `CARGO_MANIFEST_LINKS`
  # matches the `[package] links = "ring_core_X_Y_Z_"` declared in
  # its Cargo.toml. nixpkgs' buildRustCrate already wires
  # `CARGO_MANIFEST_LINKS = crate.links` in its `configure-crate.nix`;
  # passing `links` as an override arg flows through.
  # Hardcoded value tracks ring's version — bump when ring bumps.
  # Gen-side proper fix: emit `links` into the build-spec so
  # lockfile-builder can pass it directly without an override.
  ring = _: { links = "ring_core_0_17_14_"; };

  # proc-macro-crate 3.5.0+ no longer has the literal
  # `env::var("CARGO")` string nixpkgs' default override tries to
  # substitute via `--replace-fail`. The substitution fails the
  # patchPhase. Override clears `postPatch` since v3.x's code path
  # no longer needs the cargo-binary inlining (it uses
  # `CARGO_MANIFEST_DIR` env-only). When proc-macro-crate updates
  # again, re-evaluate.
  proc-macro-crate = _: { postPatch = ""; };

  # wgpu-hal 25.0.2: cargo metadata filters out the `portable-atomic`
  # optional dep on platforms with native 64-bit atomics (aarch64,
  # x86_64) via a target-cfg gate, but the feature flag `portable-
  # atomic` stays enabled in the resolve graph. wgpu-hal's
  # `src/noop/mod.rs` then references `use portable_atomic::*` and
  # fails to compile because the extern is missing. Drop the
  # feature entirely — every target where mado/namimado run has
  # native 64-bit atomics, so the `noop/mod.rs` code path uses
  # the std AtomicU64 path. Upstream fix is in wgpu-hal's gating.
  wgpu-hal = attrs: {
    features = builtins.filter (f: f != "portable-atomic") (attrs.features or []);
  };
}
