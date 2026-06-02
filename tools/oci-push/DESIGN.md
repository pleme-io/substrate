# doca — typed OCI manager (destination + roadmap)

> Working crate name today: `oci-push`. Proposed Tier-2 name: **`doca`**
> (Portuguese, "dock" — where containers are loaded, stowed, and
> transferred). This doc is the *destination*; the crate grows into it
> phase by phase.

## Why

The fleet's release pipelines shell out to `skopeo`/`crane` for OCI image
movement. Per the NO-SHELL law + "acquire and contextualize, never just
consume," that external surface is **absorbed** into one typed pleme-io
primitive built on the fleet-standard `oci-client` crate (the same one
wasm-platform uses). One primitive owns the whole OCI-movement domain;
every pipeline calls it instead of bash + skopeo.

## Three swappable axes (the architecture)

The primitive is defined by three orthogonal, pluggable axes. Each axis is
a typed trait with selectable impls; the *semantics* are draped identically
over whichever impl is chosen.

### Axis 1 — Operation (the verbs)

Subcommand CLI: `doca <op> …`.

| op | meaning |
|----|---------|
| `push` | docker-archive tarball → registry (the core; built) |
| `pull` | registry → docker-archive / OCI-layout |
| `transfer` | registry → registry copy (the "transferer"; mount-optimized) |
| `inspect` | fetch + render manifest / config / layers |
| `tag` | add a tag to an existing manifest (no re-upload) |
| `delete` | remove a tag/manifest |
| `list` | list tags (registry-specific catalog) |

### Axis 2 — Transport backend (how bytes move) — ABSTRACTED, DONE for push

`trait PushBackend` today; generalizes to `trait Transport` across ops.

| backend | status | notes |
|---------|--------|-------|
| `native` (**default**) | built (push) | pure-Rust `oci-client`; no external binary; the two-digest-space handling (gzip layers → blob digest; verbatim config → diff_ids) is correct by construction |
| `skopeo` | built (push) | fallback / escape hatch; supplied on PATH by the flake wrapper |

### Axis 3 — Eval/run backend (how the tool + images are built & run) — DESIGNED

The substrate run-layer the tool is invoked through. Swappable nix ↔ sui.

| backend | status | notes |
|---------|--------|-------|
| `nix` (default today) | available | `nix run github:pleme-io/substrate#doca -- …` |
| `sui` (in-memory, the efficient default) | forward-looking | `sui run …#doca` — sui is the pure-Rust Nix (bytecode VM, ~3× CppNix); **fully in-memory** evaluation → no `/nix/store` round-trips for the tool's own closure → faster cold-start in CI. Becomes the default once `sui run flake#app` is production-ready. Image *building* can likewise move in-memory under sui. |

This axis is why "nix completely native, nix swappable with sui, sui
in-memory default" matters: the same `doca` invocation runs under either
evaluator; sui-in-memory is the optimization target.

## Surfaces

- **CLI** — typed subcommands + flags (no `format!`, typed error enum).
- **GitHub Action** — `action.yml` with typed inputs (`operation`,
  `source`, `dest`, `tags`, `transport`, `registry`, creds, concurrency,
  gzip-level). The action is a thin wrapper over `nix run …#doca` (or
  `sui run …#doca`), staying dependency-free (no pre-built pleme-io image
  → no bootstrap deadlock — the lesson from the old docker-action pusher).
- **shikumi config** — typed `DocaConfig` via `TieredConfig`
  (bare / discovered / prescribed_default): default registry + transport,
  named auth profiles, concurrency, gzip level. HM / NixOS / Darwin module
  trio per the fleet CONFIGURATION-MANAGEMENT rule.

## Optimizations (the "optimized transferer")

- Concurrent blob uploads (push layers in parallel, bounded).
- `HEAD`-dedup before upload (idempotent re-push; already free via oci-client).
- Cross-repo blob **mount** for `transfer` (skip re-upload when the dest
  already has a blob under a readable repo).
- Content-addressed local layer cache (skip re-gzip across runs).
- Streaming for large images (avoid whole-archive-in-memory; today push
  reads the archive fully — fine for action images, revisit for big ones).
- In-memory image build via sui (Axis 3).

## Roadmap

- **Phase 0 — DONE.** Native push core + skopeo fallback; transport-backend
  seam; compiles against `oci-client 0.13`. Docker-archive parse (outer-gzip
  detect, `manifest.json[0]`, config, layers) + per-layer gzip + `oci-client`
  push; multi-tag.
- **Phase 1 — wire + prove (load-bearing, next).** Build via substrate's
  crate2nix path (mirror wasm-platform's `oci-client` build); expose
  `packages.<system>.oci-push` (→ `doca`); **test native against a real
  ghcr push of a Nix docker-archive** before flipping the live pipeline;
  then replace the bash in `image-push.yml` with `nix run …#doca push …`.
  Keep skopeo fallback wired until native is proven in the fleet.
- **Phase 2 — operations. DONE (core).** Subcommand CLI: `push` (native +
  skopeo) · `transfer` (registry→registry, native oci-client pull+push, reuses
  gzipped blobs) · `inspect` (pull_manifest → render + digest) · `pull` (typed
  seam — registry→docker-archive reconstruction reserved). `tag`/`delete`/`list`
  remain. 6 unit tests (parse/gzip/protocol/reference) pass; compiles vs
  oci-client 0.13 (no new deps → nix build unaffected).
- **Phase 3 — shikumi `DocaConfig`** + HM/NixOS/Darwin module trio.
- **Phase 4 — `action.yml`** GitHub Action interface; register the action.
- **Phase 5 — optimizations** (parallel uploads, mount, cache).
- **Phase 6 — sui run/build backend** (Axis 3): nix↔sui swappable,
  in-memory default. **DEFERRED — grounded by a 2026-06-02 sui audit.**
  sui's `run` is not a `nix run` drop-in today: `FlakeRef::parse`
  (`sui-compat/src/flake_ref.rs`) is filesystem-only (no remote `github:`
  ref fetch), and `Run` (`src/main.rs`) execs an already-realized store
  path without building. The eval/input-fetch/native-builder pieces all
  exist and work (the real in-process-eval speed win), so it's wiring not
  greenfield (~weeks upstream: extend FlakeRef to fetch remote top-level
  flakes + make `run` build via the existing `LocalBuilder` + E2E tests).
  Note: "in-memory" is the *evaluator*, not the store/build (outputs still
  land in real `/nix/store`). Low-risk interim if speed is wanted sooner:
  a local-path `sui eval`/`build` fast-path behind the backend seam, with
  `nix run` fallback for remote refs.

Phases 2–6 are compounding; Phase 1 is the load-bearing step that actually
de-shells the live pipeline and must be proven against a real registry
push first (these images gate the whole fleet release pipeline).
