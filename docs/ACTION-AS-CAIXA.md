# Actions as a tatara-lisp + caixa primitive

> Mining the rest of the value: every pleme-io GH action today is
> hand-authored `action.yml` + `run.tlisp` + `README.md`. The shape
> is identical across 66 primitives. Per the prime directive
> (Pillar 12: generation over composition), this is **boilerplate
> waiting to become a typed primitive**.
>
> Target shape: a single `(defaction …)` form in tatara-lisp;
> arch-synthesizer emits the 3-file action triple mechanically.
> Same template as `(defcaixa …)` → cluster artifacts.

## The hand-authored shape (today)

```
pleme-io/actions/<name>/
├── action.yml      ~45 lines — composite shape, inputs/outputs,
│                                tatara-script invocation boilerplate
├── run.tlisp       ~80 lines — the actual logic
└── README.md       ~35 lines — template-generated from action.yml
```

Of the 45 lines in `action.yml`, ~30 are **identical** across every
action: the stdlib loader step, the `tatara-script` runner step, the
env-var passthrough. The 15 unique lines are: name / description /
inputs / outputs.

## The target shape (defaction)

```lisp
(defaction cargo-bump
  :description "Bump a single-crate Rust repo's package.version field."
  :branding   { :icon "arrow-up-circle" :color "green" }
  :inputs     { :bump-type                  { :default "patch" }
                :skip-when-no-source-changes { :default "true" }
                :source-paths                { :default "src Cargo.toml Cargo.lock" } }
  :outputs    { :bumped      { :description "true if bumped" }
                :new-version { :description "new version after bump" }
                :old-version { :description "previous version" } }
  :installs   [ :rust-toolchain :cargo-edit :nix ]
  :body
    (define bump-type
      (config-resolve "BUMP_TYPE" "bump" "default-type" "patch"))
    (define skip-flag
      (config-resolve "SKIP_WHEN_NO_SOURCE_CHANGES" "bump" "skip-when-no-source-changes" "true"))
    ;; ... rest of the cargo-bump/run.tlisp body unchanged
    ))
```

**One file. Typed. Renderable.**

## How tatara-lisp + caixa super-power this

| Tatara/caixa primitive | What it brings to action production |
|---|---|
| `#[derive(TataraDomain)]` | `Action` struct in arch-synthesizer becomes a typed Rust value; Lisp `(defaction …)` syntax is auto-registered |
| `tatara-lisp-derive` | Proc macro generates `Display`/`Serialize` for the typed Action — no `format!()` of YAML strings |
| `tatara-domain-forge` | The schema for every action input/output becomes a typed sub-form |
| `tatara-lisp-eval` | Lint-time eval catches malformed `(defaction …)` at PR time, not at GHA runtime |
| `caixa` renderer pattern | A `Renderer<Action> -> ActionTriple { yaml, tlisp, readme }` mirrors `Renderer<Caixa> -> ClusterArtifacts` |
| `arch-synthesizer` typescape | The `Action` type sits next to `Caixa` / `Promessa` / etc. in the typescape — same compounding model |

## The proposed `arch-synthesizer::Action` domain

```rust
// arch-synthesizer/src/actions/mod.rs

#[derive(TataraDomain, Serialize, Deserialize, Debug, Clone)]
#[tatara(keyword = "defaction")]
pub struct Action {
    pub name: String,
    pub description: String,
    pub branding: Branding,
    pub inputs: BTreeMap<String, InputSpec>,
    pub outputs: BTreeMap<String, OutputSpec>,
    pub installs: Vec<InstallStep>,   // pre-shipped setup recipes
    pub body: TlispBody,
}

// Display impl uses write!() — typed-emission compliant
impl Display for Action { ... }  // → action.yml
impl ActionTriple for Action { ... }  // → action.yml + run.tlisp + README.md

pub fn register() { tatara_lisp::domain::register::<Action>(); }
```

## The proposed substrate renderer

```nix
# substrate/lib/release/action-builder.nix
{ pkgs, arch-synthesizer, ... }:

let
  renderAction = lispSource:
    pkgs.runCommand "action-triple-${name}" { } ''
      ${arch-synthesizer}/bin/arch-synthesizer render-action \
        --in ${lispSource} \
        --out $out
      # $out/action.yml + $out/run.tlisp + $out/README.md
    '';
in
{ inherit renderAction; }
```

## Migration path

**M0 — pure mechanical extraction (this iteration)**
- Document the bridge (this file).
- No code changes; current hand-authored actions keep shipping.

**M1 — proof-of-concept (~1 day)**
- Add `Action` typed domain to arch-synthesizer.
- Implement renderer for one pilot action (`cargo-bump`).
- Verify byte-equivalent output to today's hand-authored files.
- Add `substrate.lib.release.renderAction` Nix function.

**M2 — fleet migration (~3 days)**
- Migrate all 66 actions to `.lisp` source form.
- Wire each action's directory to render-at-build via a substrate
  builder.
- Delete the hand-authored YAML+TLisp pairs from main; render
  output via Nix instead.
- CI verifies render outputs match expected snapshots.

**M3 — `(defaction-suite …)` (~2 days)**
- A higher-level form that declares a SUITE of related actions
  (e.g. the akeyless suite — 5 actions sharing `:installs` and
  `:auth-token-env`).
- One `.lisp` file generates 5 action triples.
- Code reuse becomes Lisp macro composition.

**M4 — caixa-aware actions (~1 week)**
- Actions can reference caixa typed values in their `:body`.
- E.g. an action declares `:expects-caixa-kind :Servico` and the
  renderer validates the action's inputs against the caixa M2/M3 slots.
- Type-safe composition between SDLC primitives + their automation.

## Why this is the right next compound

Per the prime directive: **every pattern appearing ≥2 times becomes
a macro/primitive.** The action shape appears 66 times — way past the
threshold.

Per Pillar 12 (generation over composition): hand-authored
boilerplate is the fallback; generation is the default. Today 66
hand-authored triples is exactly the kind of compounding-debt the
substrate exists to eliminate.

Per the prime directive's #1 (solve once, in one place): an action's
"shape" is currently solved 66 times. The `Action` typed domain
solves it once.

The 66 existing actions become INPUTS to the new system, not legacy
that needs preserving — they're the corpus that defines the typed
schema, and the migration loses zero behavior.

## Status

**Drafted** 2026-05-22. Implementation tracked under
`AUTO-RELEASE-CLI` + `ACTION-AS-CAIXA` milestones. M0 = this doc.
M1 = next focused session. The 66 hand-authored actions ship in
parallel until M2 cuts over.
