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
  # its Cargo.toml. Cargo sets that env var from the manifest;
  # buildRustCrate doesn't propagate it to the build script
  # subprocess even when set at the drv level. `preBuild` runs in
  # the same shell as buildCrate (same shape as the rmcp override
  # above) so exporting there reaches the build script's env.
  # Hardcoded value tracks ring's version — bump when ring bumps.
  # Gen-side proper fix: emit `links` into the build-spec so
  # lockfile-builder can wire CARGO_MANIFEST_LINKS automatically.
  ring = _: { preBuild = ''export CARGO_MANIFEST_LINKS="ring_core_0_17_14_"''; };
}
