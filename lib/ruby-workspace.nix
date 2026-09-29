# ★ UNWIRED (measured 2026-09-29): nothing in substrate imports this file and no
# checkout under ~/code references `lib/ruby-workspace.nix`. Kept, not deleted: wire it into
# lib/default.nix or retire it deliberately, rather than letting it drift.
#
# Shim — moved to build/ruby/workspace.nix
import ./build/ruby/workspace.nix
