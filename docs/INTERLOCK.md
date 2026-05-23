# The substrate ↔ actions interlock

> **Thesis.** The hand-authored boundary between
> `pleme-io/substrate` (Nix patterns + reusable workflows) and
> `pleme-io/actions` (composite GH primitives) is the LAST major
> piece of compounding-debt in the fleet. After ACTION-AS-CAIXA
> M1-M4 lands, both sides become MECHANICAL RENDERINGS of one
> typed tatara-lisp source. The interlock collapses to a single
> declaration; the rest is generated.
>
> Per Pillar 12 (generation over composition): the 136-primitive
> catalog + 14 reusable workflows + 9 yaml shims-per-repo are all
> downstream products of one set of typed Lisp forms. The current
> hand-authoring is fallback while the renderer ships.

## The current boundary (today)

```
pleme-io/actions          pleme-io/substrate
─────────────────         ──────────────────
136 × action.yml          14 × .github/workflows/*.yml (reusable)
136 × run.tlisp           1  × lib/release/patterns.nix (catalog)
136 × README.md           1  × lib/release/catalog.nix
_tlisp-stdlib/            1  × lib/release/example-config.toml
                          1  × lib/release/example-defaction.lisp
                          1  × docs/ACTION-AS-CAIXA.md
                          1  × docs/INTERLOCK.md (this file)

Cross-repo references (currently STRINGS, not types):
  patterns.nix.bump.cargo-bump.uses = "pleme-io/actions/cargo-bump@main"
  workflow.yml uses: pleme-io/actions/<name>@main
```

The boundary is **enforced by convention**: when you add an
action, you also add a `patterns.nix` entry + (if it's part of a
pipeline) wire it into a substrate workflow + update the skill +
the consumer shim format. **4 places to touch for every new
action.** Today: ~136 primitives × 4 touches = 544 touch-points
manually kept in sync.

## The unified target (tomorrow)

```
pleme-io/<single-canonical-home>/
├── actions/
│   ├── cargo-bump.lisp             ← ONE FILE per action
│   ├── npm-bump.lisp
│   ├── ... (136 typed .lisp source files)
│   └── _stdlib.lisp                ← shared helpers
├── workflows/
│   ├── auto-release.lisp           ← ONE FILE per reusable workflow
│   ├── pre-merge-gate.lisp
│   ├── security-gate.lisp
│   ├── container-stack.lisp
│   ├── cd-stack.lisp
│   └── release-pipeline.lisp
└── caixas/
    ├── pleme-io-base.lisp          ← the canonical operator-facing shim
    └── ...

Renderer (arch-synthesizer):
  cargo-bump.lisp     → pleme-io/actions/cargo-bump/{action.yml,run.tlisp,README.md}
  auto-release.lisp   → pleme-io/substrate/.github/workflows/auto-release.yml
                       + patterns.nix entry
                       + skill table row
                       + example-config.toml schema
                       + README catalog entry
  pleme-io-base.lisp  → consumer-repo .github/workflows/{pre-merge,security,auto-release}.yml
```

**One source. Every downstream artifact rendered.** Touching the
typed Lisp form propagates to all 5-6 surfaces mechanically.

## The three typed forms

### 1. `(defaction ...)` — the atomic primitive

```lisp
(defaction cargo-bump
  :category    :bump
  :ecosystem   :rust-single-crate
  :description "Bump a single-crate Rust repo's package.version field."
  :branding    { :icon "arrow-up-circle" :color "green" }
  :inputs      { :bump-type                   { :default "patch" }
                 :skip-when-no-source-changes { :default "true" }
                 :source-paths                { :default "src Cargo.toml Cargo.lock" } }
  :outputs     { :bumped      { :type :bool }
                 :new-version { :type :string }
                 :old-version { :type :string } }
  :installs    [ :rust-toolchain :cargo-edit :nix ]
  :wraps       "cargo set-version --bump <bump-type>"
  :body        (... typed tlisp body using config-resolve / exec-capture ...))
```

Renders to:
- `cargo-bump/action.yml` (5 canonical sections, deterministic)
- `cargo-bump/run.tlisp` (loader-prepended body)
- `cargo-bump/README.md` (template-generated)
- `patterns.nix.bump.cargo-bump = { uses = ...; ecosystem = ...; ... }` (typed mirror)
- Skill table entry (auto-generated)
- `example-config.toml.[bump]` field (from :inputs)

### 2. `(defworkflow ...)` — typed composition

```lisp
(defworkflow auto-release
  :description "Polymorphic dispatcher — push to main → per-language bump+publish."
  :triggers    [ (:push :branches [ "main" ])
                 (:workflow-dispatch
                   :inputs { :bump-type { :default "patch" } }) ]
  :permissions { :contents :write
                 :packages :write }
  :secrets     [ :CRATES_API_TOKEN :NPM_TOKEN :PYPI_API_TOKEN :BOT_PAT ]
  :jobs
    [ (:job detect
        :uses-action :detect-repo-type
        :outputs     [ :repo-type ])
      (:job rust-workspace
        :needs detect
        :when (= (output detect :repo-type) "rust-workspace")
        :uses-workflow :rust-auto-release
        :with { :bump-type (input :bump-type) })
      (:job rust-single-crate
        :needs detect
        :when (= (output detect :repo-type) "rust-single-crate")
        :uses-workflow :cargo-auto-release)
      (:job npm
        :needs detect
        :when (= (output detect :repo-type) "npm")
        :uses-workflow :npm-auto-release)
      ;; ... etc per ecosystem
      ])
```

Renders to:
- `auto-release.yml` (substrate reusable, full GH workflow yaml)
- `patterns.nix.workflows.auto-release = { ... }` (typed mirror)
- Skill section linking to component primitives + their actions

**Crucially**: every `:uses-action` and `:uses-workflow` ref is
TYPED. The renderer validates that `:detect-repo-type` exists in
the action catalog at build time. Refactoring is mechanical: rename
the action's `(defaction name ...)`, and every workflow's
`:uses-action :old-name` becomes a compile-time error pointing at
every dependent.

### 3. `(defcaixa ...)` — the operator-facing shim

```lisp
(defcaixa my-rust-crate
  :kind   :Biblioteca
  :name   "my-rust-crate"
  :version "0.1.0"
  :description "An example caixa shipping a Rust library to crates.io."
  :ecosystem :rust-single-crate
  :ci      [ :pleme-io-base ]   ;; reference a typed CI suite
  ;; renderer emits .github/workflows/auto-release.yml + pre-merge-gate.yml + security-gate.yml
  ;; auto-detect: :ecosystem implies which substrate workflow gets wired
  ;; auto-emit: .pleme-io-release.toml with sensible defaults
  )
```

Renders to:
- `.github/workflows/auto-release.yml` (3-line consumer shim)
- `.github/workflows/pre-merge-gate.yml`
- `.github/workflows/security-gate.yml`
- `.pleme-io-release.toml`
- (optional) The actual `Cargo.toml` + `src/lib.rs` scaffold for a fresh caixa

## The compounding payoff

| Today (hand-authored)         | After M2 ((defaction) renders)  | After M3 ((defcaixa) composes)  |
|-------------------------------|----------------------------------|---------------------------------|
| 4 touch-points per action    | 1 .lisp file (renderer covers 4) | 0 (workflow comes via caixa)    |
| 9 yaml lines per adopting repo | 9 (unchanged)                    | 1 .lisp file (renderer covers 9)|
| 14 substrate reusable yaml   | 14 .lisp files                   | (composed via caixa)            |
| 136 actions × ~150 lines each = ~20,400 lines hand-authored | 136 × ~25 lines = ~3,400 lines | source ≈ consumer count        |
| New primitive: ~150 lines yaml+tlisp+readme + 6 lines patterns.nix + skill table edit | One `(defaction ...)` form | (auto-available to every caixa) |
| Adding a new ecosystem (e.g. dart-pub-publish): hand-author bump + publish + workflow + dispatcher route + skill entry + patterns.nix entry + skill table = ~600 lines + 4 file edits | One `(defaction-suite ...)` form ≈ 50 lines | (zero-touch for consumers)    |

**Adding a new ecosystem after M3 = a single Lisp form. The
renderer handles everything else.**

## How tatara-lisp + caixa MAKE this possible

The pleme-io substrate already ships:

- **`#[derive(TataraDomain)]`** on the Rust side: register a typed
  domain so its Lisp keyword is auto-wired. Adding `Action`,
  `Workflow`, `Caixa` as domains = ~50 lines each in
  arch-synthesizer.

- **`tatara-lisp-derive`** proc macros: generate `Display` /
  `Serialize` for the typed structs. Renderer outputs yaml without
  ever touching `format!()`.

- **`tatara-lisp-eval`**: lint-time eval catches malformed
  `(defaction)` BEFORE PR merge. The current paren-balance check
  becomes a full type-check.

- **`tatara-domain-forge`**: schema for every input/output becomes
  a typed sub-form. `:inputs { :bump-type { :default "patch" } }`
  is itself typed.

- **`(defcaixa ...)`**: the existing SDLC primitive becomes the
  CONSUMER FACE — a repo declares ONE caixa form and gets the full
  CI surface for free.

The renderer pattern was PROVEN with `caixa` itself
(`feira render` emits cluster artifacts mechanically). Action +
workflow rendering is the same pattern at the CI layer.

## The interlock unlocks compounding nobody else has

Every other Action library on GitHub is hand-authored. Every
other reusable-workflow library is hand-authored. Every other
"opinionated CI stack" is a copy-paste template.

Per the prime directive, pleme-io's `(defaction)` + `(defworkflow)`
+ `(defcaixa)` triad is the FIRST CI library that's typed all the
way down. New behaviors compound across the typescape:

- **Discoverability**: every action / workflow / caixa is queryable
  from `substrate.lib.release.patterns` (already true today; M2
  makes the catalog the SOURCE not the mirror).

- **Refactorability**: renaming an action propagates across every
  workflow + every caixa that uses it (compile-time).

- **Composability**: a caixa can declare `:also-uses [ :slack-notify
  :coverage-upload ]` and the renderer wires them in automatically.

- **Verifiability**: the renderer's output is deterministic, so PRs
  can run `defaction-render --check` to verify the rendered yaml
  matches the typed source.

- **Extensibility**: adding a new typed concept (like `(defpromessa
  ...)` for The Viggy Method) gets a free CI surface by composing
  with the existing actions.

## Migration roadmap (concretized)

**M0 — drafts (this iteration)**: `ACTION-AS-CAIXA.md` +
`example-defaction.lisp` + this `INTERLOCK.md`. The vision is
documented; nothing executes yet.

**M1 — single-action POC (1 session)**:
- Add `Action` domain to `arch-synthesizer/src/actions/mod.rs`
- Hand-port `cargo-bump.lisp`
- Implement `arch-synthesizer render-action --in X.lisp --out dir/`
- Verify byte-equivalent output to today's hand-authored
  `pleme-io/actions/cargo-bump/{action.yml,run.tlisp,README.md}`
- Snapshot test in CI

**M2 — fleet migration (3 sessions)**:
- Migrate all 136 actions to `.lisp` source
- Wire `substrate.renderActions` Nix function that builds the
  triples at flake evaluation time
- Delete the hand-authored YAML+TLisp pairs from `pleme-io/actions`
  main branch; render via Nix instead
- CI snapshot-tests verify renderer output

**M3 — workflows ((defworkflow ...))** (2 sessions):
- Add `Workflow` domain
- Hand-port the 14 substrate reusables to `.lisp` source
- Renderer emits the yaml workflow files
- Update patterns.nix to consume the typed Workflow values

**M4 — caixa-aware actions + (defcaixa) extensions** (1 week):
- `(defaction)` gains `:expects-caixa-kind` slot for type-safe
  composition with `Servico` / `Aplicacao` / `Biblioteca`
- `(defcaixa)` gains `:ci` slot that auto-emits the 3 consumer
  shims via the workflow renderer
- New typed concepts (Promessa, Anomalia, etc.) get free CI by
  composing with existing actions

**M5 — full source-of-truth migration**:
- The Lisp source moves to a single canonical home (likely
  `pleme-io/typescape` — peer of `arch-synthesizer`)
- `pleme-io/actions` + `pleme-io/substrate` become RENDERED
  outputs published by CI from the typed source
- Operators NEVER edit yaml or tlisp files directly; only `.lisp`
  source.

## What ships in THIS iteration (M0 expansion)

This document. Plus:
- The `(defworkflow ...)` form spec added to
  `example-defaction.lisp` (next to the existing
  `(defaction-suite ...)` example).
- Updated skills citing this interlock as the next big move.

The vision is now CONCRETE and queryable. Future sessions can
pick up M1 with zero re-discovery.
