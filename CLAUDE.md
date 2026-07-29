# Substrate

`pending-vacuous-guard: infra/wasm-compat` — `lib/infra/tests/wasm-compat-test.nix`
is the one eval suite deliberately left OUT of CI (2026-07-28), while the other 22
were wired. Not red, not broken: a tautology. Its 13 assertions compare
`wasmCompat.<crate>` against the literal written into `wasmCompat` in the same
file, so the suite reads nothing outside itself and cannot fail when a crate's
real wasm32 compatibility changes. Wiring it would add 13 units of coverage that
verify nothing, indistinguishable in a CI log from the 830 that work. The file's
own header states what would make it real (derive the matrix from each crate's
Cargo.toml/flake, or make it a per-crate `checks.<system>.*` build).

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

## ★ Reusable CI workflows (`.github/workflows/caixa-*.yml`)

These four reusable workflows ship from this repo. **Three repos call one,
out of 224 in the checkout that carry a `caixa.lisp` / `*.caixa.lisp`** —
`mirante` and `programs` (`caixa-validate.yml`), `hello-rio`
(`caixa-publish.yml`). All three match the caller shape below, at 17–25
lines rather than 5–10.

The other 221 are not un-CI'd; they are CI'd by a different family. Across
every workflow in those repos the `uses:` lines resolve to
`cargo-auto-release.yml` (152), `security-gate.yml` (143),
`pre-merge-gate.yml` (143), `go-auto-release.yml` (43) and
`reusable-gen-spec.yml` (33) — the two `caixa-*` callers are the tail, not
the norm. **So this section documents an available shape, not the fleet's
actual caixa CI.** A fifth reusable, `caixa-auto-release.yml`, also ships
here and has zero callers.

Counted 2026-07-28 over a local fleet checkout that contains vendored
mirrors — lower bounds, not org-wide percentages.

| workflow | for | gates |
|---|---|---|
| `caixa-publish.yml` | `:kind Servico` (Rust→wasm) | feira lint → cse-lint repo --strict → nix build dockerImage → ghcr push (`v<versao>` + `:latest`) → git tag v<versao> |
| `caixa-publish-tlisp.yml` | pure-Lisp Servico/Biblioteca/Binario (github: source URL) | same gates, no OCI image, only git tag (Zig-style) |
| `caixa-validate.yml` | monorepos (programs/), PRs, dev branches | non-publishing gate: cse-lint --strict + feira lint |
| `caixa-forge.yml` | caixas with OpenAPI specs | runs forge-gen → auto-PR on drift |

Caller workflow shape is identical across all four:

```yaml
name: release
on: { push: { branches: [main] }, workflow_dispatch: {} }
jobs:
  release:
    uses: pleme-io/substrate/.github/workflows/<workflow>.yml@main
    secrets: inherit
    permissions: { contents: write, packages: write }
```

**`cse-lint repo --strict` is a hard gate in exactly one of these
workflows.** `caixa-validate.yml:70` runs it bare, so a violation fails the
job. `caixa-publish.yml:140` and `caixa-publish-tlisp.yml:84` end the same
command in `|| echo "::warning::…"` — deliberately, each with a
migration-window comment — so on the publish path a violation prints a
warning and the build goes green. **A discarded verdict is not a gate**
(★★ UNREPRESENTABILITY tier ⊥, "discarded" subclass): never read the step's
presence in a publish log as enforcement.

Reach: `mirante` and `programs` hit the hard gate (`push: main` +
`pull_request`); `hello-rio` hits the swallowed one (`push: main`). The only
other `cse-lint` invocation in any workflow in the checkout is substrate's
own `cse-audit.yml`, a separate `cse-lint audit` surface with no callers.

So "enforces the 6 CSE invariants on every commit … structurally enforced"
was wrong three ways: it reaches **3 repos of 224**, it is a hard gate in
**2 of those 3**, and it fires on pushed commits and PRs rather than every
commit. The six invariants it checks (claude-md-pointer, hand-roll,
manifest-membership, module-trio-adoption, deployment-coverage,
**caixa-naivete**) are the tool's, not this pipeline's guarantee —
`caixa-validate.yml`'s own header names only four of them.

And a caller is not a run: **554 of 716 workflow-bearing pleme-io repos have
Actions disabled at the repo level**, so every count above is an upper bound
on what actually executes.

**Skill:** `caixa-author` — for authoring or migrating any caixa,
this is the first reference.

## ★★ `nix flake check` BUILDS ONLY `checks.<system>.*` — a builder that emits none hands out a green lie

**The single most load-bearing fact about this repo's verification
surface.** `nix flake check` *evaluates* `packages` / `devShells` / `apps`
— it literally prints `(build skipped)` — and **builds** only
`checks.<system>.*`. So a flake declaring zero checks makes that command a
pure *evaluation* check: it passes over a crate that was never compiled,
let alone tested.

**Measured, not inferred (2026-07-27).** A consumer-shaped fixture over
`lib/build/rust/library.nix` at substrate `3f4dfb9` reported
`checks.<system>` = `[]` and `nix flake check` **exit 0 with a
deliberately failing test in the crate**. On `forge`, `nix flake check
--impure` returned exit 0 in 8.66 s with `compile_error!` inside
`#[cfg(test)] mod tests`, and again with literal non-Rust garbage in a
function body. `cargo-ci.yml`'s header meanwhile claimed it ran
"`cargo test` via the substrate baseline" — **there was no such
baseline**, and at least `forge`, `iac-forge`, `engenho` plus nine
`tool-release` consumers were relying on the claim.

### What every Rust builder now emits

| check | emitted | proves |
|---|---|---|
| `checks.build` | always, both build paths | the SHIPPED artifact compiles (same derivation as `packages.default`, so it is paid for once) |
| `checks.tests` | `library.nix` always; `tool-release.nix` only on `buildMode = "cargo-nix"` | the crate's tests actually RUN (crate2nix `runTests` → `crateWithTest`) — **emitted by the builders, reaching zero consumers; see below** |

Policy lives in **`lib/build/rust/test-check.nix`** — one surface, so both
builders emit the same shape. Opting out is typed (`tests = { enable =
false; reason = "…"; }`); a bare boolean is refused, same grammar as
`lib/infra/mutating-verbs.nix`.

### `checks.tests` reaches ZERO consumers — the row above is about the builders, not the fleet

Two independent reasons, both measured 2026-07-28 over a local fleet
checkout containing vendored mirrors (lower bounds, not org-wide
percentages). Either one alone would be sufficient; both hold.

1. **`substrate.rust.library` never reaches `library.nix`.** All five
   `substrate.rust.<shape>` entry points are `callShape` over one builder
   (`flake.nix:496-506` → `mk-rust-tool-flake.nix` → `tool-release.nix`);
   `shape` validates and records, it does not select a builder.
   `lib/build/rust/shape.nix` states this and prices the routing fix — read
   it before assuming the shape name means anything about the build path.
   So the **136** `flake.nix` files naming `substrate.rust.library` — out of
   **270** naming any `substrate.rust.*`, or **290** counting direct
   `mkRustToolFlake` — all land on the `tool-release` path, where the row's
   other condition applies: **zero of them set `buildMode = "cargo-nix"`**.

2. **The 16 repos that DO reach `library.nix` discard its `checks`.**
   Pattern-3 standalone import is a live route the shape-routing argument
   misses entirely: 15 repos import `lib/rust-library.nix` (the two-line
   shim to `build/rust/library.nix`) and `pleme-app-core` imports
   `lib/build/rust/library.nix` directly. Every one of the 16 then writes
   `inherit (lib) packages devShells apps;` — the string `checks` does not
   appear **anywhere** in any of their `flake.nix` files. The builder emits
   the check; the consumer flake never re-exports it; `nix flake check`
   there builds nothing. That is the same green lie this whole section
   exists to close, one layer further out, and it is not fixed by anything
   in `test-check.nix`.

### The named gap — do not paper over it

`checks.tests` is **absent on the default `lockfile` build path**, and the
absence is deliberate. gen's build spec carries **no dev-dependency
graph** (a crate record has `runtime_dependencies` + `build_dependencies`
only, and `spec-invariants.nix` *rejects* a `kind = "dev"` edge in
either), and nixpkgs' bare `buildRustCrate` has no `runTests` argument at
all — only `buildTests`, which compiles test targets without dev-dep
externs and never runs them. **12 of 13 surveyed consumers declare
`[dev-dependencies]`**, so a test target simply cannot be compiled there
today. Emitting an always-green `checks.tests` that ran nothing would be
strictly worse than emitting none — a guard over an empty subject set
reports a tier it does not have (★★ UNREPRESENTABILITY §II.3, tier ⊥).

**The load-bearing fix is upstream in gen-cargo** (emit `dev_dependencies`
edges into the spec, per the ★★ GEN TYPED-SPEC CONTRACT above) plus a
substrate-side test-runner derivation. A Nix-side re-derivation of cargo's
dev-dep feature resolution would be a second, untested copy of the
resolver. Tracked as **`pending-rust-test-check: lockfile-dev-deps`**.
Until it lands, the real-test leg for those consumers is the `cargo-test`
job in `cargo-ci.yml` (`cargo test` inside the flake's devShell on the CI
runner), which retires into `checks.tests` when the pending item closes.

**That leg carries three repos — `engenho`, `forge`, `iac-forge` — against
the 270 `flake.nix` files naming a `substrate.rust.*` builder** (290 counting
direct `mkRustToolFlake`). `nix-devshell-cargo-test.yml`, which
`cargo-ci.yml` composes, has one further direct caller, `pangea-operator`.
So for the great majority of consumers there is no real-test leg at all
today: not `checks.tests`, and not this job either.

**And on 2026-07-27 it ran the tests of ZERO of those three.** State the
denominator here too, because "carries three repos" is a reach, not a
coverage. Measured 2026-07-28, `devShells.<sys>.default.name` per caller:
`forge` → `devenv-shell` (its own `devenv.flakeModule`, the only pleme-io
repo importing it), `engenho` → `devenv-shell`, `iac-forge` → `devenv-shell`
(both stale substrate pins, pre-`e232917`). `nix develop` cannot enter a
devenv shell non-interactively, so the leg that was added to make the test
claim true broke all three consumers and verified none. `checks.tests` was
vacuous by **absence**; this was vacuous by **breakage**.

The general lesson, which outlives the devenv specifics: **a job added to a
shared `@main` reusable asserts a capability of every consumer.** This one
asserted "`.#default` is enterable non-interactively" — never guaranteed by
any substrate builder, and true for none of them. Two things now hold it:

- **The preflight is wired.** `lib/util/devshell-preflight.nix` shipped
  tested-but-unwired (its own header: "No workflow imports
  `devshellPreflightPath` — zero hits"), which is the *unreached* subclass of
  tier ⊥ — a guard passing its unit tests against zero real subjects.
  `nix-devshell-cargo-test.yml` now invokes it, so a non-enterable devShell
  yields an actionable verdict naming the fix instead of a raw nix trace.
- **The reusable has an in-repo caller.** `devshell-cargo-test-selftest.yml`
  + `devShells.<sys>.selftest-cargo` + a dependency-free fixture crate. Until
  it existed, the first execution of a new leg *anywhere* was in a downstream
  repo's CI — a shared reusable with no caller here cannot go red before its
  blast radius does.

`--impure` is **not** the fix, measured rather than assumed: `nix develop
--impure .#default` on forge does not succeed, it fails *differently*
(`error: To use 'languages.rust.channel', Add … inputs.rust-overlay.url`).
Hence `devshell-args` is a distinct input and `flake-args` is deliberately
not forwarded into `nix develop`. Receipts: run `30411786849` — `1 passed`
through the shipped path after `preflight OK`, and the deliberate break
refusing non-zero.

Count uncommented `uses:` lines, not mentions. A plain grep for the string
`cargo-ci.yml` returns 8 repos: 3 callers, substrate itself (which defines
it), and **4 — `pangea-forge`, `ruby-synthesizer`, `yaml-synthesizer`,
`shikumi` — that name it only in comments explaining why they deliberately
do NOT adopt the shim**, each with its own measured blockers worth reading
before "simplifying" any of them back.

Counted 2026-07-28 over a local fleet checkout containing vendored mirrors:
lower bounds, not org-wide percentages. And a caller is not a run — **554 of
716 workflow-bearing pleme-io repos have Actions disabled at the repo
level**, so 3 callers is itself an upper bound on how many execute this leg.

### `cargo-ci.yml` — two jobs, and the split is the point

`flake-check` runs `nix flake check`, then a gate
(`lib/util/flake-checks-gate.nix`) that **fails loudly when the flake
exposes zero checks** and otherwise **prints the check names it built**, so
a green states what it verified instead of being opaque. `cargo-test`
composes the existing `nix-devshell-cargo-test.yml` (Operating Principle
#1 — extend the near-miss) and defaults to `--all-features`: on forge,
plain `--all-targets` ran 2,663 tests while `--all-features` ran 2,950
— an `attestation` feature gated 263 of them, and a gate that silently
skips a tenth of the suite is a fresh subject-set vacuity inside the very
thing meant to close one.

Both new surfaces are covered by substrate's own gate:
`checks.<system>.rust-test-check` and `checks.<system>.flake-checks-gate`,
each **verified red against a deliberately-broken input before landing**
(removing the availability gate throws on the poisoned `mkTests`;
dropping the reason requirement fails 3 tests; making the gate return a
string instead of throwing fails 4).

**Separately documented under-scope, left alone on purpose:**
`tool-release.nix`'s `gen confirm . --if-present` tolerates `rc=1` for the
~10 consumers with no committed delta — an honest, documented gap in a
different gate, not this one.

## ★★ `runTests` REPORTS, it does not throw — the eval-suite catalog exists because of that

substrate's own eval tests come in three families, and the third one
cannot be gated the way the first two are.

| family | shape | run by |
|---|---|---|
| **A** self-evaluating | `throw`s on the first failure | `nix-instantiate --eval --strict <file>` |
| **B** `{ lib }` + `asCheck pkgs` | a `checks.<system>.*` derivation | `nix build .#checks.<system>.<name>` |
| **C** report-returning | evaluates to a VALUE describing the run | `lib/util/eval-suites.nix` |

**Family C's trap, stated plainly:** `util/test-helpers.nix`'s `runTests`
returns `{ total; passCount; failCount; allPassed; failures; }`. It does
**not** throw when a test fails — it records the failure and carries on.
So `nix-instantiate --eval --strict lib/util/tests.nix` **exits 0 whether
every assertion passes or every assertion fails**; it detects only an
evaluation error. Measured 2026-07-28 on a deliberately-broken copy of
that exact file: the family-A command exited 0 while the catalog gate
exited 1 on the same bytes. Copying the family-A steps for these suites
would have added four jobs that run 830 assertions and gate on none —
a discarded verdict, not a gate (★★ UNREPRESENTABILITY tier ⊥).

**What is wired.** 22 suites / **830 assertions**, none of which ran in
any job on any trigger before 2026-07-28: `lib/types` (144),
`lib/infra` (298), `lib/build/shared` + `nixos` + `rust` + `go` (244),
`lib/kube` (57), `lib/hm` (65), `lib/util` (22). Catalog and gate live in
`lib/util/eval-suites.nix`; the steps are in `nix-tests.yml`'s four
`*-suites` jobs, one step per suite so a failure names the suite.

Two properties beyond "it runs":

- **An assertion FLOOR per suite.** Each entry records the count measured
  when it was wired, and the gate fails on `total < min` as well as on a
  failing assertion — so a suite that silently *shrinks* (a `map` over a
  list that became empty, a block dropped in a refactor) turns red instead
  of reporting a smaller green.
- **A catalog-covers-workflow forcing-function.** `only = "coverage"`
  reads `nix-tests.yml` and fails when a catalogued suite has no step.
  "In the catalog, running nowhere" is the exact defect the catalog
  repairs, so it is made unable to recur silently. Same trick as
  `rust-shape`'s `known-set-covers-every-flake-call-site`, which reads
  `flake.nix`.

**NOT VACUOUS: verified red against deliberately-broken inputs, not
merely observed green.** A flipped assertion in `lib/util/tests.nix`
(1 of 22 failed, exit 1); six tests deleted from `lib/types/tests.nix`
(`SHRANK 73 < 79`, exit 1); an unknown suite name (exit 1); and the
coverage check itself was red on all 22 entries before the steps existed
and green after. All restored afterwards.

**One suite is deliberately excluded** — see `pending-vacuous-guard:
infra/wasm-compat` at the top of this file. It is green, and that is the
problem.

**A vacuity found INSIDE a newly-running suite, and fixed.**
`lib/types/property-tests.nix`'s `testInformationFlow` runs
`checkInformationFlow` over seven `sampleSpecs` that each carry
`secrets = []` and `env = {}` — so `leaked == []` holds by construction
and none of those seven can detect a leak. Its one "positive control"
re-implemented the leak filter inline and asserted on its own copy, so it
passed **without ever calling the function under test**: blinding
`checkInformationFlow` to always report no-leak left all 8 tests green.
The control now calls the real function on a genuinely leaking spec and
asserts the rejection — the same blinding now fails it (1 of 8, exit 1).
The seven remain structurally vacuous and are documented as such in the
file; they prove the checker *evaluates* per archetype, not that it
*detects*. Do not count them as leak coverage.

## ★ Reusable CI workflows (`.github/workflows/ansible-collection-*.yml`)

Layer 2 of the ansible-collection SDLC: nine composite workflows that
**compose `pleme-io/actions/*@v1`** (Layer 1 custom actions) and that
collection repos (`ansible-akeyless`, `ansible-akeyless-gen`) consume as
≤15-line wrappers (Layer 3). Zero inlined shell beyond the project-specific
spec-fetch / mock-server hooks.

| workflow | one-line role |
|---|---|
| `ansible-collection-ci.yml` | `nix flake check` with optional OpenAPI spec fetch (`AKEYLESS_OPENAPI_YAML`) |
| `ansible-collection-release.yml` | build tarball → publish to Galaxy (no-op if token unset) → attach to GH Release on tag |
| `ansible-collection-auto-bump.yml` | patch-bump galaxy.yml when plugins/meta/galaxy.yml changed since last tag, push, tag (accepts optional `BOT_PAT` secret so tag push triggers downstream release; falls back to `GITHUB_TOKEN` if absent) |
| `ansible-collection-upstream-watch.yml` | scheduled OpenAPI poller → iac-forge regen → PR labeled `automated` |
| `ansible-collection-auto-merge.yml` | enable squash auto-merge on PRs labeled `automated` |
| `ansible-collection-docs-lint.yml` | antsibull-docs lint in `ansible_collections/<ns>/<name>/` layout |
| `ansible-collection-published-install.yml` | install from Galaxy + ansible-doc smoke per module (scheduled) |
| `ansible-collection-matrix.yml` | Python × ansible-core × OS compatibility matrix |
| `ansible-collection-ansible-test.yml` | `ansible-test sanity` + `units` in proper layout |
| `ansible-collection-integration-live.yml` | Python mock akeyless gateway + example playbooks in `--check` mode |

Convention: these workflows compose `pleme-io/actions/*` at `@v1` (the
floating major). No inlined shell beyond what is strictly project-specific
(OpenAPI fetch URL, mock-server bootstrap). Collection-repo wrappers stay
≤15 lines.

## ★ Reusable publish primitives (per-channel)

Tag-triggered reusable workflows for each artifact channel. Caller is
always a ≤15-line wrapper. Every workflow is **secret-gated** (publish
step is a no-op + clear notice when the channel token is absent), so
the same `release.yml` can be merged before secrets are configured and
the build half still runs as a smoke test.

| workflow | channel | one-line role |
|---|---|---|
| `crates-publish.yml` | crates.io | `cargo publish` (CRATES_API_TOKEN) |
| `ansible-collection-release.yml` | Galaxy + GH Release | build tarball → publish to Galaxy (no-op if token unset) → attach to GH Release |
| `helm-publish.yml` | ghcr.io/charts (OCI) | helm lint + package + push, forge preferred (GHCR_TOKEN) |
| `helm-chart-release.yml` | ghcr.io/charts (OCI) | tag-aware thin wrapper around `helm-publish.yml`: parses chart version from `v*` tag, delegates publish |
| `image-push.yml` | ghcr.io (Docker / OCI) | nix build .#dockerImage → forge push / skopeo copy (GHCR_TOKEN) |
| `rust-binary-release.yml` | GH Release | cross-arch (linux/macOS × x86_64/aarch64) feature-aware cargo build → attach binaries + .sha256 to Release |
| `rust-release.yml` | crates.io + GH Release | combined Rust workspace release primitive |
| `terraform-provider-publish.yml` | Terraform Registry | goreleaser builds + GPG-signs the provider, uploads to GH Release; Registry auto-detects via webhook (TF_REGISTRY_GPG_PRIVATE_KEY + TF_REGISTRY_GPG_PASSPHRASE). First-time providers require manual registration at registry.terraform.io |
| `pulumi-provider-publish.yml` | Pulumi Cloud + npm + PyPI | builds Go provider binary + Python SDK + Node.js SDK; per-language publish gated by PYPI_TOKEN / NPM_TOKEN / PULUMI_ACCESS_TOKEN. Plugin tarballs always land on GH Release |
| `crossplane-provider-publish.yml` | xpkg.upbound.io / ghcr.io | `crossplane xpkg build` + push (UPBOUND_TOKEN or GHCR_TOKEN); ArtifactHub auto-indexes xpkg.upbound.io |
| `steampipe-plugin-publish.yml` | Steampipe Hub | cross-arch go build → tarball + checksum to GH Release. Hub listing requires manual PR to turbot/steampipe-plugins-hub; subsequent releases auto-detected |

Conventions:
- `workflow_call` trigger + typed inputs + typed `secrets:` block.
- Header comment with one-line consumer usage.
- Publish step is **idempotent** + **secret-gated** (token absent → notice + exit 0).
- For channels where the publish CLI does not yet exist or requires
  out-of-band registration (Terraform Registry, Steampipe Hub, Pulumi
  Registry listing), the workflow stages the artifact + emits a notice
  describing the manual step rather than failing.

Reusable Nix build patterns consumed by all pleme-io product and library repos.

Implements the **Unified Infrastructure Theory**: Nix as the universal
language for describing any system. Abstract workload archetypes declare
intent; backend renderers translate to any target (K8s, tatara, WASI, Compose).

Composes with tatara's **Unified Convergence Computing Theory**: each rendered
target becomes a convergence DAG with verified atomic boundaries. The
infrastructure theory says WHAT. The convergence theory says HOW. Together:
declare any system in Nix, compute it into existence through verified
convergence, prove every step cryptographically via tameshi.

This repo is PUBLIC. Never commit secrets, user-specific data, or private paths.

---

## Module Hierarchy

```
lib/
├── default.nix                    # Root aggregation — ALL public API surfaces
├── types/                         # Type system — typed interfaces for all domains
│   ├── default.nix                # Aggregation: foundation, ports, buildResult, etc.
│   ├── foundation.nix             # NixSystem, Architecture, Language, ArtifactKind, etc.
│   ├── ports.nix                  # Unified port types with attrTag + coercedTo
│   ├── build-result.nix           # Universal output contract (packages, devShells, apps)
│   ├── build-spec.nix             # Per-language typed input specs
│   ├── service-spec.nix           # HealthSpec, ScalingSpec, ResourceSpec, MonitoringSpec
│   ├── deploy-spec.nix            # DockerImageSpec, DeploySpec, ReleaseSpec
│   ├── infra-spec.nix             # WorkloadSpec, PolicyRule, MultiTierAppSpec
│   ├── kube-spec.nix              # KubeMetadata, SecurityContext, Probes, RBAC
│   ├── validate.nix               # mkTypedBuilder, validateSpec, checkBuildResult
│   └── tests.nix                  # 79 pure eval tests for all types
├── build/                         # Language-specific build patterns
│   ├── rust/                      # overlay, library, service, service-flake,
│   │                              #   tool-release, tool-release-flake,
│   │                              #   tool-image, tool-image-flake, devenv,
│   │                              #   crate2nix-builders, crate2nix-apps
│   ├── go/                        # overlay, tool, monorepo, monorepo-binary,
│   │                              #   library-check, docker, grpc-service,
│   │                              #   bootstrap, toolchain, patches/
│   ├── zig/                       # overlay, tool-release, tool-release-flake,
│   │                              #   bootstrap, deps, zls
│   ├── swift/                     # overlay, bootstrap, sdk-helpers
│   ├── typescript/                # tool, library, library-flake
│   ├── ruby/                      # config, build, gem, gem-flake
│   ├── python/                    # package, uv
│   ├── dotnet/                    # build
│   ├── java/                      # maven
│   ├── wasm/                      # build
│   ├── web/                       # build, docker, github-action
│   └── nixos/                     # aws-ami (NixOS → AWS AMI, packer + direct)
├── kube/                          # Kubernetes resource builders (nix-kube)
│   ├── primitives/                # 29 pure K8s resource builders (no pkgs)
│   │   ├── deployment.nix         # mkDeployment
│   │   ├── service.nix            # mkService
│   │   ├── network-policy.nix     # mkNetworkPolicySet (deny-all+DNS+Prometheus)
│   │   └── ...                    # 26 more (statefulset, hpa, pdb, shinka, etc.)
│   ├── compositions/              # 9 service archetypes
│   │   ├── microservice.nix       # mkMicroservice → Deployment+Service+SA+SM+NP+...
│   │   ├── worker.nix             # mkWorker → Deployment+PodMonitor+NP
│   │   ├── operator.nix           # mkOperator → Deployment+SA+RBAC+NP
│   │   └── ...                    # web, cronjob, database, cache, namespace-gov, bootstrap
│   ├── modules/                   # NixOS-style module system
│   │   ├── eval.nix               # evalKubeModules (overlay applicator)
│   │   └── presets/               # hardened.nix, observable.nix
│   ├── eval.nix                   # Dependency ordering by K8s kind
│   ├── flake.nix                  # Zero-boilerplate flake entry point
│   ├── defaults.nix               # Shared defaults (security, probes, resources)
│   └── tests.nix                  # 57 pure eval tests (was "37" until counted 2026-07-28)
├── infra/                         # Infrastructure-as-Code patterns
│   ├── workload-archetypes.nix    # Unified infrastructure theory: 7 abstract archetypes
│   │                              #   mkHttpService, mkWorker, mkCronJob, mkGateway,
│   │                              #   mkStatefulService, mkFunction, mkFrontend
│   ├── compositions.nix           # Cross-archetype wiring: mkMultiTierApp, mkPipeline
│   ├── policies.nix               # Governance: mkPolicy, evaluateAll, assertPolicies
│   ├── policy-presets/            # production.nix, development.nix
│   ├── renderers/                 # Backend-specific translation
│   │   ├── kubernetes.nix         # Archetype → nix-kube compositions
│   │   ├── tatara.nix             # Archetype → tatara JobSpec
│   │   └── wasi.nix               # Archetype → WASI component config
│   ├── k8s-manifest.nix           # K8s metadata, ArgoCD sync policies
│   ├── argocd-appset.nix          # ApplicationSet generators
│   ├── external-secrets.nix       # ExternalSecret manifests
│   ├── pangea-arch-workspace.nix  # CANONICAL — subdirectory workspace
│   │                              # in pangea-architectures (six verbs:
│   │                              # plan/deploy/destroy/synth/test/import +
│   │                              # extraApps for custom verbs).
│   │                              # See pangea-architectures/docs/workspace-sdlc.md
│   ├── pangea-workspace.nix       # Nix->YAML->pangea (no .rb template,
│   │                              # whole config in Nix attrsets)
│   ├── pangea-infra.nix           # Top-level repo-as-workspace builder
│   ├── pangea-infra-flake.nix     # Top-level Pangea flake wrapper
│   ├── mutating-verbs.nix         # ★★ typed retirement of hand-run
│   │                              # mutating verbs (apply/destroy/init/
│   │                              # mutating flows). ONE surface, honoured
│   │                              # by every Pangea builder here.
│   ├── fleet-pangea-infra.nix     # Top-level repo with declarative
│   │                              # fleet flows in Nix
│   ├── fleet-pangea-infra-flake.nix # ^ flake wrapper
│   ├── ami-build.nix              # AMI build/test/promote pipeline
│   │                              #   mkBuildTemplate, mkTestTemplate,
│   │                              #   mkAmiBuildPipeline
│   ├── terraform-module.nix       # TF module validation
│   ├── terraform-provider.nix     # TF provider builds
│   ├── pulumi-provider.nix        # Pulumi SDK gen (5 languages)
│   ├── ansible-collection.nix     # Galaxy collection packaging
│   └── environment-config.nix     # Environment variable config
├── service/                       # Service lifecycle patterns
│   ├── helpers.nix                # Docker compose, test runners
│   ├── platform-service.nix       # Full platform service builder
│   ├── environment-apps.nix       # Env-aware deployment apps
│   ├── product-sdlc.nix          # Product SDLC app factory
│   ├── db-migration.nix          # K8s migration jobs
│   ├── health-supervisor.nix     # Health supervisor builder
│   ├── image-release.nix         # Multi-arch OCI release
│   └── helm-build.nix            # Helm chart SDLC
├── hm/                            # home-manager integration
│   ├── service-helpers.nix        # launchd + systemd service templates
│   ├── mcp-helpers.nix            # MCP server deployment
│   ├── skill-helpers.nix          # Claude Code skill framework
│   ├── typed-config-helpers.nix   # JSON/YAML config from Nix options
│   ├── workspace-helpers.nix      # Workspace config helpers
│   ├── secret-helpers.nix         # Secret management helpers
│   └── nixos-service-helpers.nix  # NixOS module patterns
├── codegen/                       # Code generation patterns
│   ├── openapi-forge.nix          # OpenAPI parsing + forge
│   ├── openapi-sdk.nix            # Multi-language SDK gen
│   ├── openapi-rust-sdk.nix       # Rust SDK gen
│   └── source-registry.nix        # Pinned source registry
├── util/                          # Shared utilities
│   ├── config.nix                 # Tokens, secrets, runtime tools
│   ├── darwin.nix                 # macOS SDK deps helper
│   ├── docker-helpers.nix         # Docker build utilities
│   ├── release-helpers.nix        # Release workflow helpers
│   ├── completions.nix            # Shell completion gen
│   ├── test-helpers.nix           # Pure Nix eval test infra
│   ├── flake-wrapper.nix          # Flake boilerplate reduction
│   ├── repo-flake.nix             # Universal flake builder
│   ├── monorepo-parts.nix         # flake-parts monorepo module
│   └── versioned-overlay.nix      # N tracks x M components overlays
└── devenv/                        # devenv.sh module templates
    ├── nix.nix
    ├── rust.nix
    ├── rust-service.nix
    ├── rust-tool.nix
    ├── rust-library.nix
    └── web.nix
```

---

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

## Key Exports from `lib/default.nix`

### Build

| Export | Source | Description |
|--------|--------|-------------|
| `mkRustOverlay` | `build/rust/overlay.nix` | Fenix stable overlay for crate2nix |
| `mkGoOverlay` | `build/go/overlay.nix` | Go from upstream source |
| `mkZigOverlay` | `build/zig/overlay.nix` | Prebuilt Zig + source zls |
| `mkSwiftOverlay` | `build/swift/overlay.nix` | Swift 6 from swift.org (Darwin) |
| `mkCrate2nixProject` | `build/rust/crate2nix-builders.nix` | Per-crate cached Rust build |
| `mkCrate2nixDockerImage` | `build/rust/crate2nix-builders.nix` | Multi-arch Docker image |
| `mkCrate2nixServiceApps` | `build/rust/crate2nix-apps.nix` | Full service app set |
| `mkGoTool` | `build/go/tool.nix` | Go CLI tool builder |
| `mkNpmTool` | `build/npm/tool.nix` | npm CLI tool builder (external upstream source, e.g. fetchFromGitHub) |
| `mkPnpmTool` | `build/npm/pnpm-tool.nix` | pnpm CLI tool builder (pnpm-lock.yaml sources; wraps nixpkgs' native pnpm.fetchDeps + configHook) |
| `mkGoMonorepoSource` | `build/go/monorepo.nix` | Shared monorepo source |
| `mkGoMonorepoBinary` | `build/go/monorepo-binary.nix` | Binary from monorepo |
| `mkViteBuild` | `build/web/build.nix` | Vite/React builds |
| `mkTypescriptToolAuto` | `build/typescript/tool.nix` | Auto-discover TS tool |
| `mkRubyDockerImage` | `build/ruby/build.nix` | Ruby Docker image |
| `mkPythonPackage` | `build/python/package.nix` | Python package builder |
| `mkUvPythonPackage` | `build/python/uv.nix` | UV + pyproject.toml |
| `mkDotnetPackage` | `build/dotnet/build.nix` | .NET package builder |
| `mkJavaMavenPackage` | `build/java/maven.nix` | Maven package builder |
| `mkWasmBuild` | `build/wasm/build.nix` | Yew/WASM builds |
| `mkGitHubAction` | `build/web/github-action.nix` | GitHub Action builder |
| `mkLeptosBuild` | `build/rust/leptos-build.nix` | Dual-target Leptos SSR+CSR build |
| `mkLeptosDockerImage` | `build/rust/leptos-build.nix` | Docker image for Leptos SSR |
| `mkLeptosDockerImageWithHanabi` | `build/rust/leptos-build.nix` | CSR-only via Hanabi BFF |
| `mkNixosAwsAmi` | `build/nixos/aws-ami.nix` | NixOS system closure → AWS AMI (packer mode + direct mode); consumes `AmiConventionDecl`-shaped `amiName` + `amiTags` |

#### Standalone Rust Flake Builders

These are imported directly from substrate (not via `lib.${system}`):

| Builder | Source | Description |
|---------|--------|-------------|
| `rust-tool-release-flake.nix` | `build/rust/tool-release-flake.nix` | CLI tool with 4-target GitHub releases |
| `rust-tool-image-flake.nix` | `build/rust/tool-image-flake.nix` | CLI tool as Docker image for K8s CronJobs/init containers |
| `rust-action-release-flake.nix` | `build/rust/action-release-flake.nix` | pleme-io GitHub Action — Rust binary + composite action.yml |
| `rust-workspace-release-flake.nix` | `build/rust/tool-release-flake.nix` | Workspace CLI with `packageName` member selection |
| `rust-service-flake.nix` | `build/rust/service-flake.nix` | Dockerized microservice |
| `rust-library.nix` | `build/rust/library.nix` | crates.io library (check + test) |
| `leptos-build-flake.nix` | `build/rust/leptos-build-flake.nix` | Zero-boilerplate Leptos PWA flake |
| `eframe.nix` | `build/rust/eframe.nix` | eframe/egui GUI-app native-dep surface + `mkDevShell` + `mkPackage` (X11/wayland/vulkan/GL on Linux, apple-sdk on macOS) |

##### rust-action-release Pattern

For pleme-io GitHub Actions whose behavior is implemented as a Rust binary.
Wraps `rust-tool-release-flake.nix` with two extra outputs:

- `packages.<system>.action-yml` — the composite `action.yml` rendered as a
  single-file derivation
- `apps.<system>.write-action-yml` — `nix run .#write-action-yml` writes
  `./action.yml` directly to the consumer's repo root

Inputs to `action` are typed (name, description, required, default) +
the renderer hoists every `${{ inputs.<name> }}` to an `INPUT_<UPPER>` env
var per the `yaml.github-actions.security.run-shell-injection` rule.

```nix
outputs = (import "${substrate}/lib/build/rust/action-release-flake.nix" {
  inherit nixpkgs crate2nix flake-utils;
}) {
  toolName = "terragrunt-apply";
  src = self;
  repo = "pleme-io/terragrunt-apply";
  action = {
    description = "Run terragrunt plan/apply/destroy with typed inputs";
    inputs = [
      { name = "working-directory"; description = "Leaf dir"; required = true; }
      { name = "action"; description = "Mode"; default = "plan"; }
    ];
    outputs = [
      { name = "plan-summary"; description = "Counts"; }
    ];
  };
};
```

The action's binary reads inputs via `pleme_actions_shared::Input::from_env()`
(see `pleme-io/pleme-actions-shared`). Mirrors the typed `Action` domain
in `arch-synthesizer/src/action_domain/` 1:1, so the same typed declaration
can render via either Rust (canonical, in arch-synthesizer) or Nix (this
builder, when a consumer flake needs to emit action.yml without going
through arch-synthesizer's CLI).

##### rust-tool-image Pattern

For CLI tools that run as K8s CronJobs, init containers, or one-shot Jobs
rather than long-running services. Produces Docker images instead of GitHub
releases. Only targets Linux (amd64, arm64).

```nix
outputs = (import "${substrate}/lib/build/rust/tool-image-flake.nix" {
  inherit nixpkgs crate2nix flake-utils forge;
}) {
  toolName = "image-sync";
  src = self;
  repo = "pleme-io/image-sync";
  tag = "0.1.0";
  extraContents = pkgs: [ pkgs.crane ];  # runtime tools in Docker image
  architectures = ["amd64" "arm64"];
};
```

Key differences from `rust-tool-release`:
- Produces `dockerImage-amd64` / `dockerImage-arm64` packages
- `nix run .#release` pushes to `ghcr.io/${repo}` via forge (not GitHub releases)
- `extraContents` function receives target pkgs, adds runtime deps to the image
- Native binary wrapped with runtime deps on PATH for local testing
- No GitHub release artifacts -- images only

### Service

| Export | Source | Description |
|--------|--------|-------------|
| `mkServiceApps` | `service/helpers.nix` | Docker compose + deployment |
| `mkEnvironmentServiceApps` | `service/environment-apps.nix` | Env-aware deployments |
| `mkProductSdlcApps` | `service/product-sdlc.nix` | Full SDLC app factory |
| `mkImageReleaseApp` | `service/image-release.nix` | Multi-arch OCI release |
| `mkHelmSdlcApps` | `service/helm-build.nix` | Helm chart lifecycle |
| `mkHealthSupervisor` | `service/health-supervisor.nix` | Health check builder |

### Infrastructure

| Export | Source | Description |
|--------|--------|-------------|
| `pangeaInfraBuilder` | `infra/pangea-infra.nix` | Pangea project builder |
| `pangeaInfraFlakeBuilder` | `infra/pangea-infra-flake.nix` | Pangea flake wrapper |
| `mutatingVerbsBuilder` | `infra/mutating-verbs.nix` | ★★ typed retirement of hand-run mutating verbs (see below) |
| `mutatingVerbsTests` | `infra/tests/mutating-verbs-test.nix` | Pure eval tests for the above; `checks.<sys>.mutating-verbs` |
| `mkTerraformModuleCheck` | `infra/terraform-module.nix` | TF validation derivation |
| `mkPulumiProvider` | `infra/pulumi-provider.nix` | Pulumi SDK generation |
| `mkAnsibleCollection` | `infra/ansible-collection.nix` | Ansible Galaxy packaging |
| `mkBuildTemplate` | `infra/ami-build.nix` | Packer build template (NixOS AMI from base image) |
| `mkTestTemplate` | `infra/ami-build.nix` | Packer test template (boot AMI, run validation) |
| `mkAmiBuildPipeline` | `infra/ami-build.nix` | Nix run apps wrapping `ami-forge pipeline-run` |

### Home-Manager

| Export | Source | Description |
|--------|--------|-------------|
| `hmServiceHelpers` | `hm/service-helpers.nix` | launchd/systemd patterns |
| `hmSkillHelpers` | `hm/skill-helpers.nix` | Claude Code skill deploy |
| `hmMcpHelpers` | `hm/mcp-helpers.nix` | MCP server management |
| `hmTypedConfigHelpers` | `hm/typed-config-helpers.nix` | Typed config generation |
| `nixosServiceHelpers` | `hm/nixos-service-helpers.nix` | NixOS module patterns |
| `testHelpers` | `util/test-helpers.nix` | Pure Nix eval tests |

### Utility

| Export | Source | Description |
|--------|--------|-------------|
| `mkDarwinBuildInputs` | `util/darwin.nix` | macOS SDK deps |
| `mkRuntimeToolsEnv` | `util/config.nix` | Runtime tool env vars |
| `mkVersionedOverlay` | `util/versioned-overlay.nix` | N-track overlay gen |
| `repoFlakeBuilder` | `util/repo-flake.nix` | Universal flake builder |
| `monorepoPartsModule` | `util/monorepo-parts.nix` | flake-parts module |

### Type System

| Export | Source | Description |
|--------|--------|-------------|
| `substrateTypes` | `types/default.nix` | Complete type lattice (instantiated with pkgs.lib) |
| `substrateTypesPath` | `types/` | Standalone import path (no pkgs needed) |
| `typeTests` | `types/tests.nix` | 79 pure eval tests |
| `assertionTests` | `types/assertion-tests.nix` | 47 assertion library tests |
| `convergenceTests` | `types/property-tests.nix` | 18 property-based + convergence stage tests |
| `convergenceTypestate` | `types/convergence.nix` | Stage machine: declared → resolved → converged → verified |

Standalone import: `types = import "${substrate}/lib/types" { lib = nixpkgs.lib; };`

Key type modules:
- `types.foundation` — NixSystem, Architecture, Language, ArtifactKind, ServiceType, etc. (19 types)
- `types.ports` — Unified port types with `attrTag` + `coercedTo` for legacy compat
- `types.buildResult` — Universal output contract (`packages`, `devShells`, `apps`)
- `types.buildSpec` — Per-language typed input specs (rust, go, zig, ts, ruby, python, web, wasm)
- `types.serviceSpec` — HealthCheck, ScalingSpec, ResourceSpec, MonitoringSpec
- `types.deploySpec` — DockerImageSpec, DeploySpec, ReleaseSpec
- `types.infraSpec` — WorkloadSpec, PolicyRule, MultiTierAppSpec
- `types.kubeSpec` — KubeMetadata, SecurityContext, Probes, RBAC rules
- `types.convergence` — Stage typestate: `declared` → `resolved` → `converged` → `verified`
- `types.validate` — `mkTypedBuilder`, `validateSpec`, `checkBuildResult`
- `types.assertions` — Lightweight assertion guards: `nonEmptyStr`, `port`, `architecture`, `enum`, etc.

### Typed Builder Wrappers (module-system validated)

| Export | Source | Description |
|--------|--------|-------------|
| `rustServiceTypedBuilder` | `build/rust/service-typed.nix` | 25-option module-validated Rust service |
| `rustToolReleaseTypedBuilder` | `build/rust/tool-release-typed.nix` | Module-validated Rust CLI tool |
| `rustWorkspaceReleaseTypedBuilder` | `build/rust/workspace-release-typed.nix` | Module-validated workspace |
| `goGrpcServiceTypedBuilder` | `build/go/grpc-service-typed.nix` | Module-validated Go gRPC service |

### Shared Cross-Cutting Middleware

| Export | Source | Description |
|--------|--------|-------------|
| `mkTypedDockerImage` | `build/shared/docker-image.nix` | Universal Docker image builder |
| `mkWebDockerImage` | `build/shared/docker-image.nix` | Web app Docker with Hanabi |
| `mkServiceDockerImage` | `build/shared/docker-image.nix` | Service Docker with migrations |
| `mkReleaseApps` | `build/shared/release-app.nix` | Shared release/bump/check-all/lock-platform |
| `mkTypedDevShell` | `build/shared/devshell.nix` | Universal devShell factory |

### Formal Methods Improvements (academic-grounded)

These are structural properties enforced in the infrastructure layer:

| Property | Enforcement | Source |
|----------|-------------|--------|
| Information flow | `assertNoSecretLeaks` — secrets cannot appear in env | `workload-archetypes.nix` |
| Bilateral promises | `promiseViolations` — imports must match exports | `compositions.nix` |
| Intrinsic attestation | `mkSpecAttestation` — SHA-256 spec hash in every result | `workload-archetypes.nix` |
| Recursive lattice merge | `recursiveMerge` — nested defaults preserved | `workload-archetypes.nix` |
| Extensible renderers | `mkArchetypeWith` — add backends via functor interface | `workload-archetypes.nix` |
| Monotonicity guard | Module fold cannot remove services | `kube/modules/eval.nix` |
| Convergence typestate | `declared` → `resolved` → `converged` → `verified` | `types/convergence.nix` |

### Kubernetes (nix-kube) — Standalone Import

These are imported directly from substrate, not via `lib.${system}`:

| Builder | Source | Description |
|---------|--------|-------------|
| nix-kube primitives | `kube/primitives/*.nix` | 29 pure K8s resource builders (no pkgs) |
| nix-kube compositions | `kube/compositions/*.nix` | 9 service archetypes (mkMicroservice, mkWorker, etc.) |
| nix-kube eval | `kube/eval.nix` | Dependency ordering + JSON serialization |
| nix-kube flake | `kube/flake.nix` | Zero-boilerplate K8s resource flake |
| nix-kube modules | `kube/modules/eval.nix` | NixOS-style overlay system |
| nix-kube tests | `kube/tests.nix` | 57 pure eval tests — counted 2026-07-28 when the suite first ran in CI; the long-standing "37" was never re-counted. All 57 are reached by its `allPassed` aggregator (checked mechanically: zero defined-but-unforced `test*` attrs) |

### Unified Infrastructure Theory — Standalone Import

| Builder | Source | Description |
|---------|--------|-------------|
| Workload archetypes | `infra/workload-archetypes.nix` | 7 abstract archetypes: mkHttpService, mkWorker, mkCronJob, mkGateway, mkStatefulService, mkFunction, mkFrontend |
| Compositions | `infra/compositions.nix` | mkMultiTierApp, mkPipeline — cross-archetype wiring |
| Policies | `infra/policies.nix` | mkPolicy, evaluateAll, assertPolicies — governance |
| Policy presets | `infra/policy-presets/*.nix` | production.nix, development.nix |
| K8s renderer | `infra/renderers/kubernetes.nix` | Archetype → nix-kube compositions |
| Tatara renderer | `infra/renderers/tatara.nix` | Archetype → tatara JobSpec |
| WASI renderer | `infra/renderers/wasi.nix` | Archetype → WASI component config |
| Infra tests | `infra/tests/leptos-deploy-test.nix` | 30 pure eval tests for Leptos PWA archetype rendering |

### Examples

| File | Description |
|------|-------------|
| `examples/leptos-deploy.nix` | Full Leptos PWA deployment through all three renderers (K8s, Tatara, WASI) |
| `examples/leptos-helm-values.nix` | Helm values generator for Leptos SSR services (`mkLeptosHelmValues`) |
| `examples/leptos-tatara-jobspec.json` | Concrete Tatara JobSpec for Lilitu Web PWA |
| `examples/leptos-wasi-config.json` | WASI Preview 2 component config for Leptos SSR |

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

## ★★ `mutatingVerbs` — typed retirement of hand-run mutating verbs

**One surface, in `lib/infra/mutating-verbs.nix`, honoured by every Pangea
builder in the table below — which is four of the five, not all of them (see
"The one builder without a surface").** ★★ PLATFORM-MEDIATED INFRASTRUCTURE says a human's only two
verbs are DECLARE and OBSERVE; ★★ MODULARIZE, DON'T DELETE says retirement is
a typed flag, never a deletion. `mutatingVerbs` is where those two meet.

```nix
mutatingVerbs.apply = {
  enable    = false;                 # default is TRUE for every verb
  retiredOn = "2026-07-27";          # required when enable = false
  executes  = "pangea bulk apply -> OpenTofu apply against S3 state";
  reason    = "…";                   # optional extra WHY prose
};
```

A retired verb's app **still exists and still resolves** — `nix run .#apply`
is a refusal derived from the declaration's own fields, naming the
declare-and-observe replacement path, exit 1. **The flag resolves at EVAL
time**: the real program was never built, so no runtime flag, env var or
argument can satisfy it.

| Builder | Retireable verbs |
|---|---|
| `infra/pangea-infra.nix` (+ `-flake`) | validate · plan · apply · destroy · init · drift · test · regen |
| `infra/fleet-pangea-infra.nix` (+ `-flake`) | the above + flow-list + every generated `flow-<name>` |
| `infra/constellation-platform-infra.nix` | (threads through to fleet-pangea-infra) |
| `infra/gated-pangea-workspace.nix` (→ `infra-sdlc.nix`) | plan · apply · destroy · show · status · migrate · list |

**Retire at the SOURCE app set, not the returned one.** `gated-pangea-workspace`
applies retirement to the base workspace apps *before* `deploy` (and
`infra-sdlc`'s `cycle` / `cycle-destroy`) splice `base.<verb>.program`.
Retiring only the returned `apply` would leave those compositions running the
real cloud mutation behind a top-level app that reads as refusing — a guard
that is green and checks nothing.

That paragraph was a *claim* until 2026-07-28: the 20 tests then in
`lib/infra/tests/mutating-verbs-test.nix` covered `retireApps` only in
isolation, so removing `base = retire rawBase` would have kept every one of
them green. Ten `composition-*` tests now drive the two real composition
layers end to end and assert the retirement reaches `deploy` and `cycle` —
**with a control** asserting the OPEN build still splices the real apply, so
the negatives are falsifiable rather than an artifact of a harness that sees
nothing. Both directions verified red (the property break: 24/30; the harness
break: 26/30 with both controls red). Detail in the test file's header.

**The one builder without a surface: `infra/pangea-arch-workspace.nix`** (the
17 `pangea-architectures/workspaces/<name>/` flakes). Its omission is
*unresolved*, not a considered exemption, and the "cannot gate anything"
reading is **refuted by the code**: its `deploy`/`apply`/`destroy` ARE nix
apps (`writeShellApplication` → `bundle exec pangea apply <template>`), all
17 consumers take the full default verb list, and `nix run .#deploy` is the
*only documented* execution path for 14 of them (`platforms/*.yaml` headers,
`pangea-architectures/docs/workspace-sdlc.md` §"single-workspace verbs go
direct"). `cordel platform-cycle` shells that same app. A surface here would
gate real paths.

What it would NOT gate — recorded so the surface is never mistaken for
complete coverage: the repo-root fleet flow (`fleet/src/commands/pangea.rs`
`Command::new("pangea")`, reached via `flow-deploy-*`), `cordel cluster-up`
(`cordel-callers/src/pangea_invoke.rs` spawns `pangea` directly), workspaces
regenerated by `arch-synthesizer/src/workspace_helpers.rs` (emits its own
inline `bundle exec pangea apply` flake, no substrate import), and the
builder's own `devShell` — though that last one is **not** a distinguishing
reason to withhold the surface, since `pangea-infra.nix` and
`fleet-pangea-infra.nix` both ship a devShell carrying `opentofu` + a
`pangea` wrapper and carry `mutatingVerbs` anyway.

**Higher-leverage gap found alongside it:** `pangea-architectures/flake.nix`
consumes `fleet-pangea-infra.nix` — which *already has* the surface — and
passes **no `mutatingVerbs` at all**, including for `pleme-io-opensource`,
the one workspace with a live (`suspend: false`) `InfrastructureTemplate` CR
on rio. That is a hand-run flow racing an active reconciler with the gate
already built and simply unused. Fleet-wide, only `pleme-infra/flake.nix`
declares `mutatingVerbs` today.

**Sibling of `gated-pangea-workspace`'s test gate, not a duplicate.** A gate
says *"you may run this, once the tests pass"*; retirement says *"this is not
a human's to run at all"*. A gate cannot express retirement (a passing suite
would unlock the very apply the platform forbids) and retirement cannot
express a gate. Neither subsumes the other, so they **compose** through one
declaration rather than shipping two mechanisms.

**Backward compatibility is mechanical, not asserted.** Every verb defaults to
`enable = true`, and `retireApps` on an all-enabled declaration returns the
app set **by identity** without forcing `pkgs` at all —
`lib/infra/tests/mutating-verbs-test.nix` proves it by passing
`pkgs = throw "…"`. Wired as `checks.<system>.mutating-verbs` (30 tests);
verified red against five deliberate breaks — three for the isolation
contract, two for the composition block above.

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
