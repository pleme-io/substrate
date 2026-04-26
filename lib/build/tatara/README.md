# Tatara substrate builders — `tlisp2nix`

The crate2nix-analog for tatara-lisp programs. Turns a `.tlisp` file
(local or remote) into a content-addressed Nix derivation that runs
via `tatara-script`.

```
substrate/lib/build/tatara/
├── program.nix         the builder primitive (one program → one derivation)
├── program-flake.nix   the flake wrapper (multi-system, multi-program)
└── README.md
```

Implements the
[`theory/TATARA-PACKAGING.md`](https://github.com/pleme-io/theory/blob/main/TATARA-PACKAGING.md)
content-addressed packaging philosophy at the Nix layer. The /nix/store
becomes the second cache tier (the first being
`~/.cache/tatara/sources/` driven by `tatara-lisp-source`). Both caches
share the same BLAKE3 keying — fleet-wide store sharing is automatic.

## When to use which

| Situation | Use |
|---|---|
| One program with a flake of its own | `program-flake.nix` |
| Multiple programs in one workspace | `program-flake.nix` with N entries in `programs` |
| Embed in a larger flake's outputs | `program.nix` directly |
| Run a tatara-lisp script ad-hoc on the host | `tatara-script ./script.tlisp` (no Nix) |
| Run a content-pinned remote program | `program-flake.nix` with `source.type = "github"` + sha256 |

## Source descriptor shapes

```nix
# Local path — for in-flake authoring.
{ type = "local"; path = ./main.tlisp; }

# GitHub — content-pinned via fetchFromGitHub.
{ type = "github";
  owner  = "pleme-io";
  repo   = "programs";
  path   = "hello-world/main.tlisp";
  rev    = "v0.1.0";
  sha256 = "0000000000000000000000000000000000000000000000000000";
}

# GitLab — same shape.
{ type = "gitlab";
  owner = "..."; repo = "..."; path = "..."; rev = "..."; sha256 = "...";
}

# Generic URL — for direct fetches from any host.
{ type = "url"; url = "https://..."; sha256 = "..."; }
```

## Standardization mandate

Per the user's directive (2026-04-26): every tatara-lisp program in
pleme-io ships a flake that calls `program-flake.nix` (or
`program.nix` for embeds). No bespoke tatara-script wrapping; no
hand-rolled `nix run` apps; no per-program builder code.

The pattern propagates standardized:

1. Same `nix run .#<name>` UX across every program.
2. Same `/nix/store/<hash>-<name>` cache layout cluster-wide.
3. Same `tatara-script` runtime version everyone consumes.
4. Same `nix flake check` verification path.

Adding a new program is one `programs.<name> = { source = …; }` entry
in the consumer flake.

## See also

- [theory/TATARA-PACKAGING.md](https://github.com/pleme-io/theory/blob/main/TATARA-PACKAGING.md)
  — the philosophy
- [tatara-lisp-source](https://github.com/pleme-io/tatara-lisp/tree/main/tatara-lisp-source)
  — the host-side resolver (parallel cache)
- [substrate/lib/build/rust/tool-image-flake.nix](../rust/tool-image-flake.nix)
  — the Rust container builder these tatara builders mirror
- [substrate/lib/rust-workspace-release-flake.nix](../../rust-workspace-release-flake.nix)
  — the Rust workspace builder
