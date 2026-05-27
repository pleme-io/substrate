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

  # alloc-no-stdlib ships an example binary `src/bin/heap_alloc.rs`
  # whose `use alloc_no_stdlib;` / `use core;` only resolve when the
  # crate is built with `cargo build --example heap_alloc` (which
  # supplies the `--extern alloc_no_stdlib=…` link), not via
  # buildRustCrate's binary auto-discovery. Suppress the bin —
  # consumers only ever pull the library.
  alloc-no-stdlib = _: { crateBin = []; };

  # alloc-stdlib has the same shape — `src/bin/integration.rs`
  # depends on the lib being externally linked. Suppress the bin.
  alloc-stdlib = _: { crateBin = []; };

  # brotli + brotli-decompressor ship CLI binaries (`src/bin/brotli.rs`,
  # `src/bin/decompress.rs`) under the same auto-discovery footgun.
  # Consumers always pull the lib (datafusion / parquet / shinryu-mcp).
  brotli = _: { crateBin = []; };
  brotli-decompressor = _: { crateBin = []; };
}
