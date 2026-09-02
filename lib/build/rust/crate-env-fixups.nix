# Crate overrides for third-party crates that read a compile-time environment
# variable nixpkgs' `buildRustCrate` does not export.
#
# ── WHY THIS FILE EXISTS ────────────────────────────────────────────────────
# Cargo sets `CARGO_CRATE_NAME` per crate. `buildRustCrate` exports only the
# `CARGO_PKG_*`, `CARGO_CFG_*` and `CARGO_MANIFEST_*` families, so any crate
# calling `env!("CARGO_CRATE_NAME")` fails to COMPILE under every crate2nix
# builder:
#
#   error: environment variable `CARGO_CRATE_NAME` not defined at compile time
#
# It must go in via `preBuild` — that runs in the same shell as `buildCrate`,
# where a top-level attribute does not reach the rustc child.
#
# ── WHY IT IS SHARED RATHER THAN COPIED ─────────────────────────────────────
# `library.nix` carried this fix and `library-workspace.nix` did not, so the
# same rmcp dependency built in a single-crate library and failed in a
# workspace. That asymmetry is invisible from a consumer's Cargo.toml: the
# crate, the version and the feature set are identical, and only the builder
# differs. Landing it in one file makes the two builders agree by construction
# instead of by whoever remembered to copy the line.
#
# The cost of the asymmetry, measured: mukae gated its MCP face off behind an
# optional feature because enabling it broke `mukae-greeter` → `greetd.toml` →
# `system-path` → `nixos-system-plo`, taking plo's LOGIN SCREEN out of the
# build and leaving the node gitops-degraded for 47 reconcile cycles
# (2026-08-28). mado carries the same rmcp 0.15 and was fine throughout,
# because `substrate.rust.tool` builds it.
#
# ── ADDING A CRATE ──────────────────────────────────────────────────────────
# One entry per third-party crate, named for the variable it reads. Keep it to
# crates whose need is a MEASURED build failure, not a precaution: an override
# that is not needed is indistinguishable from one that is, and the next reader
# cannot tell which are load-bearing.
{
  # rmcp 0.15 reads it at src/model.rs:860.
  rmcp = _: { preBuild = "export CARGO_CRATE_NAME=rmcp"; };
}
