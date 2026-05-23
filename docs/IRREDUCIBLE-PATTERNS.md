# pleme-io · the 4 irreducible patterns

> **Thesis.** Every typed primitive in the pleme-io substrate
> — 192 actions, 14 reusable workflows, 6 ecosystem renderers,
> 5 institutional skills, ~500 repos — reduces to FOUR
> self-reinforcing patterns. Mastering these four reproduces
> the rest mechanically.
>
> Per the prime directive: the substrate compounds its ability
> by SHRINKING the set of primitives it depends on, not by
> growing it. The fewer the core patterns, the more they
> compose, the more they self-reinforce.

## The four

### 1. **TYPED DECLARATION** — every artifact starts as a typed Lisp form

```
(defaction ...)       → a GH action primitive
(defworkflow ...)     → a substrate reusable workflow
(defcaixa ...)        → a repo's adoption surface
(defpromessa ...)     → a business outcome (Viggy Method)
(defarchetype ...)    → a repo-forge template
```

**The pattern**: an operator types ONE form. The Rust type system
+ tatara-lisp validates it at parse time. No yaml-by-hand. No
markdown-by-hand. No json-by-hand.

**Self-reinforcing**: every new typed concept (Promessa, Anomalia,
Archetype, Cofre, Saguão) ADDS to the typescape without contradicting
existing primitives. The type system catches incompatibilities at
parse time, not at runtime.

### 2. **MECHANICAL RENDERING** — typed form → all downstream artifacts

```
(defcaixa my-lib ...) ──renderer──┬─→ Cargo.toml
                                  ├─→ .pleme-io-release.toml
                                  ├─→ .github/workflows/auto-release.yml
                                  ├─→ .github/workflows/pre-merge-gate.yml
                                  └─→ .github/workflows/security-gate.yml
```

**The pattern**: a typed source generates N downstream artifacts via
ONE renderer. The renderer is `Display` impls + `Serialize` derives,
not `format!()` of yaml strings. Bad combinations are compile-time
errors in the renderer, not runtime errors in the consumer.

**Self-reinforcing**: every new downstream target (a new workflow,
a new config file, a new doc format) extends the renderer ONCE,
and ALL existing typed sources gain the new output for free.

### 3. **POLYMORPHIC DISPATCH** — one typed input → N specialized handlers

```
detect-repo-type ──┬─→ rust-workspace  → rust-auto-release.yml
                   ├─→ rust-single     → cargo-auto-release.yml
                   ├─→ npm             → npm-auto-release.yml
                   ├─→ python          → python-auto-release.yml
                   ├─→ helm            → helm-auto-release.yml
                   └─→ caixa           → caixa-auto-release.yml

(defcaixa :ecosystem ...) ──┬─→ render_rust_single
                            ├─→ render_npm
                            ├─→ render_python
                            ├─→ ...
```

**The pattern**: ONE typed detection + N typed handlers. Adding a
new ecosystem doesn't touch existing handlers; consumers don't
change their 3-line shim. The dispatcher absorbs the new route
mechanically.

**Self-reinforcing**: every new handler proves the dispatcher works.
Every new repo type proves the detection works. The dispatcher's
contract is the boundary; everything inside compounds.

### 4. **PUBLICATION CASCADE** — every push fires the next layer

```
git push origin main
  ↓                                                  ⏱
auto-bump.yml fires                                  <10s
  → tag v0.X.Y
  ↓
release.yml fires on tag                             ~1-5min
  → publishes to crates.io / npm / pypi / OCI
  → cuts Docker images
  → fast-forwards @v1
  ↓
catalog regen (CI on every PR)                       ~30s
  → patterns-full.nix updated
  → per-action README regen
  → root index regen
  ↓
adoption-audit weekly cron                           weekly
  → fleet-wide status report
```

**The pattern**: every state change in the typed source propagates
through every downstream layer AUTOMATICALLY on push. No operator
intervention beyond `git push`. Free public GitHub-hosted CI handles
the rest at $0 marginal cost.

**Self-reinforcing**: every new auto-bump trigger reinforces the
"git push is the operator's only command" invariant. Every new
substrate workflow extends the cascade. Every new artifact format
plugs into the same cascade.

## How these four generate everything else

| Higher-level construct | Reduction |
|---|---|
| 192-action catalog | TYPED DECLARATION × 192 + MECHANICAL RENDERING (pleme-doc-gen patterns) |
| 14 substrate reusable workflows | TYPED DECLARATION × 14 + POLYMORPHIC DISPATCH |
| 6 example caixa ecosystems | TYPED DECLARATION × 6 + MECHANICAL RENDERING × 6 (caixa.rs emitters) |
| 192 per-action READMEs | TYPED DECLARATION (action.yml is the source) + MECHANICAL RENDERING |
| patterns-full.nix catalog | TYPED DECLARATION (each action.yml) + MECHANICAL RENDERING (Rust gen) |
| Adoption-audit weekly cron | PUBLICATION CASCADE + TYPED DECLARATION (the audit emits typed counts) |
| The pleme-io action vocabulary | TYPED DECLARATION + MECHANICAL RENDERING (skill captures the shape) |
| The org-profile invitation | PUBLICATION CASCADE (auto-bump on content change) |
| The 5-tool published stack | PUBLICATION CASCADE × 5 (actions/substrate/releaser/pleme-doc-gen/blackmatter-pleme) |
| The 6 institutional skills | TYPED DECLARATION (skill is a typed knowledge artifact) |
| The 4 CI gates (shell/tlisp/security/adoption) | POLYMORPHIC DISPATCH (per-language) + TYPED DECLARATION (gate is a typed verb) |
| ACTION-AS-CAIXA M0-M5 roadmap | MECHANICAL RENDERING progressively absorbing more layers |

**No higher-level construct adds a fifth pattern.** Every shape in
the substrate is a composition of these four. The substrate
COMPOUNDS its expressiveness, not its primitive count.

## Why this is the right number

- Fewer than 4: you lose one of the orthogonal axes. (Drop typed
  declaration → can't type-check. Drop mechanical rendering →
  hand-authoring drift returns. Drop dispatch → polymorphism dies.
  Drop cascade → manual operator work returns.)
- More than 4: composition gets brittle. New patterns can be
  derived from these four; if you find yourself naming a 5th,
  it's almost always a specialization of one of the existing four.

**The test**: any new abstraction you propose must reduce to a
composition of these four. If it doesn't, either (a) it's not
generic enough yet, or (b) one of the four needs to be refactored
— never (c) "add a fifth pattern."

## Each pattern enforces the prime directives

| Pattern | Which prime directive it enforces |
|---|---|
| TYPED DECLARATION | "Macros everywhere" — every repeated shape is a typed form |
| MECHANICAL RENDERING | "Generation over composition" (Pillar 12) — hand-authoring is the fallback |
| POLYMORPHIC DISPATCH | "Standardization" — one entry point, many concrete impls |
| PUBLICATION CASCADE | "Free public CI / $0 marginal cost" + the auto-release directive |

Each pattern also enforces NO SHELL:

- TYPED DECLARATION lives in `.lisp` source (not bash)
- MECHANICAL RENDERING is Rust + tatara-lisp (not Python)
- POLYMORPHIC DISPATCH is yaml workflow_call (not shell case statements)
- PUBLICATION CASCADE uses GH actions (not cron + scripts)

## The self-reinforcement loop

```
TYPED DECLARATION  ──validates──→  MECHANICAL RENDERING  
       ↑                                   │
       │                                   ↓
PUBLICATION CASCADE  ←──discovers──  POLYMORPHIC DISPATCH
       │                                   ↑
       │                                   │
       └───── ships ←── catalog ────────────┘
```

- Typed declarations FEED the renderer
- The renderer PRODUCES the catalog the dispatcher reads
- The dispatcher ROUTES to per-ecosystem workflows
- The workflows TRIGGER the publication cascade
- The cascade UPDATES the catalog
- The updated catalog DRIVES more typed declarations being authored

Every iteration of the loop validates every pattern. The substrate
SELF-REPAIRS — any drift in one layer is caught by a downstream
layer (catalog regen catches typed-declaration drift; CI gates
catch rendering drift; adoption-audit catches publication drift).

## What this means for new work

Before adding ANY new pleme-io abstraction, ask:

1. **Is it a TYPED DECLARATION?** (does it have a `.lisp` source form?)
2. **Does it MECHANICALLY RENDER?** (or does it require hand-authoring?)
3. **Does it POLYMORPHICALLY DISPATCH?** (or does it specialize too early?)
4. **Does it ride the PUBLICATION CASCADE?** (or does it require operator intervention?)

If any answer is "no", refactor until it's "yes". The substrate's
power comes from the LOOP, not from any individual feature.

## Status

**Locked.** These four patterns are now load-bearing across the
fleet (~500 repos, 192 actions, 14 reusable workflows, 6 example
caixas, 6+ self-publishing tools, 6+ institutional skills, 4 CI
gates).

This doc is the canonical reduction. Any new abstraction that
doesn't decompose into these four is a refactoring opportunity.
