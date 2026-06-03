# Go Fleet Publish Manifest (borealis-style)

Status: **PUBLISH-READY** (post-cycle-fix). Generated 2026-06-03.

This manifest enumerates every module + sub-module in the borealis-style Go
fleet, its position in the topological publish order, its pleme-io dependencies,
and the EXACT local-development `replace` directives + `go.work` files that must
be removed at tag time. **Nothing here has been pushed, tagged, or had its
replaces removed** — the removal lists below are the operator's checklist for
the gated publish step.

---

## 1. The cycle that was fixed

Before this work the fleet had a **module cycle** blocking an ordered publish:

```
shikumi-go (MAIN)  --requires-->  borealis     (shikumi-go/diag rendered diagnostics via borealis/comp + borealis/theme)
borealis  (MAIN)   --requires-->  shikumi-go   (borealis/cfg loads borealis.Config via shikumi)
```

`shikumi-go <-> borealis` was a true module-level cycle. Fixed exactly as
`logging-go/console` already solved the identical problem: the sole borealis-importing
package in shikumi-go (`diag`) was moved into its **own leaf sub-module** so the
shikumi-go CORE module carries **zero pleme-io deps**.

### Change applied (NOT committed — orchestrator commits)

- **Created** `shikumi-go/diag/go.mod`
  → `module github.com/pleme-io/shikumi-go/diag`
  → `require` borealis (`replace ../../borealis`) + shikumi-go (`replace ../`)
  → mirrors `logging-go/console/go.mod` exactly.
- **Removed** `github.com/pleme-io/borealis v0.1.0` from `shikumi-go`'s MAIN
  `go.mod` require block; `go mod tidy` pruned the now-unused charmbracelet
  indirect closure (lipgloss/termenv/colorprofile/ansi/cellbuf/go-isatty/…).
- `go mod tidy` run on both `shikumi-go` core and `shikumi-go/diag`.

### shikumi-go core pleme deps: BEFORE → AFTER

| | pleme-io module deps (`go list -m all | grep pleme-io`) |
|---|---|
| **BEFORE** | `github.com/pleme-io/shikumi-go` (self) + `github.com/pleme-io/borealis v0.1.0` |
| **AFTER**  | `github.com/pleme-io/shikumi-go` (self) **only — ZERO pleme deps** |

Verification (all green):
- `shikumi-go` core — `go build ./...` OK, `go test ./...` OK (root, akeyless, flags, schema).
- `shikumi-go/diag` sub-module — `go build ./...` OK, `go test ./...` OK.

---

## 2. Module inventory + tiers + pleme deps + removal checklist

Tier = position in the topological publish order (lower tier publishes first).
`v0.0.0` requires are pre-publish placeholders resolved by the local `replace`/`go.work`.

### Tier 0 — zero-pleme-dep libraries (publish first, any order)

| Module path | pleme deps | replace directives to remove | go.work to remove |
|---|---|---|---|
| `github.com/pleme-io/errors-go` | none | (none) | (none) |
| `github.com/pleme-io/logging-go` | none | (none) | (none) |
| `github.com/pleme-io/metrics-go` | none | (none) | (none) |
| `github.com/pleme-io/lifecycle-go` | none | (none) | (none) |
| `github.com/pleme-io/auth-go` | none | (none) | (none) |
| `github.com/pleme-io/shikumi-go` | **none** (was: borealis — cut by this fix) | (none — core has no replaces post-fix) | (none) |

### Tier 1 — `cli-go` (depends on tier-0 errors-go + shikumi-go)

| Module path | pleme deps | replace directives to remove (in `cli-go/go.mod`) | go.work |
|---|---|---|---|
| `github.com/pleme-io/cli-go` | `errors-go`, `shikumi-go` (core only; both via cli leaves — Law 8) | `replace github.com/pleme-io/shikumi-go => ../shikumi-go`<br>`replace github.com/pleme-io/errors-go => ../errors-go` | (none) |

### Tier 2 — `borealis` (depends on cli-go + shikumi-go; errors-go transitive)

| Module path | pleme deps | replace directives to remove (in `borealis/go.mod`) | go.work |
|---|---|---|---|
| `github.com/pleme-io/borealis` | `cli-go`, `shikumi-go` (+ `errors-go` transitive) | `replace github.com/pleme-io/shikumi-go => ../shikumi-go`<br>`replace github.com/pleme-io/cli-go => ../cli-go`<br>`replace github.com/pleme-io/errors-go => ../errors-go` | (none) |

### Tier 3 — leaf sub-modules + server-go (depend on tier 0–2)

| Module path | pleme deps | replace directives to remove | go.work |
|---|---|---|---|
| `github.com/pleme-io/shikumi-go/diag` | `shikumi-go`, `borealis` | `replace github.com/pleme-io/shikumi-go => ../`<br>`replace github.com/pleme-io/borealis => ../../borealis` (in `shikumi-go/diag/go.mod`) | (none) |
| `github.com/pleme-io/logging-go/console` | `logging-go`, `borealis` | `replace github.com/pleme-io/logging-go => ../`<br>`replace github.com/pleme-io/borealis => ../../borealis` (in `logging-go/console/go.mod`) | (none) |
| `github.com/pleme-io/logging-go/redact` | `logging-go` | `replace github.com/pleme-io/logging-go => ../` (in `logging-go/redact/go.mod`) | (none) |
| `github.com/pleme-io/metrics-go/otel` | `metrics-go` | `replace github.com/pleme-io/metrics-go => ../` (in `metrics-go/otel/go.mod`) | (none) |
| `github.com/pleme-io/auth-go/akeyless` | `auth-go`, `shikumi-go` | `replace github.com/pleme-io/auth-go => ../`<br>`replace github.com/pleme-io/shikumi-go => ../../shikumi-go` (in `auth-go/akeyless/go.mod`) | (none) |
| `github.com/pleme-io/server-go` | `lifecycle-go`, `metrics-go`, `logging-go` | `replace github.com/pleme-io/logging-go => ../logging-go`<br>`replace github.com/pleme-io/metrics-go => ../metrics-go`<br>`replace github.com/pleme-io/lifecycle-go => ../lifecycle-go` (in `server-go/go.mod`) | (none) |

> Sub-module tiering note: `logging-go/redact`, `metrics-go/otel`, and `auth-go/akeyless`
> only need their parent + tier-0 deps and could publish as early as tier 1; they are
> grouped in tier 3 with the borealis-dependent leaves for a single "sub-modules last"
> publish wave. `shikumi-go/diag` and `logging-go/console` genuinely require tier-2
> `borealis` and MUST come after it.

### Tier 4 — examples (leaf consumers; publish last)

| Module path | pleme deps | replace directives to remove | go.work to remove |
|---|---|---|---|
| `github.com/pleme-io/borealis-cli-example` | `borealis`, `cli-go`, `errors-go`, `logging-go`, `shikumi-go` | block `replace ( … )` of all 5 in `borealis-cli-example/go.mod` | `borealis-cli-example/go.work` (+ `go.work.sum`) |
| `github.com/pleme-io/borealis-service-example` | `auth-go`, `borealis`, `cli-go`, `errors-go`, `lifecycle-go`, `logging-go`, `metrics-go`, `server-go`, `shikumi-go` | block `replace ( … )` of all 9 in `borealis-service-example/go.mod` | `borealis-service-example/go.work` (+ `go.work.sum`) |

> The examples carry BOTH a `go.work` (dev-local composition, gitignored) AND a
> per-module `replace ( … )` block. At publish time both are removed and the
> `require` block pins the published tags (the examples already pin `borealis v0.1.0`).

---

## 3. The acyclic DAG (post-fix)

```
                 tier 0 (zero pleme deps)
   errors-go   logging-go   metrics-go   lifecycle-go   auth-go   shikumi-go
       │            │            │            │            │          │
       │            │            │            │            │          │
       └──────┬─────┘            │            │            │          │
              ▼ (errors-go, shikumi-go)       │            │          │
   tier 1   cli-go ◄─────────────────────────────────────────────────┘
              │
              ▼ (cli-go, shikumi-go, +errors-go)
   tier 2   borealis
              │
   tier 3   ┌─┴───────────────────────────────────────────────────────┐
            ▼                ▼                                          ▼
   shikumi-go/diag   logging-go/console                 server-go (logging+metrics+lifecycle)
   (shikumi+borealis)(logging+borealis)                 logging-go/redact (logging)
                                                        metrics-go/otel  (metrics)
                                                        auth-go/akeyless (auth+shikumi)
              │
   tier 4   borealis-cli-example      borealis-service-example
            (consumes tiers 0–2)      (consumes tiers 0–3)
```

**Acyclicity proof** (`go list -m all`, replaces active):
- `shikumi-go` core transitive pleme deps: **{self only}** — the back-edge to borealis is gone.
- `cli-go` transitive pleme deps: `{errors-go, shikumi-go}` — no borealis (it dropped out once shikumi-go core stopped pulling it).
- `borealis` transitive pleme deps: `{cli-go, errors-go, shikumi-go}` — no path returns to borealis.
- No module's transitive closure contains a module that (transitively) depends on it. **DAG is acyclic.**

---

## 4. Precise tiered publish order

Tag + push + (proxy-confirm) in this order; remove the listed replaces/go.work
for each module at its tag step (root→leaf, per VER-15):

1. **tier 0** (parallel-safe): `errors-go`, `logging-go`, `metrics-go`, `lifecycle-go`, `auth-go`, `shikumi-go`
2. **tier 1**: `cli-go`
3. **tier 2**: `borealis`
4. **tier 3** (sub-modules + service, after their parents/borealis):
   `shikumi-go/diag`, `logging-go/console`, `logging-go/redact`, `metrics-go/otel`, `auth-go/akeyless`, `server-go`
5. **tier 4** (examples, last): `borealis-cli-example`, `borealis-service-example`

---

## 5. Local build verification (current replaces/go.work, post-fix)

| Module | build | test |
|---|---|---|
| errors-go, logging-go, metrics-go, lifecycle-go, auth-go | OK | — (spot) |
| shikumi-go (core) | OK | OK (root/akeyless/flags/schema) |
| shikumi-go/diag | OK | OK |
| cli-go | OK | — |
| borealis | OK | — |
| logging-go/redact, metrics-go/otel, auth-go/akeyless | OK | — |
| server-go | OK | — |
| borealis-cli-example | OK (go.work) | — |
| borealis-service-example | compiles (`go vet ./...` OK, libs + `CGO_ENABLED=0 go build ./...` OK) | — |

### Pre-existing issues found (NOT caused by the cycle fix, NOT touched)

- **`logging-go/console` go.mod drift** — its `go.mod` pins the OLD charmbracelet
  stack (`charmbracelet/lipgloss v1.1.0`, `go 1.25`) while the `borealis` it
  imports has moved to `charm.land/lipgloss/v2`. `go build ./...` there fails with
  "updates to go.mod needed; to update it: go mod tidy". A `go mod tidy` in
  `logging-go/console` resolves it (bumps to the v2 charm stack + `go 1.25.8`).
  This is independent logging-go publish-readiness work — left untouched here.
- **`borealis-service-example` cmd link failure** — `ld: library not found for
  -lresolv` when CGO links the `net` package into the binary. A local Nix-clang
  toolchain gap, not a dependency-graph problem: `go vet ./...`, library-package
  builds, and `CGO_ENABLED=0 go build ./...` all succeed.

---

## 6. Confirmation

- **No git commit** (orchestrator commits the cycle fix).
- **No push, no tag, no GitHub repo creation.**
- **No `replace` directive removed** — all listed above remain in place.
- **No `go.work` removed** — both example `go.work` files remain in place.

The fix is staged in the working tree only:
`shikumi-go/diag/go.mod` (new), `shikumi-go/diag/go.sum` (new),
`shikumi-go/go.mod` (borealis require removed + indirect closure pruned),
`shikumi-go/go.sum` (pruned).
