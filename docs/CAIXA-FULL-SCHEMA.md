# caixa — the full schema (absorbing best of every package manager)

> **Thesis.** caixa unifies Cargo + Bundler + npm + uv + Helm
> into ONE typed Lisp form. Every feature any of those ecosystems
> ships, caixa expresses. The renderer emits per-ecosystem
> artifacts; the typed source is universal.
>
> Per the prime directive: ONE typed primitive covers every
> package-manager concern. Operators learn caixa once, ship to
> every registry.

## The complete schema

```lisp
(defcaixa my-thing

  ;; ── IDENTITY ──────────────────────────────────────────────────
  :kind         :Biblioteca         ;; Biblioteca | Binario | Servico | Supervisor | Aplicacao | GhAction
  :ecosystem    :rust-single-crate  ;; rust-* | npm | python | helm | github-action
  :description  "..."

  ;; ── PACKAGE METADATA ────────────────────────────────────────
  :package      { :name        "my-thing"
                  :version     "0.1.0"
                  :license     "MIT"
                  :repository  "https://github.com/pleme-io/my-thing"
                  :homepage    "https://..."
                  :authors     [ "..." ]
                  :categories  [ "..." ]      ;; crates.io categories
                  :keywords    [ "..." ] }     ;; npm/crates.io keywords

  ;; ── DEPENDENCY SURFACE (Cargo + Bundler + npm + uv unified) ──
  :dependencies { :runtime  [ { :name "serde"  :version "1"  :features [ "derive" ] }
                              { :name "tokio"  :version "1"  :features [ "rt-multi-thread" :macros ] } ]
                  :dev      [ { :name "proptest" :version "1" } ]
                  :build    [ { :name "tonic-build" :version "0.12" } ]
                  :optional [ { :name "ratatui" :version "0.27" :gates [ :tui-feature ] } ]
                  :peer     [ { :name "react"  :version ">=18" } ] }   ;; npm peerDeps

  ;; ── FEATURE FLAGS (Cargo features + npm conditional exports) ──
  :features     { :default       [ "serde-support" ]
                  :serde-support { :adds [ "serde" "serde_json" ] }
                  :async         { :adds [ "tokio" "futures" ] }
                  :tui-feature   { :adds [ "ratatui" "crossterm" ] } }

  ;; ── BUILD PROFILES (Cargo profiles + npm scripts unified) ────
  :profiles     { :release  { :opt-level 3 :lto true :strip true :codegen-units 1 }
                  :dev      { :opt-level 0 :debug true }
                  :bench    { :opt-level 3 :debug false }
                  :test     { :opt-level 1 :debug true } }

  ;; ── LIFECYCLE SCRIPTS (cargo+bundler+npm scripts unified) ────
  :scripts      { :test         "cargo test --workspace"
                  :bench        "cargo bench"
                  :fmt          "cargo fmt --check"
                  :lint         "cargo clippy -- -D warnings"
                  :pre-publish  "tar tzf target/package/*.tgz"
                  :post-install "echo installed" }

  ;; ── SOURCES (cargo patches + bundler source mirror + npm reg) ─
  :sources      { :default        "crates.io"
                  :registry-aliases { :pleme-private "https://pleme.io/registry" }
                  :git-overrides  { "shikumi" { :git "github:pleme-io/shikumi" :rev "main" }
                                    "garasu"  { :git "github:pleme-io/garasu"  :tag "v0.5.0" } }
                  :path-overrides { "local-lib" "../local-lib" } }

  ;; ── PLATFORM / ENGINE CONSTRAINTS ─────────────────────────────
  :supports     { :rust    ">=1.89.0"
                  :node    ">=20"
                  :python  ">=3.10"
                  :ruby    ">=3.2"
                  :os      [ :linux :darwin :windows ]
                  :arch    [ :x86_64 :aarch64 ] }

  ;; ── ARTIFACTS (Cargo [[bin]]/[[example]] + npm bin + lib) ────
  :artifacts    { :bin       [ { :name "my-cli"  :path "src/main.rs" }
                               { :name "my-tool" :path "src/bin/tool.rs" } ]
                  :lib       { :path "src/lib.rs"
                               :crate-types [ :lib :cdylib :rlib ] }
                  :examples  [ { :name "demo"  :path "examples/demo.rs" } ]
                  :tests     { :integration-dir "tests/" } }

  ;; ── PUBLISHING CONTROLS ───────────────────────────────────────
  :publish      { :private              false
                  :registry-token-env   "CARGO_REGISTRY_TOKEN"
                  :files-include        [ "src/**" "Cargo.toml" "README.md" "LICENSE" ]
                  :files-exclude        [ "**/*.test.*" "fixtures/" ".env*" ]
                  :verify-on-publish    true
                  :dry-run-first        false }

  ;; ── CI / LIFECYCLE INTEGRATION ────────────────────────────────
  :workflows    [ :auto-release :pre-merge-gate :security-gate ]
  :stacks       [ :ai-stack :data-stack :observability-deploy ]
  :ci-config    { :bump     { :default-type "patch" }
                  :publish  { :no-verify true } }

  ;; ── DEPENDENCY GRAPH (caixa→caixa via git-as-package-repo) ───
  :depends-on   [ "pleme-io/shikumi@v0.1.0"
                  "pleme-io/garasu@main"
                  { :repo "pleme-io/secret-lib" :ref "v1" :private true } ]
  :exposes      [ :rust-crate :docker-image :tlisp-lib ]
  :publish-to-git true)
```

## How each ecosystem renderer maps the schema

### `rust-single-crate` / `rust-workspace`

| caixa field | Cargo.toml output |
|---|---|
| `:package.*` | `[package]` table |
| `:dependencies.runtime` | `[dependencies]` |
| `:dependencies.dev` | `[dev-dependencies]` |
| `:dependencies.build` | `[build-dependencies]` |
| `:dependencies.optional` | `[dependencies]` with `optional = true` + feature gate |
| `:features` | `[features]` table |
| `:profiles` | `[profile.<name>]` tables |
| `:sources.git-overrides` | `[patch.crates-io]` |
| `:supports.rust` | `[package].rust-version` |
| `:artifacts.bin` | `[[bin]]` tables |
| `:artifacts.lib` | `[lib]` + `crate-type = [...]` |
| `:artifacts.examples` | `[[example]]` |
| `:publish.files-include` | `[package].include` |
| `:publish.private` | `[package].publish = false` |

### `npm`

| caixa field | package.json output |
|---|---|
| `:package.*` | top-level fields |
| `:dependencies.runtime` | `dependencies` |
| `:dependencies.dev` | `devDependencies` |
| `:dependencies.optional` | `optionalDependencies` |
| `:dependencies.peer` | `peerDependencies` |
| `:supports.node` | `engines.node` |
| `:scripts.*` | `scripts` |
| `:artifacts.bin` | `bin` |
| `:publish.files-include` | `files` |
| `:publish.private` | `private: true` |

### `python` (pyproject.toml via uv/hatchling)

| caixa field | pyproject.toml output |
|---|---|
| `:package.*` | `[project]` |
| `:dependencies.runtime` | `[project].dependencies` |
| `:dependencies.dev` | `[project.optional-dependencies].dev` |
| `:dependencies.optional` | `[project.optional-dependencies]` per-feature |
| `:supports.python` | `[project].requires-python` |
| `:scripts.*` | `[project.scripts]` |

### `helm`

| caixa field | Chart.yaml + values.yaml output |
|---|---|
| `:package.*` | `Chart.yaml` fields |
| `:dependencies.runtime` | `Chart.yaml.dependencies` |
| `:supports.os/arch` | `values.yaml.nodeSelector` |
| `:artifacts.bin` | n/a (chart-level concept) |

### `github-action`

| caixa field | action.yml + run.tlisp output |
|---|---|
| `:package.description` | `description:` |
| `:action.inputs` | `inputs:` |
| `:action.outputs` | `outputs:` |
| `:action.installs` | composite `steps:` install layer |
| `:action.body` | `run.tlisp` content |

## Renderer status

| Field | Implemented in M3? | Notes |
|---|---|---|
| `:package` | ✅ all ecosystems | Core metadata round-trips |
| `:ci-config` | ✅ all ecosystems | `.pleme-io-release.toml` emitted |
| `:workflows` | ✅ all ecosystems | 3 yaml shims emitted |
| `:stacks` | ✅ all ecosystems | pleme-stacks.yml emitted |
| `:depends-on` | ✅ schema parsed | caixa-deps-resolve runtime |
| `:exposes` | ✅ schema parsed | catalog-listing future |
| `:publish-to-git` | ✅ schema parsed | caixa-publish-to-git runtime |
| `:dependencies.*` | ⏳ M3.1 | Each ecosystem emits its dep-graph |
| `:features` | ⏳ M3.1 | Cargo `[features]` + npm conditional |
| `:profiles` | ⏳ M3.2 | Cargo profile tables |
| `:scripts` | ⏳ M3.2 | npm `scripts` / Cargo aliases |
| `:sources` | ⏳ M3.3 | Cargo patches + npm registry config |
| `:supports` | ⏳ M3.3 | engine version + os/arch constraints |
| `:artifacts` | ⏳ M3.4 | `[[bin]]` / `[[example]]` / `[lib]` |
| `:publish.*` | ⏳ M3.4 | files-include / private / verify |

Each ⏳ row is a single PR against pleme-doc-gen's caixa.rs.
The schema is locked NOW; the per-ecosystem emitters land
incrementally per consumer demand.

## What this absorbs

| Source | Concepts unified |
|---|---|
| **Cargo** | features / profiles / patches / bin/lib/example targets / dev-deps / build-deps / publish.include |
| **Bundler** | groups / source overrides / platform-specific gems / gemspec runtime+dev separation |
| **npm** | peerDeps / optionalDeps / scripts lifecycle / engines / files allowlist / private / workspaces / overrides |
| **uv/Poetry** | optional-dependencies extras / requires-python / dev groups / lockfile reproducibility |
| **Helm** | Chart.yaml fields / values.yaml structure / chart dependencies |
| **Action** | inputs/outputs typed schema / installs / body |
| **caixa (existing)** | kind / ecosystem / depends-on / exposes / workflows / stacks / publish-to-git |

**ONE typed form. Every package-manager feature. Mechanical
rendering to every ecosystem.**

## Operator promise

"Learn caixa once. Ship to crates.io, npmjs, pypi, OCI registries,
GH releases, AND the git-as-package-repo. Never hand-author a
Cargo.toml or package.json or pyproject.toml or Chart.yaml again."

That's the prime directive's "macros everywhere" + "generation
over composition" at the package-manager layer.
