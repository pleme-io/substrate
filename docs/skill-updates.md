# Skill Updates Needed

The following Claude Code skills in blackmatter-claude and blackmatter-pleme
need updates to reflect the new scaffold system and metaframework. Apply these
changes in the respective repos and rebuild.

## blackmatter-claude/skills/build/SKILL.md

Add to the intent-to-recipe table (Step 2):

```
| Leptos PWA (web frontend) | `leptos-build.nix` | `leptos-build-flake.nix` |
| Rust WASM (WASI service) | `wasi-service.nix` | `wasi-service-flake.nix` |
| Dioxus desktop/mobile | Use standard Rust build | — |
| GPU app (garasu+egaku) | Use standard Rust build | — |
```

Add a new Step 0 before Step 1:

```markdown
## Step 0: Check for Scaffolds

Before diving into build recipes, check if a scaffold can generate the
entire project. Scaffolds produce a complete, compilable project with
flake.nix, Cargo.toml, source files, and deployment specs.

| Intent | Scaffold |
|--------|----------|
| New Leptos PWA frontend | `leptosAppScaffold` |
| New Axum backend service | `rustServiceScaffold` |
| New CLI tool | `rustToolScaffold` |
| New Dioxus desktop/mobile app | `dioxusAppScaffold` |
| New GPU-rendered app | `gpuAppScaffold` |
| New Ruby/Pangea gem | `rubyGemScaffold` |

Usage:
\`\`\`nix
scaffold = import "${substrate}/lib/leptos-app-scaffold.nix" { inherit lib; };
app = scaffold.generate ({
  name = "my-project";
} // scaffold.templates.standard);
\`\`\`

If a scaffold exists, use it. It generates a project that already uses
the right substrate builder.
```

## blackmatter-pleme/skills/platform-creation/SKILL.md

Add scaffold awareness to the architecture decision tree:

```markdown
## Scaffold-First Creation

Before manually scaffolding, check if a substrate scaffold exists:

- Web frontend → `/build` skill → `leptosAppScaffold`
- Backend API → `/build` skill → `rustServiceScaffold`
- CLI tool → `/build` skill → `rustToolScaffold`
- Desktop app → `/build` skill → `dioxusAppScaffold` or `gpuAppScaffold`

Scaffolds generate complete projects with pleme-app-core (framework infra)
and pleme-mui (web components) pre-wired. Only use manual platform-creation
for project types without a matching scaffold.
```

## blackmatter-pleme/skills/rust-wasm/SKILL.md

Update to reference the Leptos builder alongside Yew:

```markdown
## Leptos PWA (NEW — recommended for web applications)

For full-featured web PWAs with SSR+CSR, use the Leptos builder:

**Builder:** `substrate/lib/build/rust/leptos-build.nix`
**Flake:** `substrate/lib/build/rust/leptos-build-flake.nix`
**Scaffold:** `substrate/lib/build/rust/leptos-app-scaffold.nix`

The Leptos builder produces:
- SSR server binary (native Rust)
- CSR WASM bundle (wasm32-unknown-unknown + wasm-bindgen + wasm-opt)
- Combined deployment package
- Docker image

Framework crates pre-wired:
- `pleme-app-core` — providers, hooks, state machines, cache, observability
- `pleme-mui` — 92 Material Web + MUI island components

## Yew WASM (legacy — for simple CSR-only apps)

For CSR-only WASM apps without SSR, use the existing Yew builder.
```

## blackmatter-pleme/skills/convergence-computing/SKILL.md

Add a section on the metaframework connection:

```markdown
## Application Convergence

The pleme-io metaframework applies convergence computing to application
development. Every UI interaction is a convergence step:

- Auth: Unauthenticated → token → verified → authenticated
- Auto-save: Changed → debouncing → saving → saved
- Query cache: Stale → fetch → fresh
- PWA: Uncached → precaching → offline-capable

Framework crate: `pleme-app-core` implements these as pure state machines
with convergence tracing:

\`\`\`rust
use pleme_app_core::convergence::{ConvergencePhase, trace_convergence};
trace_convergence("auth-session", ConvergencePhase::Verify, 0.3);
\`\`\`

See: substrate/docs/convergence-application-theory.md
See: substrate/docs/metaframework.md
```

## blackmatter-pleme/skills/convergence/SKILL.md

Add the academic grounding connection:

```markdown
## Academic Foundations

The convergence theory is grounded in established mathematics:

- Banach contraction mapping (1922) — convergence distance strictly decreases
- Knaster-Tarski (1955) — Nix module evaluation terminates
- Lyapunov stability (1892) — convergence distance is a Lyapunov function
- CALM theorem (2020) — monotone ops = gossip, non-monotone = Raft
- Abstract interpretation (1977) — archetypes are abstract domains, renderers concretize

Full bibliography: substrate/docs/convergence-application-theory.md
```
