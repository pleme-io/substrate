# Fleet OSS-Publish Manifest (tiered)

Status: **PUBLISH-READY (staged)**. Re-tiered for the FULL current fleet on
2026-06-06. Supersedes the early 12-module subset manifest (which predated the
Rust engine, all `tundra-*` tools, the new Go leaves, and the borealis proofs).

This manifest enumerates EVERY publishable module in the fleet, its tier in the
topological publish order, its kind, its visibility, the **replaces-to-remove**
at tag time, and the release mechanism. Nothing here has been pushed, tagged, or
had its replaces removed — the removal lists are the operator's gated-publish
checklist. Tag order is **root→leaf** (VER-15): a module publishes only after
every module in its transitive `require` closure is already on the proxy /
crates.io, and its `replace` directives are stripped at its own tag step.

Three independent release tracks compose here:

| Track | Kind | Mechanism | Where |
|---|---|---|---|
| **Go libraries** | `:go-library` | `goLibraryFlakeBuilder` + `auto-release.yml → go-auto-release.yml` (pull-model: tag-only, `proxy.golang.org` fetches lazily; "publish" is a NO-OP confirm) | each repo |
| **Go tools / services** | `:go-tool`, `:go-service` | `goToolReleaseFlakeBuilder` + the same `go-auto-release.yml` pull-model | each repo |
| **Rust engine** | `:rust-library`, `:rust-tool` | crates.io PUSH chain `go-synthesizer → go-tool-synthesizer → pleme-doc-gen` (+ standalone `delivery-fsm`) via `cargo-auto-release.yml` | each repo |

Builders are resolved from `substrate.lib.${system}`:
`goLibraryFlakeBuilder` = `lib/build/go/library-flake.nix`,
`goToolReleaseFlakeBuilder` = `lib/build/go/tool-release-flake.nix`.
The reusable Go CI is `.github/workflows/go-auto-release.yml` (consumed by each
repo's `auto-release.yml` via `uses: pleme-io/substrate/.github/workflows/go-auto-release.yml@main`).

---

## Replace-directive shapes (read before the tier tables)

Every tier ≥ 1 `go.mod` resolves its committed siblings locally pre-publish. Two
shapes appear; both are **removed at publish** and the bare `require` then pins
the proxy-resolved tag:

1. **Single / multiple line `replace`** — tier-0-only consumers and the
   sub-modules. Example (`exec-go`):
   `replace github.com/pleme-io/errors-go => ../errors-go`.
2. **Grouped `replace ( … )` block ending `// REMOVED`** — the `tundra-*`
   tools and the multi-dep modules (`controller-go`, the borealis proofs, the
   examples). The block header reads
   `// DEV-LOCAL pre-publish resolution (fleet sibling pattern). REMOVED at publish …`.

**SDK carve-out (worlds-separate):** the four PRIVATE akeyless tools require
`github.com/akeylesslabs/akeyless-go/v5 v5.0.22` with **NO replace** — the public
upstream SDK resolves from the module proxy at its pinned tag. It is named ONLY
by the hand-written `internal/app/client_adapter.go`; the generated shell names
no backend (TOOLGEN-03). Removing replaces NEVER touches the SDK require.

**Sub-modules** (nested `go.mod` inside a parent repo — NO separate catalog
entry; they tag as `parent/sub@vX` on the parent repo):
`logging-go/console`, `logging-go/redact`, `metrics-go/otel`,
`auth-go/akeyless`, `shikumi-go/diag`.

---

## Tier 0 — zero pleme-io deps (publish first, any order, parallel-safe)

No `replace` directives (verified: `grep '=> '` empty for every entry below).

| Module | kind | visibility | replaces-to-remove | release mechanism |
|---|---|---|---|---|
| `errors-go` | :go-library | public | (none) | goLibraryFlakeBuilder + go-auto-release.yml |
| `logging-go` | :go-library | public | (none) | goLibraryFlakeBuilder + go-auto-release.yml |
| `metrics-go` | :go-library | public | (none) | goLibraryFlakeBuilder + go-auto-release.yml |
| `lifecycle-go` | :go-library | public | (none) | goLibraryFlakeBuilder + go-auto-release.yml |
| `shikumi-go` (core) | :go-library | public | (none — borealis back-edge was cut into `shikumi-go/diag`) | goLibraryFlakeBuilder + go-auto-release.yml |
| `todoku-go` | :go-library | public | (none) | goLibraryFlakeBuilder + go-auto-release.yml |
| `shigoto-go` | :go-library | public | (none) | goLibraryFlakeBuilder + go-auto-release.yml |
| `auth-go` (core) | :go-library | public | (none — `auth-go/akeyless` is the SUB-MODULE, tier 1) | goLibraryFlakeBuilder + go-auto-release.yml |
| `pleme-actions-shared-go` | :go-library | public | (none) | goLibraryFlakeBuilder + go-auto-release.yml |
| `token-cache-go` | :go-library | public | (none) | goLibraryFlakeBuilder + go-auto-release.yml |
| `tfplan-go` | :go-library | public | (none) | goLibraryFlakeBuilder + go-auto-release.yml |
| `k8sauthconfig-go` | :go-library | public | (none) | goLibraryFlakeBuilder + go-auto-release.yml |
| `python-synthesizer-go` | :go-library | public | (none — no pleme deps) | goLibraryFlakeBuilder + go-auto-release.yml |
| `dapr-component-generator` | :go-tool | public | (none) | goToolReleaseFlakeBuilder + go-auto-release.yml |
| `delivery-fsm` | :rust-library | public | (none — crates.io) | cargo-auto-release.yml → crates.io (standalone; no fleet consumers) |

---

## Tier 1 — depend on tier 0 only

| Module | kind | visibility | pleme deps | replaces-to-remove | release mechanism |
|---|---|---|---|---|---|
| `exec-go` | :go-library | public | errors-go | `=> ../errors-go` | goLibraryFlakeBuilder + go-auto-release.yml |
| `redactor-go` | :go-library | public | errors-go | `=> ../errors-go` | goLibraryFlakeBuilder + go-auto-release.yml |
| `secrettmpl-go` | :go-library | public | errors-go | `=> ../errors-go` | goLibraryFlakeBuilder + go-auto-release.yml |
| `ci-sink-go` | :go-library | public | errors-go | `=> ../errors-go` | goLibraryFlakeBuilder + go-auto-release.yml |
| `migration-harness-go` | :go-library | public | errors-go | `=> ../errors-go` | goLibraryFlakeBuilder + go-auto-release.yml |
| `manifest-renderer-go` | :go-library | public | errors-go | `=> ../errors-go` | goLibraryFlakeBuilder + go-auto-release.yml |
| `grafana-dashboard-go` | :go-library | public | errors-go | `=> ../errors-go` | goLibraryFlakeBuilder + go-auto-release.yml |
| `tundra-brew` | :go-library | public | errors-go | `=> ../errors-go` | goLibraryFlakeBuilder + go-auto-release.yml |
| `tundra-browser-replay` | :go-library | public | errors-go | `=> ../errors-go` | goLibraryFlakeBuilder + go-auto-release.yml |
| `tundra-events` | :go-library | public | errors-go | `=> ../errors-go` | goLibraryFlakeBuilder + go-auto-release.yml |
| `tundra-secret-mapping` | :go-library | public | errors-go | `=> ../errors-go` | goLibraryFlakeBuilder + go-auto-release.yml |
| `kubeclient-go` | :go-library | public | k8sauthconfig-go | `=> ../k8sauthconfig-go` | goLibraryFlakeBuilder + go-auto-release.yml |
| `refresh-loop-go` | :go-library | public | shigoto-go | `=> ../shigoto-go` | goLibraryFlakeBuilder + go-auto-release.yml |
| `cli-go` | :go-library | public | errors-go, shikumi-go | `=> ../shikumi-go`<br>`=> ../errors-go` | goLibraryFlakeBuilder + go-auto-release.yml |
| `kenshou-go` | :go-library | public | errors-go, shikumi-go | `=> ../errors-go`<br>`=> ../shikumi-go` | goLibraryFlakeBuilder + go-auto-release.yml |
| `server-go` | :go-library | public | lifecycle-go, logging-go, metrics-go | `=> ../logging-go`<br>`=> ../metrics-go`<br>`=> ../lifecycle-go` | goLibraryFlakeBuilder + go-auto-release.yml |

### Tier 1 sub-modules (parent + tier-0 only — could ship here; grouped into the sub-module wave)

| Sub-module | kind | visibility | replaces-to-remove |
|---|---|---|---|
| `logging-go/redact` | :go-library (sub) | public | `=> ../` (logging-go) |
| `metrics-go/otel` | :go-library (sub) | public | `=> ../` (metrics-go) |
| `auth-go/akeyless` | :go-library (sub) | public | `=> ../` (auth-go)<br>`=> ../../shikumi-go` |

> `auth-go/akeyless` is the elevated SDK-backed sibling (imports the public
> `akeyless-go/v5`); the four PRIVATE tools consume it via a `replace` plus the
> SDK no-replace require. It is a SUB-MODULE inside the `auth-go` repo — **NO
> separate catalog entry** — but it MUST be tagged before its tier-3 consumers.

---

## Tier 2 — depend on tier 1 (and below)

| Module | kind | visibility | pleme deps | replaces-to-remove | release mechanism |
|---|---|---|---|---|---|
| `cisink-write-go` | :go-library | public | ci-sink-go, errors-go | `=> ../ci-sink-go`<br>`=> ../errors-go` | goLibraryFlakeBuilder + go-auto-release.yml |
| `controller-go` | :go-library | public | errors-go, lifecycle-go, shigoto-go | block `replace ( … )`:<br>`errors-go => ../errors-go`<br>`lifecycle-go => ../lifecycle-go`<br>`shigoto-go => ../shigoto-go` | goLibraryFlakeBuilder + go-auto-release.yml |
| `tundra-openapi` | :go-library | public | errors-go | `=> ../errors-go` | goLibraryFlakeBuilder + go-auto-release.yml |
| `borealis` | :go-library | public | cli-go, shikumi-go (+errors-go transitive) | `=> ../shikumi-go`<br>`=> ../cli-go`<br>`=> ../errors-go` | goLibraryFlakeBuilder + go-auto-release.yml |

### Tier 2 sub-modules (require tier-2 `borealis` — MUST come after it)

| Sub-module | kind | visibility | replaces-to-remove |
|---|---|---|---|
| `shikumi-go/diag` | :go-library (sub) | public | `=> ../` (shikumi-go)<br>`=> ../../borealis` |
| `logging-go/console` | :go-library (sub) | public | `=> ../` (logging-go)<br>`=> ../../borealis` |

> The `shikumi-go ↔ borealis` module cycle was already cut: the sole
> borealis-importing package in `shikumi-go` (`diag`) lives in its own leaf
> sub-module, so the `shikumi-go` CORE (tier 0) carries zero pleme deps and
> `shikumi-go/diag` publishes here after borealis. `logging-go/console` follows
> the identical pattern.

---

## Tier 3 — depend on tier 2 (proofs + engine top + private akeyless tools)

### Rust engine top of the crates.io chain

| Module | kind | visibility | crates.io deps | replaces-to-remove | release mechanism |
|---|---|---|---|---|---|
| `go-synthesizer` | :rust-library | **public** (flip — see gated steps) | (leaf) | (none — crates.io) | cargo-auto-release.yml → crates.io |
| `go-tool-synthesizer` | :rust-library | public | go-synthesizer | path dep `go-synthesizer = { path = "../go-synthesizer" }` → switch to crates.io version | cargo-auto-release.yml → crates.io |
| `pleme-doc-gen` | :rust-tool | public | go-synthesizer, go-tool-synthesizer | `[patch."https://github.com/pleme-io/go-synthesizer"]` block + `go-tool-synthesizer = { path = "../…" }` → switch to published versions | cargo-auto-release.yml → crates.io |

> The Rust chain is a crates.io PUSH (contrast the Go pull-model). Order is
> strictly `go-synthesizer → go-tool-synthesizer → pleme-doc-gen`.
> `pleme-doc-gen` additionally path-deps `tatara-lisp` (the tatara repo) — an
> external-to-this-manifest dependency that must already be on crates.io; do NOT
> publish `pleme-doc-gen` until `tatara-lisp` resolves from the registry.

### PUBLIC generic borealis proofs (`:go-tool`)

All consume tier-2 `borealis`; each removes a grouped `replace ( … )` block
(except `borealis-fetch`, which uses individual `replace` lines and has NO
`go.work`). Those carrying a `go.work` remove **both** the `go.work` (+ `go.work.sum`)
AND the `replace` block at publish.

| Module | kind | visibility | pleme deps (replaces-to-remove) | go.work | release mechanism |
|---|---|---|---|---|---|
| `borealis-greet` | :go-tool | public | borealis, cli-go, errors-go, logging-go, shikumi-go | remove `go.work` | goToolReleaseFlakeBuilder + go-auto-release.yml |
| `borealis-svc` | :go-tool | public | borealis, cli-go, errors-go, lifecycle-go, logging-go, metrics-go, server-go, shikumi-go | remove `go.work` | goToolReleaseFlakeBuilder + go-auto-release.yml |
| `borealis-daemon` | :go-tool | public | borealis, cli-go, errors-go, logging-go, refresh-loop-go, shigoto-go, shikumi-go | remove `go.work` | goToolReleaseFlakeBuilder + go-auto-release.yml |
| `borealis-action` | :go-tool | public | borealis, cli-go, errors-go, logging-go, pleme-actions-shared-go, shikumi-go | remove `go.work` | goToolReleaseFlakeBuilder + go-auto-release.yml |
| `borealis-fetch` | :go-tool | public | borealis, cli-go, errors-go, logging-go, shikumi-go | (none) | goToolReleaseFlakeBuilder + go-auto-release.yml |
| `borealis-controller` | :go-tool | public | borealis, cli-go, controller-go, errors-go, lifecycle-go, logging-go, shikumi-go | remove `go.work` | goToolReleaseFlakeBuilder + go-auto-release.yml |

### PUBLIC vendor-free akeyless tool (`:go-tool`)

| Module | kind | visibility | pleme deps (replaces-to-remove) | release mechanism |
|---|---|---|---|---|
| `tundra-tfgen` | :go-tool | public | block `replace ( … )`: borealis, cli-go, errors-go, logging-go, shikumi-go, todoku-go, tundra-openapi | goToolReleaseFlakeBuilder + go-auto-release.yml |

> "Vendor-free" = it names NO akeyless SDK (no `akeyless-go/v5` require), so it
> stays PUBLIC. It still depends on tier-2 `tundra-openapi` + `borealis`, which
> is why it lives at tier 3, not tier 1.

### PRIVATE akeyless tools (`:go-tool` / `:go-service`, repo `:private`)

Each removes a grouped `replace ( … )` block ending `// REMOVED`. The
`akeyless-go/v5 v5.0.22` require has **NO replace** and is left untouched
(worlds-separate). Tagged like any tool, but the repo is `private`.

| Module | kind | visibility | pleme deps (replaces-to-remove) — SDK NOT removed | release mechanism |
|---|---|---|---|---|
| `tundra-auth` | :go-tool | **private** | auth-go, auth-go/akeyless, borealis, cli-go, errors-go, logging-go, shikumi-go | goToolReleaseFlakeBuilder + go-auto-release.yml (repo :private) |
| `tundra-ci-secrets` | :go-tool | **private** | auth-go, auth-go/akeyless, borealis, ci-sink-go, cisink-write-go, cli-go, errors-go, logging-go, pleme-actions-shared-go, shikumi-go, todoku-go | goToolReleaseFlakeBuilder + go-auto-release.yml (repo :private) |
| `tundra-gwbench` | :go-tool | **private** | auth-go, auth-go/akeyless, borealis, cli-go, errors-go, logging-go, metrics-go, shikumi-go, todoku-go | goToolReleaseFlakeBuilder + go-auto-release.yml (repo :private) |
| `tundra-authconfig-operator` | :go-service | **private** | auth-go, auth-go/akeyless, borealis, cli-go, controller-go, errors-go, kenshou-go, lifecycle-go, logging-go, metrics-go, shigoto-go, shikumi-go, todoku-go | goToolReleaseFlakeBuilder + go-auto-release.yml (repo :private); cluster operator reconcile after tag |

---

## Tier 4 — examples (leaf consumers; publish last)

Both carry BOTH a `go.work` (dev-local composition) AND a grouped
`replace ( … )` block. At publish, remove both; the bare `require` block pins
published tags.

| Module | kind | visibility | pleme deps (replaces-to-remove) | go.work | release mechanism |
|---|---|---|---|---|---|
| `borealis-cli-example` | :go-tool | public | borealis, cli-go, errors-go, logging-go, shikumi-go | remove `go.work` (+ `go.work.sum`) | goToolReleaseFlakeBuilder + go-auto-release.yml |
| `borealis-service-example` | :go-tool | public | auth-go, borealis, cli-go, errors-go, lifecycle-go, logging-go, metrics-go, server-go, shikumi-go | remove `go.work` (+ `go.work.sum`) | goToolReleaseFlakeBuilder + go-auto-release.yml |

---

## Visibility summary

Everything is **public** EXCEPT the four PRIVATE akeyless tools:
`tundra-auth`, `tundra-ci-secrets`, `tundra-gwbench`, `tundra-authconfig-operator`.

**Org-catalog fix:** `go-synthesizer` is currently mislabeled
`visibility: private` in
`pangea-architectures/workspaces/pleme-io-opensource/org.yaml` — **flip to
`public`** (it is the crates.io leaf of the public engine chain). This is the
one catalog edit outside substrate (see gated steps).

### Worlds-separate (private tools = public shell + private adapter)

A PRIVATE tool is a PUBLIC generated CLI shell (names NO akeyless backend —
TOOLGEN-03 fails the forge on a leaked backend token via
`go-tool-synthesizer::lower_guarded`) plus a hand-written private
`internal/app/client_adapter.go` — the ONLY file that imports
`akeyless-go/v5`. The repo is `:private` because of the adapter, not the shell.
This is why the SDK require survives the `replace` strip: it is consumed only by
the closed-world adapter, resolved from the public proxy at the pinned tag.

---

## Gated steps (the publish is not a single shot)

1. **substrate `feat/go-pattern-parity` → `main`.** The Go builders +
   `go-auto-release.yml` live on the current feat branch. Land that to `main`
   FIRST. Until then dependent flakes reference substrate at the feat-branch ref;
   after landing they switch from the local feat-branch ref to
   `github:pleme-io/substrate` (default branch). No Go/Rust module tags before
   substrate is on `main`.
2. **Rust engine feat-branch landing.** `pleme-doc-gen`'s Cargo.toml carries a
   `[patch."https://github.com/pleme-io/go-synthesizer"]` pointing at the
   `feat/canonicalize-go-ast` sibling checkout (the crate-root `GoFile` Render
   family is on that branch, not yet on go-synthesizer's default branch). Land
   `feat/canonicalize-go-ast` → `main` on `go-synthesizer`, publish
   `go-synthesizer` to crates.io, THEN drop the `[patch]` block and the
   `go-tool-synthesizer = { path = "../…" }` / `go-synthesizer = { git = … }`
   refs in `pleme-doc-gen` for the published crates.io versions. Crates.io order:
   `go-synthesizer → go-tool-synthesizer → pleme-doc-gen` (and `tatara-lisp`
   must already resolve from crates.io). `delivery-fsm` publishes independently.
3. **org.yaml flip.** Set `go-synthesizer.visibility: public` in
   `pangea-architectures/workspaces/pleme-io-opensource/org.yaml` and reconcile
   the org via the pangea-operator (or CLI fallback) so the GitHub repo flips
   public BEFORE the crate is published.
4. **Cluster / operator reconcile.** `tundra-authconfig-operator` is a
   `:go-service` running on a cluster: after its tag, reconcile the operator
   (Flux/operator) so the cluster picks up the published module.
5. **Tag-push order: root→leaf, replaces removed per tier (VER-15).** Walk the
   tiers in order; at each module's tag step remove that module's listed
   `replace` directives (and `go.work`/`go.work.sum` where present), then tag +
   push. The Go side is pull-model — `git push origin <tag>` is the only side
   effect; `proxy.golang.org` fetches lazily, so each module must be tagged
   before any consumer's tag step. Never strip the SDK no-replace require on the
   private tools.

Per-tier wave order:
**T0** (parallel) → **T1** (incl. tier-1 sub-modules) → **T2** (incl.
`shikumi-go/diag`, `logging-go/console` AFTER `borealis`) → **T3** (Rust chain
on crates.io; borealis proofs; `tundra-tfgen`; the four private tools; operator
reconcile) → **T4** (examples last).

---

## Internal-consistency verification

Verified against every module's `go.mod`/`Cargo.toml` in the live fleet checkout
on 2026-06-06 (`grep '^module' / '=> ' / akeyless-go/v5` per module):

- **Acyclicity / monotone tiers.** Every module's pleme `require` closure points
  strictly to a lower (or equal-but-prerequisite) tier. No back-edge: tier-0
  modules have zero `replace` directives (confirmed empty `grep '=> '`); the
  former `shikumi-go ↔ borealis` cycle is cut into `shikumi-go/diag` (tier 2).
- **Replaces ↔ requires match.** For each tier ≥ 1 module the listed
  replaces-to-remove are exactly the `replace … => ../sibling` lines present in
  its `go.mod` (single-line, grouped block, or sub-module `=> ../` / `=> ../../`),
  one per pleme require. No pleme require lacks a replace; no replace lacks a
  require.
- **SDK carve-out consistent.** The four private tools (and only those) require
  `akeyless-go/v5 v5.0.22` with no replace; that require is excluded from every
  replaces-to-remove list. `tundra-tfgen` has no SDK require → public.
- **Sub-modules have no catalog entry.** `logging-go/console`, `logging-go/redact`,
  `metrics-go/otel`, `auth-go/akeyless`, `shikumi-go/diag` are listed under their
  parents, not as standalone modules; `auth-go/akeyless` explicitly has no
  separate entry per spec.
- **go.work inventory.** `go.work` present on `borealis-greet`, `borealis-svc`,
  `borealis-daemon`, `borealis-action`, `borealis-controller`,
  `borealis-cli-example`, `borealis-service-example`; ABSENT on `borealis-fetch`
  (individual `replace` lines) — reflected in the tables.
- **Rust chain edges.** `go-tool-synthesizer` path-deps `go-synthesizer`;
  `pleme-doc-gen` git/path-deps both (+ `[patch]` to the feat-branch checkout) —
  the crates.io order and the patch-removal gated step follow directly.

### Confirmation

- No git tag, no push, no GitHub repo creation, no crates.io publish performed.
- No `replace` directive removed; no `go.work` removed.
- Only edits made: this manifest + the `go-synthesizer` org.yaml visibility flip.
