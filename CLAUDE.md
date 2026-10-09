# Substrate

`pending-repro: i18n-embed-fl fl! HashMap order` — i18n-embed-fl 0.9.4's `fl!`
emits macro args in HashMap order (src/lib.rs:69/86, emitted at :553), so every
build of `age` 0.11.5 gets a different SVH (`nix build --rebuild`: may not be
deterministic). `propagated-rlib-deps` stops GC from splitting a consumer from
the rlib it was compiled against; the cause closes with a patched
i18n-embed-fl that sorts the keys, carried until upstream does.

`pending-vacuous-guard: infra/wasm-compat` — `lib/infra/tests/wasm-compat-test.nix`
is the one eval suite deliberately left OUT of CI (2026-07-28), while the other 22
were wired. Not red, not broken: a tautology. Its 13 assertions compare
`wasmCompat.<crate>` against the literal written into `wasmCompat` in the same
file, so the suite reads nothing outside itself and cannot fail when a crate's
real wasm32 compatibility changes. Wiring it would add 13 units of coverage that
verify nothing, indistinguishable in a CI log from the 830 that work. The file's
own header states what would make it real (derive the matrix from each crate's
Cargo.toml/flake, or make it a per-crate `checks.<system>.*` build).

> **★★ `.github/workflows/` here is the FLEET's orchestration home — 90
> `workflow_call` reusables of 98 files, called by 758 of the 784
> workflow-bearing pleme-io repos (2026-08-19).** Eleven are the general
> `pleme-*` family, each a dispatcher taking one `target:`; `pleme-stack` is the
> single-file umbrella. Before authoring a flow, check whether the shape is an
> **input** to one that exists — and a new flow ships its `<flow>.cases.tsv` job
> selection table or its job selection drifts unobserved. A flow holds no logic
> of its own: every step is a `uses:` into `pleme-io/actions`. The ladder and the
> homes: [`theory/PIPELINE-DELIVERY.md`](https://github.com/pleme-io/theory/blob/main/PIPELINE-DELIVERY.md).

> **★★★ CSE / Knowable Construction.** Substrate is the *primary
> rendering layer* of Constructive Substrate Engineering — the typed
> primitives here (rust-tool-release-flake, module-trio, helm builders,
> etc.) are how typed source becomes concrete artifact across every
> environment. Per the Compounding Directive's renderer-reliability
> requirements, every helper here ships with named contracts +
> property-based tests + round-trip + differential + snapshot tests.
> Canonical methodology spec:
> [`pleme-io/theory/CONSTRUCTIVE-SUBSTRATE-ENGINEERING.md`](https://github.com/pleme-io/theory/blob/main/CONSTRUCTIVE-SUBSTRATE-ENGINEERING.md).
> Operational directive: org-level pleme-io/CLAUDE.md ★★★ section.

<!-- Blackmatter alignment: pillars 8, 9 -->
<!-- See ~/code/github/pleme-io/BLACKMATTER.md for pillar definitions. -->

## Blackmatter pillars upheld

- **Pillar 8** (Image building): `substrate/lib/oci-image-*.nix` patterns are THE way every pleme-io container image is built. No Dockerfiles. Hardened minimal roots.
- **Pillar 9** (SDLC): `rust-tool-release-flake.nix`, `rust-workspace-release-flake.nix`, `rust-service-flake.nix`, `rust-library.nix`, `ruby-gem-flake.nix`, `wasi-service-flake.nix`, `wasi-service-flux-flake.nix`, `tatara/program-flake.nix`, `build/rust/ios-game-flake.nix` (the iOS-game SDLC devloop — a **100%-local** chain: cross-compile Rust → iOS, the local `check` gate (lint/test/build-sim) + `watch` TDD loop, then deploy to the simulator "VM" or a tethered phone via the Xcode impurity boundary; emits the guided `nix run .#{sdlc,watch,check,test,lint,build-sim,run-sim,build-device,game-device,game}` app distribution; reference consumer `pleme-io/asobi`. There is NO remote CI in the iOS delivery path — a GitHub runner can't reach a local VM/phone; the optional `ios-game-ci.yml` only mirrors the local `check` gate for teams with macOS Actions budget) — every repo's `flake.nix` anchors on one of these. `nix run .#app` / `nix run .#test` / `nix run .#release` uniformity comes from here.

> **★ Standing rule for every claim in this file: state the denominator.**
> Four coverage claims in this file were found wrong on the same day and
> had rotted the same way (this section, `cse-lint` below, `checks.tests`,
> and `cargo-ci.yml`). A *named* fact — a path, a flag, a workflow name —
> gets corrected eventually, because sooner or later someone reads the file
> it names. A *coverage* claim — "every repo", "on every commit", "always"
> — rots silently, because nobody counts the denominator. So wherever this
> file states a reach, it states what that reach is **out of**, and when it
> was counted.
>
> Two measurement traps produced wrong numbers inside the audit that found
> these, so re-measure rather than inherit. (1) `rg` / `grep -r` from the
> fleet root returns **zero** for nested repos —
> `~/code/github/pleme-io/.gitignore` is `*`, un-ignoring only `flake.nix`
> and `flake.lock`; use `rg --no-ignore` or `find … -exec grep`. (2) A naive
> grep counts **prose about a thing as an instance of the thing**: grepping
> `buildMode = "cargo-nix"` hits a comment stating that zero consumers set
> it, and grepping `cargo-ci.yml` hits four repos documenting why they
> deliberately do not use it. Match uncommented lines, then read the hits.

## Where the rest lives — read the one you need

This file is the index and the short hard rules. Claude Code does not load a
`CLAUDE.md` over 40,000 characters, so the long material lives in `docs/`, and
the `claude-md-size` flake check fails the build before this file can pass that
limit again.

| Read when you are… | Document |
|---|---|
| verifying a builder: `nix flake check` builds only `checks.<system>.*`, so a builder emitting none hands out a green lie | [`docs/doctrine/flake-check-builds-only-checks.md`](./docs/doctrine/flake-check-builds-only-checks.md) |
| shipping anything generated (`Cargo.nix`, specs, locks): a generated artifact must be tied to its source | [`docs/doctrine/generated-artifact-tie.md`](./docs/doctrine/generated-artifact-tie.md) |
| writing an eval suite: `runTests` reports and does not throw, hence the suite catalog | [`docs/doctrine/runtests-reports.md`](./docs/doctrine/runtests-reports.md) |
| touching `kata.mkFleet`: it ships the invoker, not just the check | [`docs/doctrine/mkfleet-invoker.md`](./docs/doctrine/mkfleet-invoker.md) |
| retiring a hand-run mutating verb (`mutatingVerbs`) | [`docs/doctrine/mutating-verbs.md`](./docs/doctrine/mutating-verbs.md) |
| writing or calling a reusable workflow (caixa, ansible-collection, per-channel publish), including why a job output is not a workflow output | [`docs/ci/reusable-workflows.md`](./docs/ci/reusable-workflows.md) |
| finding where a module lives in `lib/` | [`docs/module-hierarchy.md`](./docs/module-hierarchy.md) |
| looking up what `lib/default.nix` exports | [`docs/exports.md`](./docs/exports.md) |
| refactoring, extracting a helper, or adding a build behaviour: the neutrality protocol, the gates, what to reuse | [`docs/evolving-substrate.md`](./docs/evolving-substrate.md) |
| choosing which files a build reads (`prose = "included" \| "excluded"`) | [`lib/build/source-policy.nix`](./lib/build/source-policy.nix) |

## Import Patterns

### Pattern 1: Via `substrate.lib.${system}` (recommended for most consumers)

```nix
# In your flake.nix outputs:
substrateLib = substrate.lib.${system};
packages.default = substrateLib.mkCrate2nixProject { ... };
```

### Pattern 2: Via `substrate.libFor` (when you need to pass forge)

```nix
substrateLib = substrate.libFor {
  inherit pkgs system;
  forge = inputs.forge.packages.${system}.forge;
};
apps = substrateLib.mkCrate2nixServiceApps { ... };
```

### Pattern 3: Standalone flake builders (zero-boilerplate)

```nix
# Rust tool (CLI with GitHub releases):
outputs = (import "${substrate}/lib/build/rust/tool-release-flake.nix" {
  inherit nixpkgs crate2nix flake-utils;
}) { toolName = "kindling"; src = self; repo = "pleme-io/kindling"; };

# Rust tool image (CLI packaged as Docker image for K8s CronJobs/init containers):
outputs = (import "${substrate}/lib/build/rust/tool-image-flake.nix" {
  inherit nixpkgs crate2nix flake-utils;
}) {
  toolName = "image-sync";
  src = self;
  repo = "pleme-io/image-sync";
  tag = "0.1.0";
  extraContents = pkgs: [ pkgs.crane ];  # runtime tools in Docker image
  architectures = ["amd64"];
};

# Ruby gem:
outputs = (import "${substrate}/lib/build/ruby/gem-flake.nix" {
  inherit nixpkgs ruby-nix flake-utils substrate forge;
}) { inherit self; name = "pangea-core"; };

# Pangea infra:
outputs = (import "${substrate}/lib/infra/pangea-infra-flake.nix" {
  inherit nixpkgs ruby-nix flake-utils substrate forge;
}) { inherit self; name = "my-infra"; };
```

### Pattern 4: Standalone home-manager helpers (no pkgs needed)

```nix
hmHelpers = import "${substrate}/lib/hm/service-helpers.nix" { lib = nixpkgs.lib; };
skillHelpers = import "${substrate}/lib/hm/skill-helpers.nix" { lib = nixpkgs.lib; };
mcpHelpers = import "${substrate}/lib/hm/mcp-helpers.nix" { lib = nixpkgs.lib; };
testHelpers = import "${substrate}/lib/util/test-helpers.nix" { lib = nixpkgs.lib; };
```

### Pattern 5: Overlay application

```nix
pkgs = import nixpkgs {
  inherit system;
  overlays = [
    (substrateLib.mkRustOverlay { inherit fenix system; })
    (substrateLib.mkGoOverlay {})
    (substrateLib.mkZigOverlay {})
    (substrateLib.mkSwiftOverlay {})
  ];
};
```

### Pattern 6: Devenv modules

```nix
devenv.lib.mkShell {
  modules = [ (import substrateLib.devenvModulePaths.rust-service) ];
};
```

---

## Cross-Reference Rules (Import DAG)

Modules follow a strict dependency DAG. Violations cause circular imports.

```
types/ ----> (none)     (standalone: only needs nixpkgs.lib — DAG leaf)
build/ ----> util/       (OK: builders use config, darwin, docker helpers)
build/ ----> types/      (OK: builders validate through types)
service/ --> build/      (OK: service patterns compose build outputs)
service/ --> util/       (OK: service patterns use config, release helpers)
service/ --> types/      (OK: service patterns use type contracts)
infra/ ----> util/       (OK: infra uses config)
infra/ ----> types/      (OK: infra specs become typed)
codegen/ --> util/       (OK: codegen uses source registry)
hm/ -------> (none)     (standalone: only needs nixpkgs.lib)
devenv/ ---> (none)     (standalone: devenv module format)

util/ -----> build/     (PROHIBITED: would create cycles)
util/ -----> service/   (PROHIBITED)
util/ -----> infra/     (PROHIBITED)
util/ -----> types/     (PROHIBITED: types is a pure leaf)
build/ ----> service/   (PROHIBITED)
build/ ----> infra/     (PROHIBITED)
types/ ----> build/     (PROHIBITED: types must remain pure)
types/ ----> util/      (PROHIBITED: types must remain pure)
```

Within `build/`, language directories are independent of each other.
Cross-language imports (e.g., `rust/` importing from `go/`) are prohibited.

### Convergence Layer Mapping

Every substrate module maps to a convergence theory layer:

| Layer | Substrate | Implementation |
|-------|-----------|----------------|
| **Declare** | Type-checked specs | `lib/types/*.nix` — submodule options |
| **Resolve** | Module evaluation | `lib.evalModules` in `types/validate.nix` |
| **Converge** | Builder transforms | `lib/build/*/*.nix` — derivation construction |
| **Checkpoint** | Build outputs | `packages.*`, store paths, Docker images |
| **Verify** | Invariant proofs | `lib/types/tests.nix`, `lib/kube/tests.nix` |
| **Cache** | Content-addressed | Nix store (automatic) |
| **Compose** | Lattice join | `imports = [a b]`, overlays, `//` merge |

---

## Adding a New Builder

See [docs/adding-a-builder.md](docs/adding-a-builder.md) for the full checklist.

Summary:
1. Create `lib/build/{lang}/{pattern}.nix`
2. Export from `lib/default.nix`
3. Create backward-compat shim at `lib/{lang}-{pattern}.nix` if replacing an old path
4. Update docs

---

## Backward Compatibility

All old flat paths (`lib/rust-overlay.nix`, `lib/go-tool.nix`, etc.) are preserved
as one-line shims that forward to the new location:

```nix
# Shim -- moved to build/rust/overlay.nix
import ./build/rust/overlay.nix
```

**Rules:**
- Never remove a shim. External consumers depend on the old paths.
- New code should use the new paths (`lib/build/rust/overlay.nix`).
- When moving a file, always create a shim at the old location.
- The shim format is exactly two lines: comment + import.

## Evolving substrate — every change is neutral or opt-in

- **A refactor proves itself derivation-neutral.** Baseline every check's
  `drvPath` on both systems before editing, and require them unchanged after.
  Also evaluate real consumers with `--override-input substrate` at `main` and
  at your worktree. If a consumer never reaches the code you touched, its
  identity proves nothing; compare the enclosing string directly instead.
- **A new behaviour is a typed parameter whose default is today's behaviour.**
  The consumer that needs it is one permutation of that parameter. Use an enum
  checked with `lib.assertOneOf`, and test that the default is the identity.
- **A new flake check lands together with its CI step**, and the workflow's
  `paths:` must cover every file the check reads. `checks-wired` fails the build
  otherwise.

- **Output only what someone must act on.** A `builtins.trace` or `lib.warn`
  names an action the reader has to take (commit a lock, fix a `go.mod`). A
  fact the caller already declared, or progress chatter, is silent by default
  and reachable through a typed flag (`traceGoDirectiveNormalization`). Every
  rebuild prints every trace, so an informational one trains people to skim
  past the warnings that matter.

Protocol, traps, reusable helpers and backlog:
[`docs/evolving-substrate.md`](./docs/evolving-substrate.md).

---

## Shikumi Pattern (Nix->YAML->App)

All configuration flows through Nix evaluation, never through shell scripts:

```
Nix option -> Nix module evaluates -> YAML/JSON file deployed -> App reads config
```

- No shell business logic between Nix and applications
- Config files are declarative artifacts, not runtime-generated
- Hot-reload via shikumi's `ConfigStore` + `ArcSwap` in Rust apps
- Config discovery: `~/.config/{app}/{app}.yaml`

**The Nix side of a shikumi config is GENERATED, not restated.** The Rust
struct derives `schemars::JsonSchema`; commit `schema_for!(Config)` as JSON
next to the module, and surface it with
`(import "${substrate}/lib/types" { inherit lib; }).jsonSchema`:
`optionsFromJsonSchema { inherit lib; schema = ./config.schema.json; }` (an
options set for an object root) or `fromJsonSchema { … }` (the root's type,
e.g. a tagged enum). Render with `jsonSchema.pruneNulls` so unset optional
fields stay missing, which serde reads as their default. Objects are closed,
serde enums become `attrTag` / `enum`, recursive `$ref`s are safe, and an
unmapped keyword throws naming its JSON pointer instead of widening to
`anything`. Mapping, refusals, nixpkgs notes: `lib/types/json-schema.nix`;
proof: `checks.<system>.json-schema-types` (real schemars 1.2.2 fixtures).

Infrastructure follows the same pattern via Pangea:

```
Nix option -> pangea-workspace.nix -> YAML workspace config -> Pangea Ruby DSL
```

Fleet flows always regenerate `fleet.yaml` before execution — the YAML file
is a build artifact, never hand-edited or cached between runs.

---

## Conventions

### Rust

- Edition 2024, Rust 1.89.0+, MIT license
- `[lints.clippy] pedantic = "warn"` in every Cargo.toml
- Release profile: `codegen-units = 1`, `lto = true`, `opt-level = "z"`, `strip = true`
- All repos are PUBLIC on GitHub
- Prefer crates.io deps; git deps fallback: `{ git = "https://github.com/pleme-io/{crate}" }`

### Nix

- Always follow nixpkgs through: `inputs.substrate.inputs.nixpkgs.follows = "nixpkgs"`
- Supported systems: `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, `aarch64-darwin`
- Use `mkShellNoCC` for dev shells (not `mkShell`)
- flake-parts for monorepos, plain flake outputs for single-product repos

### Security

See [docs/security.md](docs/security.md) for full requirements.

- Least-privilege IAM: explicit allow-list, no wildcards
- KMS encryption on all storage (S3, DynamoDB)
- `prevent_destroy` on all stateful resources
- Secrets never in Nix store or Terraform state -- use dynamic producers
- Required tags: `ManagedBy`, `Purpose`, `Environment`, `Team`

### Testing

See [docs/testing.md](docs/testing.md) for the three-layer test pyramid.

- Layer 1: RSpec resource function unit tests
- Layer 2: RSpec architecture synthesis tests (zero cloud cost)
- Layer 3: InSpec live verification (post-apply)
- Gated workspaces: tests must pass before plan/apply

---

## File Naming Conventions

- Builders: `mk{Thing}` (e.g., `mkCrate2nixProject`, `mkGoTool`)
- Flake wrappers: `*-flake.nix` (e.g., `service-flake.nix`, `gem-flake.nix`)
- Overlays: `overlay.nix` within each language directory
- Helpers: `*-helpers.nix` (e.g., `service-helpers.nix`, `docker-helpers.nix`)
- Standalone import paths: exposed as `*Builder` attrs (e.g., `rustLibraryBuilder`)

---

## ★★ No rev-pinned `url = "github:pleme-io/X/REV"` URLs in fleet flakes

**The core substrate principle that makes fleet-wide fixes propagate.**

Hard-coding a rev in a flake input URL — e.g.
`url = "github:pleme-io/blackmatter-kubernetes/26f6014"` — freezes that
input at that exact rev. `nix flake update <input>` then has NO effect
(the URL itself contains the pin, so the lock can't move). Substrate-grade
fixes — `nix-prefetch-git` added to mk-build-spec.nix, workspace-member
dedup, sha256 freshness gate — that ship to substrate's main are
INVISIBLE to consumers behind rev-pinned URLs. The fleet ends up with
27+ distinct substrate revs in nix's lock graph and 300+ stale chains
no `nix flake update` can heal.

**The doctrine:**

1. **Do NOT use `github:org/repo/REV` URLs for INTERNAL pleme-io inputs.**
   Use `github:pleme-io/<repo>` (track main) and rely on `nix flake update`
   to bump. Pinning is the job of flake.lock, not the URL.

2. **DO use `inputs.<x>.follows = "<x>"` at the aggregator level** so
   every consumer transitively flows through the same `<x>`. This
   collapses N parallel `<x>` nodes in the graph to one — a single
   bump propagates fleet-wide.

3. **Exception**: external (non-pleme-io) inputs may rev-pin when
   needed for reproducibility. The principle is internal-only.

**Detection**: `gen flake-lint --check-substrate-chain` walks
`nix/flake.lock` and reports every consumer whose substrate (or other
typed input) is at a non-target rev, plus the leaf flake.nix files
that need editing.

**Auto-fix**: per-flake script that drops the `/REV` suffix from
matching URLs, then runs `nix flake update`. Applied today across
helmworks, lilitu, pangea-operator, openclaw-web, kindling-profiles
to land the substrate IFD-tools fix fleet-wide.

---

## ★★ IFD Sandbox Contract — `lib/build/rust/mk-build-spec.nix`

Substrate's gen-IFD path runs `gen build` inside a nix sandbox to
regenerate `Cargo.build-spec.json` on demand. The sandbox provides a
**closed list of tools on PATH** + `__noChroot = true` for network
access. Every tool gen-cargo shells out to MUST be added to this
sandbox's `nativeBuildInputs` or every consumer with a corresponding
dep class fails the spec build.

Today's tool list (`mk-build-spec.nix` L54+):

| Tool | Why gen-cargo needs it |
|---|---|
| `gen` (the binary itself) | The `gen build` command |
| `cargo` | `cargo metadata` subprocess for resolve graph |
| `rustc` | cargo metadata's `rustc-cfg=` queries |
| `cacert` | TLS cert bundle for cargo's registry index fetch |
| `nix-prefetch-git` | gen-cargo's `prefetch_git_sha256` step for each git source |
| `git` | nix-prefetch-git's transitive dep |

**The contract:** when gen-cargo lands a new code path that requires
a subprocess (signature verification, custom hashers, alternate
prefetchers, additional resolvers), the matching tool MUST be added
to `mk-build-spec.nix`'s `nativeBuildInputs` in the same PR. The
gen-side hard-error message should always name the missing tool so
future operators see the exact symbol to add here.

Failure mode this contract prevents: "gen: error: failed to prefetch
sha256 for git source ... No such file or directory (os error 2)" —
emitted when the tool gen calls isn't on PATH inside the sandbox.

Reference: gen-cargo 3f6e4fa hard-fails on prefetch_git_sha256
failure; substrate 267430e added `nix-prefetch-git` + `git` after the
fleet rebuild surfaced the missing-tool class.

## ★★ Self-consistent SVH — the favored Rust-closure pattern

A Rust crate's **SVH** (Strict Version Hash) is baked into its `.rustc`
metadata and checked by every *consumer* crate. A build's rlibs must all come
from ONE SVH-coherent source or the consumer hits `error[E0463]: can't find
crate for X` (even with `--extern …rlib` passed). Favored, both first-class:

1. **rio fills, darwin consumes** — rio (Linux, sandboxed) builds reproducibly
   (byte-stable SVH) and is the sole filler of the shared cache.
2. **darwin builds fully local** — one `darwin-rebuild` invocation → one rustc
   run → mutually consistent SVHs.

**SUNSET / directly inferior — never reintroduce: darwin pushing
`aarch64-darwin` Rust crates to a shared substituter.** darwin has no full
nix sandbox, so rustc's SVH absorbs per-build entropy and diverges build-to-
build of the *same* `.drv` → a push poisons every consumer. Disabled fleet-
wide (`tend.prebuild` off on darwin + closure-deep `repro="verify"` gate).
Re-enable only behind a proven byte-reproducible darwin build.

Recovery when poisoned (E0463 in a darwin rebuild): purge the poisoned `-lib`
store paths (`sudo nix-store --delete --ignore-liveness`) + rebuild with
`--option substitute false` (local self-consistent build). Full runbook +
verified root cause: `pleme-io/nix/docs/darwin-rust-cache-reproducibility.md`.
