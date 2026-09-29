# ★ UNWIRED (measured 2026-09-29): nothing in substrate imports this file and no
# checkout under ~/code references `lib/rust-tool-image-flake.nix`. Kept, not deleted: wire it into
# lib/default.nix or retire it deliberately, rather than letting it drift.
#
# Shim — moved to build/rust/tool-image-flake.nix
import ./build/rust/tool-image-flake.nix
