# Example caixas — the ultimate reusability layer

Six reference `.caixa.lisp` sources showing how ONE typed Lisp
form declares the full operator-facing surface for any pleme-io
artifact. Per ACTION-AS-CAIXA M3-M4: caixas absorb the
hand-authored boundary between source + CI + catalog + docs.

## The 6 examples

| Caixa | Ecosystem | Kind | Renders to |
|---|---|---|---|
| `rust-library.caixa.lisp` | crates.io | `:Biblioteca` | Cargo.toml + 3 CI shims + .pleme-io-release.toml |
| `rust-workspace.caixa.lisp` | crates.io | `:Supervisor` | workspace Cargo.toml + N member toml + CI shims |
| `npm-package.caixa.lisp` | npmjs.org | `:Biblioteca` | package.json + CI shims |
| `python-package.caixa.lisp` | pypi.org | `:Biblioteca` | pyproject.toml + CI shims |
| `helm-chart.caixa.lisp` | OCI registry | `:Aplicacao` | Chart.yaml + values + CI shims + optional cd-stack |
| `github-action.caixa.lisp` | ghcr action image + v1 ref | `:GhAction` | action.yml + run.tlisp + README + patterns entry |

## The compounding payoff

Today (pre-M3):
- A new Rust library requires:
  hand-authored Cargo.toml + 3 yaml shims + .pleme-io-release.toml = ~80 lines

After M3 (caixa-renderer):
- A new Rust library = ONE `.caixa.lisp` source file (~20 lines)
- Renderer emits all 5 downstream artifacts mechanically

Across the projected ~500 pleme-io repos:
- ~40,000 lines of hand-authored adoption surface → ~10,000 lines of typed source
- Catalog stays in sync forever (it's a renderer output, not a hand-maintained mirror)
- Adding new ecosystems = extending the renderer once, all consumers absorb the new defaults

## The unification

Notice `github-action.caixa.lisp` — an action IS a caixa
(specialized to `:kind :GhAction`). The same operator-facing
form declares libraries / workspaces / packages / charts /
ACTIONS. **One typed primitive covers every artifact class
the pleme-io substrate produces.**

## How to render (post-M3)

```bash
# Render any .caixa.lisp into the target repo
pleme-release render-caixa rust-library.caixa.lisp --out ./

# Renders Cargo.toml + .pleme-io-release.toml + 3 .github/workflows/*.yml
```

The renderer becomes a callable substrate primitive at the GH
action layer too (`pleme-io/actions/caixa-render` already ships
the M0 wrapper for feira).

## Related substrate docs

- [INTERLOCK.md](../../../docs/INTERLOCK.md) — the unified vision
- [ACTION-AS-CAIXA.md](../../../docs/ACTION-AS-CAIXA.md) — the M0-M5 roadmap
- [renderer-poc/](../renderer-poc/) — working `(defaction)` + `(defworkflow)` POC
- [example-config.toml](../example-config.toml) — the `.pleme-io-release.toml` schema

## Status

**M0 — example sources committed.** The renderer that produces
the downstream artifacts is tracked under ACTION-AS-CAIXA M3
in arch-synthesizer. Until M3 ships, these `.caixa.lisp` files
serve as:

1. **Reference shapes** for hand-authors implementing the
   directive today
2. **Schema documentation** for the renderer's target output
3. **Tests** — the M3 renderer's output must reproduce these
   examples byte-for-byte when run against an empty repo
