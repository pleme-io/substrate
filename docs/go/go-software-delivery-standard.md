# Go Software Delivery Standard (GSDS)

> A single, coherent standard for how pleme-io authors, builds, documents,
> versions, secures, and ships Go software.

## The boundary-of-communication thesis

A standard is **a boundary of communication between creators and users**. A repo
that follows the GSDS is *reliably navigable by anyone who follows it*: a
follower who knows one fact (the repo name) can derive every other fact (import
path, package name, config prefix, binary name, where main lives) with **zero
lookups**, because every mapping is total, bijective, and written once. There
are **no ideological gaps** — for every question a navigator can ask ("where
does this binary start?", "which config file is winning?", "what happens when I
change this field on a running daemon?", "is `vX.Y.Z` out?"), the standard
supplies a single, mechanically-checkable answer.

Two laws hold the standard together and recur in nearly every rule:

- **Ruthless standardization / zero duplication.** Anything repeatable becomes a
  macro or a library. The eight mandated runtime libraries —
  [`shikumi-go`](https://github.com/pleme-io/shikumi-go) (config),
  [`errors-go`](https://github.com/pleme-io/errors-go) (typed errors),
  [`logging-go`](https://github.com/pleme-io/logging-go) (structured logging),
  [`cli-go`](https://github.com/pleme-io/cli-go) (CLI app/auth/validators),
  [`lifecycle-go`](https://github.com/pleme-io/lifecycle-go)
  (health/shutdown/runloop), [`todoku-go`](https://github.com/pleme-io/todoku-go)
  (HTTP client/auth/retry), [`shigoto-go`](https://github.com/pleme-io/shigoto-go)
  (job/DAG/scheduler), and
  [`pleme-actions-shared-go`](https://github.com/pleme-io/pleme-actions-shared-go)
  (GitHub-Action I/O) — *are* the macros. A local re-implementation of any of
  their concerns is "the second copy" the standard forbids.
- **No shell.** Every non-trivial tool, lint, generator, build, and release step
  is built in Rust + tatara-lisp + Nix + YAML. The substrate `build/go/*` Nix
  helpers are the build macros; the `forge` / `caixa-validate` Rust binaries are
  the gates. CI is a thin shim that calls them.

These laws make the standard *enforceable*: nearly every rule below is checked at
Nix-eval time, by a Rust analyzer wired into the substrate `check-all` app, by
`golangci-lint`/`go vet`/`staticcheck`, or by the delivery **finite state
machine** (FSM) gate that refuses to advance an artifact past a state until the
relevant checks are green.

## How to use this document

- **Per-dimension rule sections.** The standard is organized along the
  navigation dimensions a follower traverses: repo layout, naming, CLI UX,
  configuration, observability, errors, lifecycle/health, networking,
  concurrency/jobs, documentation, versioning, testing, security, and UI/UX
  (terminal look-and-feel). Each rule is rendered as:

  > **ID** — the rule. *Why:* the rationale. *Enforcement:* the gate that makes
  > it hold. *Demonstrated by:* the canonical example / live evidence.

- **IDs are normalized and stable.** Each dimension owns one ID prefix
  (`LAYOUT-`, `NAME-`, `CLI-`, `CFG-`, `OBS-`, `ERR-`, `LIFE-`, `NET-`, `JOB-`,
  `DOC-`, `VER-`, `TEST-`, `SEC-`); FSM identities use `FSM-MODULE-`,
  `FSM-RELEASE-`, `FSM-IMAGE-`, `FSM-ACTION-`. The same IDs appear in the
  machine-readable [`rules-registry.yaml`](./rules-registry.yaml). Cross-
  references in this document resolve to these IDs.

- **The Delivery FSM Type System** (final section) is the keystone: it encodes
  *delivery itself* as four typed, pure, table-driven state machines — one per
  artifact class (module, release, image, action) — sharing the
  [`shigoto-go`](https://github.com/pleme-io/shigoto-go) `Advance`/`Gate`/
  `ErrIllegalTransition` idiom. "Tests green is an FSM gate," "no unsigned push,"
  and "tag = published" are not slogans; they are unreachable-by-construction
  invariants of these machines.

- **The canonical example.** Throughout, "the canonical example" is the
  reference repo set the standard ships and tests against (a `widget-go` library,
  a `widgetctl` CLI, a `widgetd` service / `widgetkit` monorepo, a
  `notify-slack-action` action). It passes every rule and FSM gate and is the
  acceptance fixture for the standard's own tooling. These repos are **normative
  and MUST exist** (see [DOC-11](#dimension-documentation-and-discoverability-doc));
  `caixa-validate --meta` resolves every `Demonstrated by:` reference and fails
  the build if any is a dead link.

- **Reading order / role-based on-ramp.** A new engineer does not read this
  document linearly. Read in this order by role (this is normative onboarding
  guidance, enforced as a `DOC` rule, [DOC-13](#dimension-documentation-and-discoverability-doc)):
  1. **Navigate / build / run** (you just cloned a repo): the
     [Glossary](#glossary), the [Identity-derivation table](#identity-derivation-table),
     the [Concern → library → symbol map](#concern--library--symbol-map), the
     [Day-one setup](#day-one-setup), the [Run & debug recipes](#run--debug-recipes),
     then `LAYOUT`, `NAME`, `CLI`.
  2. **Author** (you are adding Go): `CFG`, `OBS`, `ERR`, `LIFE`, `NET`, `JOB`,
     and the [Extending / scaffolding](#extending--scaffolding) section.
  3. **Ship** (you are cutting a release): `VER`, `TEST`, `SEC`, the
     [Delivery FSM Type System](#delivery-fsm-type-system), the
     [FSM status / observability](#fsm-status--observability) section, and the
     standalone [`go-delivery-fsms.md`](./go-delivery-fsms.md).

---

## Glossary

Every load-bearing proper noun the standard uses, defined once, with its owning
repo/skill. This is navigation infrastructure; its presence is enforced by
[DOC-12](#dimension-documentation-and-discoverability-doc).

| Term | Definition | Owner / where it lives |
|---|---|---|
| **caixa** | The canonical pleme-io SDLC primitive — one repo's typed lifecycle declaration. A caixa has a `:kind` and `:ecosystem` and is the single source of truth from which all generated artifacts derive. | `pleme-io/caixa`; authored via the `caixa-author` skill |
| **`caixa.lisp`** | The top-level `(defcaixa <name> :kind … :ecosystem … …)` tatara-lisp file every repo carries ([LAYOUT-09](#dimension-repo-layout-and-module-layout)). The contract a follower reads to know what a repo IS before reading any Go. | repo root |
| **`defcaixa`** | The compile-time-checked tatara-lisp macro that authors a `caixa.lisp`. Invalid kind/ecosystem combinations are macro-expansion (Rust-side) errors. | `tatara-lisp` |
| **`caixa-validate`** | The Rust gate binary that lints a repo against the GSDS rules. Installed via `nix develop` (on `PATH` in the devShell) and invoked by `nix run .#check-all`. Subcommand `caixa-validate --meta` checks the standard's own meta-invariants (canonical-example existence, registry/`.md` ID parity). | `pleme-io/caixa`; ships in the substrate Go devShell |
| **`forge`** | The Rust delivery binary that drives the four delivery FSMs (`forge tool {bump,release,upgrade,status}`, `forge image-{release,sign,sbom,scan,provenance,rescan}`, `forge action-release`). Installed via the substrate flake (`nix run .#release`/`.#bump`/etc.) and present on the devShell `PATH`. | `pleme-io/forge` |
| **`forge tool status`** | The navigator-readable FSM state surface: prints the current FSM state of an artifact, the last gate verdict, and the owning rule of any refusal ([FSM-OBS](#fsm-status--observability)). | `pleme-io/forge` |
| **`pleme-doc-gen`** | The generator that re-emits the generated surface of a repo (`flake.nix`, CI shim, nix module trio, CHANGELOG wiring) from `caixa.lisp`: `pleme-doc-gen caixa --source caixa.lisp --out .`. | `pleme-io/pleme-doc-gen` |
| **Pillar** | One of the pleme-io platform's architectural pillars; a runtime lib's README states which Pillar / Rust sibling it mirrors. | `pleme-io/theory` |
| **Rust sibling** | The Rust crate of the same concept a `-go` lib mirrors (e.g. `shikumi` is the Rust sibling of `shikumi-go`). The `-go` suffix prevents the collision ([LAYOUT-01](#dimension-repo-layout-and-module-layout)). | per-concept repo |
| **Biblioteca** | Caixa kind: an importable Go library, no `main`, public API from the module-root package. | `caixa.lisp` `:kind` |
| **Binario** | Caixa kind: a one-shot CLI binary. | `caixa.lisp` `:kind` |
| **Servico** | Caixa kind: a long-running daemon/service. | `caixa.lisp` `:kind` |
| **Supervisor** | Caixa kind: a process supervisor composing Servicos. | `caixa.lisp` `:kind` |
| **Aplicacao** | Caixa kind: a typed mesh of Servicos. | `caixa.lisp` `:kind`; `aplicacao-compose` skill |
| **tatara-lisp** | The pleme-io declarative authoring language; expands to typed Rust IR. `caixa.lisp` is written in it. | `pleme-io/tatara` |
| **`mkGoDevShell`** | The substrate Nix function (`lib/build/go/devenv.nix`) that produces `devShells.default` with the exact pinned toolchain CI uses (`go gopls gotools delve gofumpt staticcheck govulncheck forge caixa-validate`). `nix develop` enters it. | `substrate/lib/build/go/devenv.nix` |
| **`check-all`** | The substrate flake app (`nix run .#check-all`) that runs the full local gate suite (gofumpt, vet, staticcheck, govulncheck, the GSDS analyzers, race tests, coverage). CI invokes it; it is the local reproduction of every CI gate. | substrate flake `apps.check-all` |
| **`lock-platform`** | The substrate flake app (`nix run .#lock-platform`) that pins the platform/toolchain inputs the build resolves against. | substrate flake `apps.lock-platform` |
| **`shigoto-go` / `shigoto`** | The job/DAG/scheduler library (Go) and its Rust sibling. The four delivery FSMs share its `Advance`/`Gate`/`ErrIllegalTransition` idiom. | `pleme-io/shigoto-go` |
| **shikumi-go, errors-go, logging-go, cli-go, lifecycle-go, todoku-go, pleme-actions-shared-go** | The eight mandated runtime libraries (config, typed errors, logging, CLI, lifecycle/health, HTTP client, jobs, action I/O). See the [Concern → library → symbol map](#concern--library--symbol-map). | `pleme-io/<name>` |
| **tameshi / sekiban / inshou / provas** | The attestation ecosystem: tameshi computes the BLAKE3 Merkle provenance tree; sekiban is the K8s admission webhook; inshou gates Nix rebuilds; together they fail-close on a broken integrity chain ([SEC-12](#dimension-security-and-supply-chain-sec)). | `pleme-io/tameshi` et al.; `attestation` skill |
| **borealis** | THE pleme-io terminal design system — one `Theme` token bundle, one render verb (`borealis.Render`), and one producer per charm-stack themeable surface. Every `*-go` primitive renders its user-facing output through it so two fleet tools cannot drift in how they look. The brand is the Nord *Aurora* palette (Polar Night surfaces, Frost primary, Aurora semantic), hardcoded today and ishou-generation-bound as target state. The whole UI/UX dimension ([UI-01](#dimension-uiux-look-and-feel-ui)..[UI-12](#dimension-uiux-look-and-feel-ui)) is rooted here. | `pleme-io/borealis` |
| **comp / style / fangx / huhx / bubblesx / tui** | borealis's render surfaces. `comp` is the render-to-string typed-value set (`Header`/`Badge`/`Glyph`/`Rule`/`StatusList`/`KV`/`Table`); `style` derives Lip Gloss styles from a `Theme`. The three GATED LEAVES map a `Theme` onto each charm-stack themeable surface: `fangx` (CLI help/errors via fang), `huhx` (huh interactive forms), `bubblesx` (bubbles widgets). `tui` carries live `tea.Model` components. | `pleme-io/borealis/{comp,style,fangx,huhx,bubblesx,tui}` |

## Identity-derivation table

The literal realization of the thesis: from **one fact** (the repo name `N`) a
navigator derives every other identity fact with **zero lookups**. This table is
normative; [LAYOUT-11](#dimension-repo-layout-and-module-layout) and
[NAME-01..13](#dimension-naming-name) enforce each cell, and
[DOC-14](#dimension-documentation-and-discoverability-doc) asserts the table is
present and that `caixa-validate` derives identity from exactly these rules.

Let `N` = the GitHub repo slug (kebab-case, e.g. `widgetd`, `cli-go`). Let
`P` = `ToUpper(ReplaceAll(N,"-","_"))` (e.g. `WIDGETD`, `CLI_GO`).

| Question a navigator asks | Derivation from `N` | Owning rule |
|---|---|---|
| Module / import path | `github.com/pleme-io/N` (`/vMAJOR` appended for major ≥ 2) | [LAYOUT-01](#dimension-repo-layout-and-module-layout), [VER-02](#dimension-versioning-and-compatibility-ver) |
| Root package name (Biblioteca) | `N` with `-` collapsed and `-go` stripped (`shikumi-go` → `shikumi`) | [NAME-02](#dimension-naming-name) |
| Where `main` lives (single-binary) | `cmd/N/main.go` | [LAYOUT-03](#dimension-repo-layout-and-module-layout), [NAME-11](#dimension-naming-name) |
| Where `main` lives (multi-binary) | `cmd/<bin>/main.go` for each `<bin>` in `caixa.lisp` `:binaries` | [LAYOUT-08](#dimension-repo-layout-and-module-layout), [VER-11a](#dimension-versioning-and-compatibility-ver) |
| Binary name | `N` (single) or each declared `<bin>` (multi); `meta.mainProgram` | [NAME-05](#dimension-naming-name) |
| Config env prefix | `P_` (e.g. `WIDGETD_`) | [NAME-07](#dimension-naming-name) |
| Config-path override env var | `P_CONFIG` (e.g. `WIDGETD_CONFIG`) | [NAME-08](#dimension-naming-name), [CFG-03](#dimension-configuration-cfg) |
| `shikumi.Load`/`New` prefix arg | `P_` / `N` | [NAME-07](#dimension-naming-name), [NAME-08](#dimension-naming-name) |
| README H1 | `# N` | [LAYOUT-04](#dimension-repo-layout-and-module-layout), [DOC-05](#dimension-documentation-and-discoverability-doc) |
| flake `name`/`toolName` | `N` | [LAYOUT-06](#dimension-repo-layout-and-module-layout), [NAME-05](#dimension-naming-name) |
| `caixa.lisp` `<name>`/`:package.name` | `N` | [LAYOUT-09](#dimension-repo-layout-and-module-layout), [LAYOUT-11](#dimension-repo-layout-and-module-layout) |
| `--version` injection target | `main.version` (default) or `caixa.lisp` `:version-package` | [CLI-04](#dimension-cli-ux-cli), [VER-04](#dimension-versioning-and-compatibility-ver), [VER-04a](#dimension-versioning-and-compatibility-ver) |
| Action repo I/O env | `INPUT_<UPPER_UNDERSCORE(input)>` / `GITHUB_OUTPUT` | [NAME-12](#dimension-naming-name) |
| Release tag | `vX.Y.Z` (single-module) or `<modRoot>/vX.Y.Z` (multi-module) | [VER-03](#dimension-versioning-and-compatibility-ver), [VER-11b](#dimension-versioning-and-compatibility-ver) |
| Canonical service ports | health/readiness `:8081` `/healthz` `/readyz`; metrics `/metrics` | [LIFE-05](#dimension-lifecycle-and-health-life), [NET-10](#dimension-networking-net), [LIFE-15](#dimension-lifecycle-and-health-life) |

## Concern → library → symbol map

The navigator's "where is X handled?" answered in one lookup. Each mandated
concern maps to exactly one library, its entry symbol, and where a repo
constructs it. Enforced present by
[DOC-08](#dimension-documentation-and-discoverability-doc)/[DOC-15](#dimension-documentation-and-discoverability-doc).

| Concern | Library | Entry symbol | Constructed in | Owning rule |
|---|---|---|---|---|
| Config discovery + load | `shikumi-go` | `shikumi.LoadStore[T]` / `shikumi.New` | `main`/`bootstrap.Config` | [CFG-01](#dimension-configuration-cfg)..[CFG-15](#dimension-configuration-cfg) |
| Typed errors + severity + codes | `errors-go` | `errs.New` / `errs.Wrap` / `errs.ExitCode` | call sites; codes manifest | [ERR-01](#dimension-errors-err)..[ERR-12](#dimension-errors-err) |
| Structured logging | `logging-go` | `logging.New` | `bootstrap.Config` (from validated config) | [OBS-01](#dimension-observability-obs)..[OBS-14](#dimension-observability-obs) |
| CLI app / commands / validators | `cli-go` | `cli.NewApp` / `cli.Command` | `cmd/<bin>/main.go` | [CLI-01](#dimension-cli-ux-cli)..[CLI-13](#dimension-cli-ux-cli) |
| Health / shutdown / run-loops | `lifecycle-go` | `lifecycle.SignalContext` / `.NewShutdown` / `.Registry` / `.RunLoop` | service `main` | [LIFE-01](#dimension-lifecycle-and-health-life)..[LIFE-15](#dimension-lifecycle-and-health-life) |
| HTTP client / auth / retry / timeout | `todoku-go` | `todoku.New` | `main`/factory (struct field) | [NET-01](#dimension-networking-net)..[NET-13](#dimension-networking-net) |
| Jobs / DAG / scheduler / gates | `shigoto-go` | `shigoto.NewScheduler` / `shigoto.Advance` / `shigoto.Gate` | service `main`; the delivery FSMs | [JOB-01](#dimension-concurrency-and-jobs-job)..[JOB-14](#dimension-concurrency-and-jobs-job) |
| GitHub-Action I/O + bootstrap | `pleme-actions-shared-go` | `actions.ParseInputs` / `actions.SetOutput` / `bootstrap.Config[T]` | action `main` | [NAME-12](#dimension-naming-name), [CFG-14](#dimension-configuration-cfg) |
| Terminal look-and-feel / theming / rendering | `borealis` | `borealis.Theme` / `borealis.Render` / `borealis.FromConfig` (+ `comp` / `fangx` / `huhx` / `bubblesx` / `tui`) | `main`/`bootstrap.Config` (theme resolved once) | [UI-01](#dimension-uiux-look-and-feel-ui)..[UI-12](#dimension-uiux-look-and-feel-ui) |

### Inter-library composition graph

The libraries compose in a fixed dependency/wiring order (normative; enforced by
[DOC-16](#dimension-documentation-and-discoverability-doc)/[LIFE-12](#dimension-lifecycle-and-health-life)).
The arrow `A → B` reads "A may import B; B never imports A":

```
errors-go        (leaf — depends on no other mandated lib)
  ▲   ▲   ▲   ▲
  │   │   │   └── todoku-go      (errors-go)
  │   │   └────── shigoto-go     (errors-go, logging-go)
  │   └────────── lifecycle-go   (errors-go, logging-go)
  └────────────── logging-go     (errors-go)
shikumi-go        (errors-go)                         ← config; no logger dep
cli-go            (errors-go, logging-go, lifecycle-go)
pleme-actions-shared-go  (composes shikumi-go + errors-go + logging-go
                          + lifecycle-go in bootstrap.Config — the wiring root)
```

Canonical wiring order in a service `main` (the eight-phase startup of
[LIFE-12](#dimension-lifecycle-and-health-life)): config (shikumi) → logger
(logging, built from validated config) → `SignalContext` (lifecycle) →
`Shutdown` (lifecycle) → dependencies (todoku clients, shigoto scheduler) →
health server (lifecycle Registry) → traffic + loops → `<-ctx.Done()` → `Run`.

## Day-one setup

The answer to "I just cloned this repo — what do I run first?" Enforced as a
`DOC` rule ([DOC-03a](#dimension-documentation-and-discoverability-doc)): every
repo README `## Install` and this section state the same day-one path.

1. **Enter the toolchain.** `nix develop` — this enters `devShells.default`
   (built by `mkGoDevShell`) and puts the *exact pinned CI toolchain* on your
   `PATH`: `go gopls gotools delve gofumpt staticcheck govulncheck forge
   caixa-validate`. You never install Go or any gate by hand; the devShell is the
   one source ([LIFE-DEV](#day-one-setup), [TEST-07](#dimension-testing-and-quality-test)).
2. **Validate.** `nix run .#check-all` — runs the full gate suite locally,
   identical to CI (gofumpt, vet, staticcheck, govulncheck, the GSDS analyzers,
   `-race` tests, coverage). A green `check-all` is the precondition for every
   FSM advance.
3. **Inspect delivery state.** `forge tool status` — prints the artifact's
   current FSM state, the last gate verdict, and (if blocked) the owning rule
   ([FSM-OBS](#fsm-status--observability)).
4. **Read identity.** `cat caixa.lisp` tells you the repo's `:kind` and
   `:ecosystem`; the [Identity-derivation table](#identity-derivation-table)
   tells you everything else from the repo name.

`forge` and `caixa-validate` are **not** installed globally and **not** fetched
ad hoc — they are provisioned solely by the devShell and the substrate flake apps
(`nix run .#release`, `.#bump`, `.#check-all`). If a binary is "not found," you
are outside `nix develop`.

## Run & debug recipes

The answer to "how do I run this on my laptop and hit it?" and "how do I triage a
red gate?" Enforced by [LIFE-16](#dimension-lifecycle-and-health-life) (README
`## Usage` run recipe) and [DOC-17](#dimension-documentation-and-discoverability-doc)
(the gate-triage table).

### Running locally

- **Biblioteca:** there is nothing to run; consume it (`go get
  github.com/pleme-io/N@vX.Y.Z`) or run its examples (`go test -run Example ./...`).
- **Binario (CLI):** `nix run .#N -- <subcommand> [flags]`. `nix run .#N --
  --help` lists every command; `nix run .#N -- version` prints the injected
  version.
- **Servico / daemon:** `nix run .#N -- serve` boots the daemon. Minimal boot
  needs only the config the schema marks required ([CFG-13](#dimension-configuration-cfg));
  override the config path with `N_CONFIG=/path/to/config.yaml` or any field via
  `N_<FIELD>` env ([NAME-07](#dimension-naming-name)). Health is on `:8081`:
  `curl localhost:8081/healthz` (liveness), `curl localhost:8081/readyz`
  (readiness), `curl localhost:8081/metrics` ([LIFE-05](#dimension-lifecycle-and-health-life)).

### Debugging / triaging a failed gate

| Red gate family | Local reproduce | How to read it / fix |
|---|---|---|
| gofumpt | `nix develop -c gofumpt -l .` | each listed file is unformatted; `gofumpt -w .` |
| go vet / staticcheck | `nix develop -c go vet ./...` ; `nix develop -c staticcheck ./...` | non-empty output is the failure; address each diagnostic |
| forbidigo / depguard / GSDS analyzers | `nix run .#check-all` (see the named analyzer in output) | the analyzer names the banned construct + the owning rule; use the sanctioned library instead |
| `caixa-validate` (layout/identity/kind) | `nix develop -c caixa-validate` | prints the failing assertion + owning `LAYOUT-*`/`NAME-*` rule |
| `caixa-validate --meta` | `nix develop -c caixa-validate --meta` | canonical-example / registry-parity meta-checks |
| race / coverage tests | `nix run .#check-all` | `-race` data-race reports; coverage below `coverage_floor` |
| govulncheck | `nix develop -c govulncheck ./...` | only call-graph-reachable vulns fail; bump the dep ([SEC-10](#dimension-security-and-supply-chain-sec)) |
| Delivery FSM gate refusal | `forge tool status` (then the gate-verdict table in [FSM status](#fsm-status--observability)) | the refusal names the gate, the owning rule, and the fix |

Attaching a debugger to a `Servico`: `nix develop -c dlv exec
$(nix build .#N --print-out-paths)/bin/N -- serve`, or `dlv attach <pid>` against
a running instance. `delve`/`dlv` ships in the devShell ([TEST-07](#dimension-testing-and-quality-test)).

## Extending / scaffolding

The answer to "how do I add to this?" Each act has a concrete generator
invocation; hand-editing the generated surface is drift
([LAYOUT-07](#dimension-repo-layout-and-module-layout)/[DOC-18](#dimension-documentation-and-discoverability-doc)).

| Act | Procedure |
|---|---|
| Create a new GSDS-conformant repo | `pleme-doc-gen scaffold --kind <Biblioteca\|Binario\|Servico> --name N --out .` then `nix run .#check-all` (see the `caixa-mass-generation` skill) |
| Add a second binary (single→multi) | edit `caixa.lisp` `:ecosystem "go-monorepo"` + add `:binaries [ … ]`, run `pleme-doc-gen caixa --source caixa.lisp --out .`, add `cmd/<bin>/main.go` ([LAYOUT-08](#dimension-repo-layout-and-module-layout)/[VER-11a](#dimension-versioning-and-compatibility-ver)) |
| Add a subcommand | add a `cli.Command{...}` and register via `app.Add(...)` ([CLI-01](#dimension-cli-ux-cli)/[CLI-02](#dimension-cli-ux-cli)); renaming/removing one is a breaking change ([CLI-13](#dimension-cli-ux-cli)) |
| Add a config field | add the tagged struct field + `// reload:` marker ([CFG-12](#dimension-configuration-cfg)); a breaking schema change bumps `schema_version` + ships a migration ([CFG-15](#dimension-configuration-cfg)); re-run `gen-config-docs` ([CFG-13](#dimension-configuration-cfg)) |
| Add a job to the DAG | add a `shigoto.Job` + wire upstreams; `dag.Validate()` fatally at startup ([JOB-04](#dimension-concurrency-and-jobs-job)/[LIFE-10](#dimension-lifecycle-and-health-life)) |
| Promote `internal/` → `pkg/` | move the package to `pkg/`, which signals a supported API ([LAYOUT-03](#dimension-repo-layout-and-module-layout)); from v1+ this is now a frozen surface ([VER-05](#dimension-versioning-and-compatibility-ver)) |
| Consume a breaking lib upgrade | `forge tool upgrade --dep github.com/pleme-io/<lib> --to vN` ([VER-13](#dimension-versioning-and-compatibility-ver)); fleet ordering root→leaf ([VER-15](#dimension-versioning-and-compatibility-ver)) |
| Regenerate the generated surface | `pleme-doc-gen caixa --source caixa.lisp --out .` (the edit→regenerate loop, [DOC-18](#dimension-documentation-and-discoverability-doc)) |

### Authored vs generated files

A navigator must know which files are safe to hand-edit. Every generated file
carries the sentinel header `# GENERATED BY pleme-doc-gen — DO NOT EDIT (edit
caixa.lisp and regenerate)`; enforced by
[DOC-18](#dimension-documentation-and-discoverability-doc).

| Authored (edit freely) | Generated (edit `caixa.lisp` + regenerate) |
|---|---|
| `internal/**`, `pkg/**`, `cmd/<bin>/main.go` (your Go) | `flake.nix` |
| `*_test.go`, `testdata/**` | `.github/workflows/auto-release.yml` |
| `README.md` prose body | README "Built on" block ([DOC-08](#dimension-documentation-and-discoverability-doc)) |
| `caixa.lisp` (the source of truth) | the nix module trio, CHANGELOG release wiring |
| `CHANGELOG.md` `## [Unreleased]` notes | `config.schema.json`, `docs/config.md` ([CFG-13](#dimension-configuration-cfg)) |

## Tunables & defaults

Every threshold the standard names, its default, and whether it is per-repo
overridable. Enforced present by [DOC-19](#dimension-documentation-and-discoverability-doc).

| Tunable | Default | Per-repo overridable? | Where |
|---|---|---|---|
| Test coverage floor | `80%` | yes | `caixa.lisp` `:coverage-floor` (typed) ([TEST-03](#dimension-testing-and-quality-test)) |
| CI `run:` glue budget | ≤ 3 lines | no (fleet-fixed) | [LAYOUT-07](#dimension-repo-layout-and-module-layout) |
| `pleme-doc-gen` navigate-test "above the fold" N | 5 | no | [DOC-09](#dimension-documentation-and-discoverability-doc) |
| Shutdown grace vs timeout | `grace > shutdown_timeout` | yes (typed Duration) | [LIFE-04](#dimension-lifecycle-and-health-life) |
| CVE gate `failOn` | `["HIGH"]` (FIPS/FedRAMP-High: also subsumed; baseline floor `HIGH`) | yes (must not loosen below `HIGH`) | [SEC-05](#dimension-security-and-supply-chain-sec) |
| Readiness timeout (FSM-IMAGE) | `300s` | yes (typed, lower-bounded Duration) | [SEC-13](#dimension-security-and-supply-chain-sec), [FSM-IMAGE](#image-delivery-fsm-image) |
| Proxy poll deadline / retries (FSM-MODULE) | `600s` / `30` polls | yes (typed) | [VER-16](#dimension-versioning-and-compatibility-ver), [FSM-MODULE](#module-delivery-fsm-module) |
| TLS minimum version | TLS 1.2 (servers + todoku clients) | yes (must not lower) | [NET-14](#dimension-networking-net) |
| Fuzz time per target | `30s` | yes | [TEST-05](#dimension-testing-and-quality-test) |

## Annotation / escape-hatch catalog

Every `//gsds:*`, `//nolint:*`, `//shigoto:*`, and `//go:build` annotation the
standard recognizes, its meaning, and the rule it suppresses. A navigator reading
an annotated line resolves it here without grepping the document. Enforced
present and complete by [DOC-20](#dimension-documentation-and-discoverability-doc);
`caixa-validate` rejects any `//gsds:`/`//shigoto:` annotation NOT in this table.

| Annotation | Meaning | Suppresses |
|---|---|---|
| `//gsds:reclassify` | justifies a wrap that lowers a statically-known cause severity | [ERR-04](#dimension-errors-err) |
| `//gsds:ignore` | justifies a deliberately-discarded error `_ = <err>` | [ERR-08](#dimension-errors-err) |
| `//gsds:invariant` | justifies a `panic(` in a Biblioteca as an unreachable invariant | [ERR-05](#dimension-errors-err) |
| `//gsds:example-required` | marks an exported symbol that MUST have a runnable `Example` | [DOC-04](#dimension-documentation-and-discoverability-doc) |
| `//gsds:multi-major-intentional` | accepts two majors of one internal submodule in one repo | [VER-14](#dimension-versioning-and-compatibility-ver) |
| `//nolint:forbidigo // invariant` | allowlists a `panic/os.Exit/log.Fatal` at an enforced invariant site | [OBS-10](#dimension-observability-obs) |
| `//nolint:gsds-net-retry` | allowlists a sanctioned `time.Sleep` in a network/IO loop | [NET-02](#dimension-networking-net) |
| `//shigoto:exempt-leaf` | allowlists a bare `go ` / errgroup in a leaf | [JOB-01](#dimension-concurrency-and-jobs-job) |
| `// non-fatal` | declares a `RunLoop` whose errors are intentionally non-fatal | [LIFE-09](#dimension-lifecycle-and-health-life) |
| `// reload: hot\|warm\|cold` | declares a config field's reload class | [CFG-12](#dimension-configuration-cfg) |
| `//lint:ignore <check> <reason>` | a reasoned staticcheck suppression (reason mandatory) | [TEST-06](#dimension-testing-and-quality-test) |
| `//go:build integration` | gates a network-touching test out of the unit pass | [TEST-09](#dimension-testing-and-quality-test) |

---

## Dimension: Repo Layout and Module (LAYOUT)

**LAYOUT-01** — Every pleme-io Go repo declares its module path as exactly
`module github.com/pleme-io/<repo-name>` in a single top-level `go.mod`, where
`<repo-name>` is byte-identical to the GitHub repo slug (kebab-case, lower-case,
no `/v2` until a v2 major actually ships, see [VER-02](#dimension-versioning-and-compatibility-ver)).
Runtime-library repos keep the `-go` suffix distinguishing them from their Rust
siblings (`shikumi-go`, `errors-go`, `logging-go`, `cli-go`, `lifecycle-go`,
`todoku-go`, `shigoto-go`, `pleme-actions-shared-go`). No vanity import paths, no
nested `go.mod` except as mandated by [LAYOUT-08](#dimension-repo-layout-and-module-layout).
*Why:* module path = repository identity; a follower who knows the repo name
knows the import path with zero lookup. The `-go` suffix prevents collision with
the Rust crate of the same concept (`shikumi` vs `shikumi-go`).
*Enforcement:* `caixa-validate` asserts `go.mod` line 1 equals
`module github.com/pleme-io/$(basename $PWD)` (suffix preserved); `go vet ./...`
and `mkGoLibraryCheck` (`build/go/library-check.nix`); GitHub-posture IaC owns
the slug, so slug/module drift is a reconcile error.
*Demonstrated by:* every runtime lib — `shikumi-go/go.mod` →
`module github.com/pleme-io/shikumi-go`, identically for the others.

**LAYOUT-02** — The `go` directive in `go.mod` MUST pin the MINOR version only
(`go 1.25`), never a patch (`go 1.25.4`) and never a version ahead of the
substrate from-source `goToolchain` (`pkgs.go.version`). Bumping the minor is a
deliberate, fleet-wide coordinated change.
*Why:* a patch-ahead `go` directive fails deep inside `go mod download` with
`requires go >= X (running Y; GOTOOLCHAIN=local)`. Pinning the minor keeps every
repo buildable by the single substrate toolchain and makes the Go version a
one-line, greppable fleet fact. See also [VER-10](#dimension-versioning-and-compatibility-ver)
and [SEC-10](#dimension-security-and-supply-chain-sec).
*Enforcement:* eval-time `throw` in `lib/build/go/tool.nix` `goVersionAssert`
(reads the consuming `go.mod`'s `go` line via `builtins.compareVersions` against
`pkgs.go.version`, aborting the Nix evaluation before any build runs); same path
covers monorepo builds via `modRoot`.
*Demonstrated by:* all eight runtime libs declare `go 1.25`; introducing
`go 1.25.4` fails Nix evaluation with the `tool.nix` throw.

**LAYOUT-03** — Directory convention is strict and the placement test is
mechanical: `cmd/<binary>/main.go` holds ONLY `package main` entrypoints (one
subdir per shipped binary); `internal/` holds all packages NOT meant for
external import and is the DEFAULT home for application logic; `pkg/` holds ONLY
packages a downstream module is intended to import and MUST NOT exist in a repo
that exposes no importable surface. Runtime libraries
([LAYOUT-09](#dimension-repo-layout-and-module-layout) kind `Biblioteca`) expose
their public API from the module-root package (`package shikumi` in
`shikumi-go/shikumi.go`) and use neither `cmd/` nor `pkg/`.
*Why:* the three-bucket convention answers "where does code live?" with no
ambiguity; `pkg/`'s mere presence is a truthful signal that a supported API
exists; `internal/` as default prevents accidental public surface.
*Enforcement:* `caixa-validate` rejects a non-`main` package under `cmd/`, any
`func main()` outside `cmd/`, and an empty/import-less `pkg/`; `go build ./...`
enforces the compiler-level `internal/` boundary; `mkGoLibraryCheck` compiling
`./...` confirms the root-package public API of `Biblioteca` repos.
*Demonstrated by:* runtime libs have no `cmd/`/`internal/`/`pkg/` and expose
their API from `shikumi.go`/`errors.go`; the single-binary example places its
sole entrypoint at `cmd/<name>/main.go`, logic under `internal/`, no `pkg/`.

**LAYOUT-04** — Every repo carries these REQUIRED top-level files in canonical
form: `go.mod` ([LAYOUT-01](#dimension-repo-layout-and-module-layout)/[LAYOUT-02](#dimension-repo-layout-and-module-layout));
`LICENSE` (see the licensing note below); `README.md` opening with the
`# <repo-name>` H1 and (for runtime libs) a one-line statement of which pleme-io
Pillar / Rust sibling it mirrors; `CHANGELOG.md` in Keep-a-Changelog format with
an `## [Unreleased]` section at top; `flake.nix`
([LAYOUT-06](#dimension-repo-layout-and-module-layout)); and `caixa.lisp`
([LAYOUT-09](#dimension-repo-layout-and-module-layout)). No repo may omit any.
*Why:* a fixed top-level file set means a follower lands in any repo and finds
licensing, narrative, history, build, and identity in known filenames every
time — gaplessness at the filesystem root.
*Enforcement:* `caixa-validate` asserts each file exists non-empty, diffs
`LICENSE` against the canonical template, asserts the `README.md` H1 matches the
slug and the `## [Unreleased]` header is present. Cross-references the README
section rules in [DOC-05](#dimension-documentation-and-discoverability-doc) and
the changelog rules in [DOC-06](#dimension-documentation-and-discoverability-doc).
*Demonstrated by:* runtime libs ship `LICENSE` + `README.md`; the `:license`
field in the canonical `caixa.lisp` is the machine-readable mirror of the
`LICENSE` file, and the canonical Go example ships all six files.

> **Licensing (single source).** The fleet OSS license is **MIT**
> (`Copyright (c) <year> pleme-io`), governed by
> [LAYOUT-04](#dimension-repo-layout-and-module-layout). Both
> [LAYOUT-04](#dimension-repo-layout-and-module-layout) and
> [DOC-07](#dimension-documentation-and-discoverability-doc) require a present,
> OSI-recognized `LICENSE` file == MIT — pkg.go.dev renders full documentation
> for any recognized OSI license, MIT included, so there is no second license and
> no contradiction. The `caixa-validate` template and the `forge` license check
> both pin MIT; [DOC-07](#dimension-documentation-and-discoverability-doc) below
> states the MIT requirement directly (no Apache-2.0 wording remains).

**LAYOUT-05** — `.goreleaser.yml` is FORBIDDEN. Go's release is pull-model and
tag-only: a module/binary is "published" by pushing a semver git tag (`vX.Y.Z`),
after which `proxy.golang.org` fetches lazily on first `go get`. Cross-compiled
binary artifacts, when needed, are produced by the substrate Nix builders.
*Why:* GoReleaser would be a second, divergent release path competing with the
Nix/substrate one and reintroduce forbidden shell release logic; Go's proxy
model makes tag-push sufficient. This rule is the code-layer counterpart of the
pull-model FSM invariant [FSM-MODULE](#module-delivery-fsm-module).
*Enforcement:* `caixa-validate` rejects `.goreleaser.yml`/`.yaml`; release is
performed exclusively by `apps.release` (`build/go/library-flake.nix` →
`release-helpers.mkReleaseApp` with `language = "go"`), which tags and pushes
only; CI has no GoReleaser step.
*Demonstrated by:* none of the runtime libs contain a `.goreleaser.yml`; the
`library-flake.nix` header documents the tag-only publish, and the canonical
example releases via `nix run .#release`.

**LAYOUT-06** — `flake.nix` is REQUIRED and MUST consume the matching substrate
Go helper rather than hand-rolling `buildGoModule`: a `Biblioteca` imports
`substrate/lib/build/go/library-flake.nix` (passing `name`, `src = self`,
`repo = "pleme-io/<name>"`); a single-binary `Binario`/`Servico` imports
`build/go/tool-release-flake.nix` (passing `toolName`, `version`, `src = self`,
`vendorHash`); a multi-binary repo composes `build/go/monorepo.nix` +
`monorepo-binary.nix` per [LAYOUT-08](#dimension-repo-layout-and-module-layout).
The flake MUST set `inputs.substrate.inputs.nixpkgs.follows = "nixpkgs"` and pin
`nixpkgs` to the fleet ref. Hand-written `pkgs.buildGoModule` in a consumer flake
is forbidden.
*Why:* the substrate helpers ARE the build macros; consuming them gives every
repo the identical `packages`/`devShells`/`apps`/`overlays` surface, the
eval-time go.mod assert ([LAYOUT-02](#dimension-repo-layout-and-module-layout)),
flake hygiene, and the language-generic release surface for free.
*Enforcement:* `nix flake check` builds `packages.default`; `flake-hygiene.nix`
`enforceAll` fails evaluation if `nixpkgs` isn't followed; `caixa-validate`
lints for a `build/go/*` helper import and no raw `buildGoModule`; `repo-forge`
flags hand-rolled Go flakes as drift.
*Demonstrated by:* the canonical `Biblioteca` flake is the ~6-line
`(import "${substrate}/lib/build/go/library-flake.nix" {inherit nixpkgs;}) { name=…; src=self; repo="pleme-io/<name>"; }`;
the single-binary example uses the `tool-release-flake.nix` form.

**LAYOUT-07** — CI is a thin SHIM only. The repo ships exactly one workflow at
`.github/workflows/auto-release.yml` whose jobs do nothing but invoke the
substrate release apps (`nix run .#check-all`, `nix run .#lock-platform`, and on
tag `nix run .#release`/`.#bump`). Inline `run:` blocks are limited to ≤3 lines
of glue. NO bespoke shell test/build/release logic, no embedded `go test`/
`go build` outside the Nix `check-all` app. The workflow set is declared in
`caixa.lisp` `:workflows [ :auto-release ]`.
*Why:* org law — no shell. CI logic in YAML `run:` blocks is unversioned,
untyped, untested shell that drifts per-repo; pushing all logic into substrate-
built Rust tooling means CI behavior is standardized and changed fleet-wide in
one place. The action-Go case consumes `pleme-actions-shared-go` for in-action
logic (see [NAME-12](#dimension-naming-name), [TEST-02](#dimension-testing-and-quality-test)).
*Enforcement:* `caixa-validate` rejects any workflow not matching the substrate-
emitted `auto-release.yml` shape, and `run:` blocks exceeding the glue budget or
containing `go test`/`go build`/release logic; the workflow is regenerated by
`pleme-doc-gen caixa`, so a hand-edit is flagged as drift.
*Demonstrated by:* the canonical example's sole workflow is the generated
`auto-release.yml`; its `caixa.lisp` declares `:workflows [ :auto-release ]`.

**LAYOUT-08** — Single-binary vs multi-binary is a typed, mutually-exclusive
layout decision. SINGLE-BINARY: exactly one `cmd/<name>/` (name == repo slug),
flake uses `tool-release-flake.nix`, `caixa.lisp` `:kind` is `Binario` (or
`Servico`). MULTI-BINARY: ≥2 `cmd/<bin>/` subdirs sharing `internal/`, flake
composes one `mkGoMonorepoSource` (shared src+ldflags) feeding N
`mkGoMonorepoBinary`/`mkGoTool` calls, and `caixa.lisp` enumerates each binary.
A repo MUST NOT mix a `Biblioteca` root-package public API with `cmd/` binaries
— split into a lib repo + a consumer repo instead.
*Why:* conflating a library with binaries, or scattering binaries without a
shared source factory, produces inconsistent version-injection and import
graphs; the monorepo source factory guarantees one src, one version, one ldflags
per repo.
*Enforcement:* `caixa-validate` cross-checks the `cmd/` count against
`caixa.lisp` `:kind`/binary list and the flake helper used (a lone `cmd/` with
`library-flake.nix`, or ≥2 `cmd/` without `mkGoMonorepoSource`, is rejected);
`monorepo.nix` asserts on owner/repo/version; `nix flake check` builds every
declared `cmd/` binary.
*Demonstrated by:* `build/go/monorepo.nix` demonstrates the kubernetes/kubernetes
pattern (one `mkGoMonorepoSource` → kubelet/kubeadm/… via per-`cmd/`
`subPackages`); the canonical multi-binary example (`widgetkit`) mirrors it.

**LAYOUT-09** — The repo's FSM/kind is DECLARED once in a top-level `caixa.lisp`
`(defcaixa <name> :kind "…" :ecosystem "…" …)` — the single source of truth for
the repo's lifecycle state machine, from which all generated artifacts
(`flake.nix`, CI shim, nix module trio, CHANGELOG release wiring) are emitted via
`pleme-doc-gen caixa --source caixa.lisp --out .`. The Go `:ecosystem` is
`go-single-module` (libs/single-binary) or `go-monorepo` (multi-binary); the
`:kind` is one of the five typed kinds — `Biblioteca` (importable library, no
main), `Binario` (one-shot CLI), `Servico` (long-running daemon), `Supervisor`,
`Aplicacao` (mesh). `:package` carries `:name`/`:version`/`:license "MIT"`/
`:repository`, and `:exposes` lists the published surface (e.g. `:go-module`).
*Why:* a repo's kind drives which build helper, CI workflow, release semantics,
and module surface apply — encoding it as typed Lisp makes the FSM machine-
checkable and the generated surface derivable mechanically. `caixa.lisp` is the
contract a follower reads to know what the repo IS before reading any Go.
*Enforcement:* `caixa-validate` parses `caixa.lisp`, asserts `:kind` ∈ the five
kinds and `:ecosystem` ∈ the Go ecosystems, then cross-checks the on-disk layout
([LAYOUT-03](#dimension-repo-layout-and-module-layout)/[LAYOUT-08](#dimension-repo-layout-and-module-layout))
against the declared kind; `caixa-forge`/`pleme-doc-gen` re-emit from it; the
typed `defcaixa` is a compile-time-checked tatara-lisp macro.
*Demonstrated by:* `pleme-asmut-derive/caixa.lisp` is the live shape; the
canonical Go example is identical with `:ecosystem "go-single-module"` and
`:exposes [ :go-module ]`.

**LAYOUT-10** — `go.sum` is committed and complete; dependencies are minimized
and the eight pleme-io runtime libs are the ONLY first-party `require`s a normal
repo needs. Re-implementing config loading, error severity, logging, CLI
parsing, service lifecycle, retrying HTTP, or job scheduling locally is
forbidden; consume the library. `pleme-actions-shared-go` (action repos only)
mandates a zero-third-party-dependency closure.
*Why:* ruthless standardization — every Go service/tool must discover config,
emit logs, parse CLI, and run its lifecycle IDENTICALLY, which holds only if they
import the same libraries. A local re-implementation is the "second copy" the
prime directive forbids. The full library-by-concern map is in
[CFG-01/CFG-02](#dimension-configuration-cfg), [ERR-01](#dimension-errors-err),
[OBS-01](#dimension-observability-obs), [CLI-01](#dimension-cli-ux-cli),
[LIFE-01](#dimension-lifecycle-and-health-life), [NET-01](#dimension-networking-net),
[JOB-01](#dimension-concurrency-and-jobs-job).
*Enforcement:* `caixa-validate` lints `go.mod` `require` blocks for local
re-implementations of a mandated concern, and rejects action repos with any
non-stdlib + non-`pleme-actions-shared-go` dependency; `mkGoLibraryCheck`/
`mkGoTool` build against the committed `go.sum`; `go mod verify` in `check-all`.
*Demonstrated by:* `shikumi-go`'s README ("discover it, load it — identically
everywhere"), `pleme-actions-shared-go`'s README ("zero external dependencies …
offline-buildable"); the canonical `Servico` imports shikumi/logging/errors/
lifecycle-go and re-implements none.

**LAYOUT-11** — The repo root directory name, the GitHub slug, the `go.mod`
module suffix, the `caixa.lisp` `<name>`+`:package.name`, the `README.md` H1, the
`flake.nix` `name`/`toolName`, and (single-binary) the sole `cmd/<name>/`
directory MUST all be the SAME identifier. There is exactly one canonical name
per repo and it is repeated, never transformed, across every surface.
*Why:* identity must be gapless — a follower who learns the name in one place can
predict it everywhere; any transformation (snake↔kebab, dropping `-go` in one
file) creates a lookup gap and silent mismatches. Naming-surface specifics live
in [NAME-01](#dimension-naming-name)..[NAME-13](#dimension-naming-name).
*Enforcement:* `caixa-validate` computes the canonical name from the repo
basename and asserts byte-equality against the module suffix, `caixa.lisp`
`<name>`/`:package.name`, README H1, flake `name`/`toolName`, and `cmd/<name>/`;
the GitHub-posture IaC owns the slug, so a rename is a coordinated reconcile.
*Demonstrated by:* `shikumi-go` dir == `module …/shikumi-go` == README
`# shikumi-go`; `pleme-asmut-derive/caixa.lisp` repeats the name verbatim across
`<name>` and `:package`.

**LAYOUT-12** — There is no `vendor/` directory. Dependencies resolve through the
Go module proxy and are pinned by `go.sum`; the substrate builders supply
`vendorHash` (single binary via `tool.nix`) or `vendorHash = null`/proxy-fetch
(libraries via `library-check.nix`). `cmd/` binaries that need a `vendorHash`
record it in `flake.nix`, never by checking a `vendor/` tree into git.

> **Vendoring (single mechanism).** The GSDS resolves dependencies through the
> Go module proxy + committed `go.sum` + Nix `vendorHash` — **never a committed
> `vendor/` tree and never `-mod=vendor`.** [SEC-10](#dimension-security-and-supply-chain-sec)
> states its hermeticity requirement in exactly those terms (no `-mod=vendor`
> wording remains in any rule). The proxy+`go.sum`+`vendorHash` triple already
> gives reproducible, offline-after-fetch, content-addressed builds inside the
> network-less Nix sandbox plus `go mod verify` — the property
> [SEC-10](#dimension-security-and-supply-chain-sec) requires.
> [LAYOUT-12](#dimension-repo-layout-and-module-layout) governs the on-disk layout
> (no `vendor/`); the `dependency-update` auto-PR refreshes `go.sum`/`vendorHash`,
> not a `vendor/` tree.

*Why:* a committed `vendor/` tree duplicates the dependency closure in-repo,
bloats diffs, and competes with the `go.sum`+`vendorHash` hermetic-build path.
*Enforcement:* `caixa-validate` rejects a committed `vendor/`; `mkGoTool`
requires an explicit non-null/string `vendorHash`; `mkGoLibraryCheck` builds
`./...` from the proxy-resolved closure; `go mod verify` in `check-all`.
*Demonstrated by:* no runtime lib commits a `vendor/`; the canonical example pins
`vendorHash` in `flake.nix` (single-binary) with no `vendor/` tree.

---

## Dimension: Naming (NAME)

**NAME-01** — A repo that ships an importable Go package MUST be named
`<concept>-go` (lowercase, single hyphen-joined concept noun, literal `-go`
suffix), its module path MUST be exactly `github.com/pleme-io/<concept>-go`, and
the on-disk directory MUST match the repo name. The triple (repo name, module
path tail, on-disk dir) is one value, written once.
*Why:* the eight mandated libs are all built this way; a user who knows the
concept derives the import path with zero lookups (total, bijective mapping). The
`-go` suffix disambiguates from same-named siblings in other languages. Composes
with [LAYOUT-01](#dimension-repo-layout-and-module-layout)/[LAYOUT-11](#dimension-repo-layout-and-module-layout).
*Enforcement:* `caixa-validate` asserts module path ==
`github.com/pleme-io/$(basename $repo)`; the `library-flake.nix` `repo`/`name`
args are cross-checked at Nix eval; `tend status` flags on-disk/slug divergence.
*Demonstrated by:* `widget-go` → `module github.com/pleme-io/widget-go`,
mirroring `shikumi-go`'s `module github.com/pleme-io/shikumi-go`.

**NAME-02** — The exported package name (the `package X` clause of every
non-`_test`, non-`main` file in the repo root) MUST be the bare concept with the
`-go` suffix stripped and all hyphens removed — `package <concept>`. A multi-word
repo collapses to a single lowercase token (no underscores, no mixedCaps);
`pleme-actions-shared-go` is the canonical collapse → `package actions`.
*Why:* Go identifiers cannot contain hyphens, so the package name MUST differ
from the repo name; standardizing the exact transform removes the per-repo guess
(`errors-go`→`errors`, `cli-go`→`cli`, etc.).
*Enforcement:* `go vet` + `revive`/`golangci-lint` `package-comments`/
`var-naming` forbid mixedCaps/underscore package names; `caixa-validate` computes
`ReplaceAll(TrimSuffix(repo,"-go"),"-","")` and asserts equality, pinning
multi-word collapses declared in `caixa.lisp`.
*Demonstrated by:* `widget-go/widget.go` opens `package widget`, mirroring
`errors-go/errors.go`'s `package errors`.

**NAME-03** — Exported identifiers MUST NOT stutter against the package name
(`errors.New` not `errors.NewError`; `cli.NewApp` not `cli.NewCLIApp`;
`shikumi.Load` not `shikumi.LoadShikumi`). The package qualifier is the noun; the
identifier is the verb or bare type. Functional-options constructors follow the
`With<Field>` pattern returning the package's `Option` type.
*Why:* Go's own style guide and the runtime libs enforce this; `errors.New(...)`
reads as a sentence because the package already supplies the domain noun.
*Enforcement:* `golangci-lint` `revive` `exported` + `staticcheck ST1003`; the
`With<Field>` options shape is compiler-enforced (each must return the package's
exported `Option` func type).
*Demonstrated by:* `widget-go` exposes `widget.New`, `widget.WithTimeout`, type
`widget.Option` — structurally identical to `errors-go`'s `errors.New(msg, opts ...Option)`.

**NAME-04** — File names MUST be lowercase, words joined by underscore only when
needed, ending `.go`; each file is named for the ONE concept it defines. The repo
root MUST contain a doc-anchor file named exactly `<package>.go` (`shikumi.go`,
`cli.go`, …) holding the `// Package <name>` doc comment and the package's
primary entry type. Test files are `<peer>_test.go`. A standalone package doc may
instead live in `doc.go`.
*Why:* a user opening an unfamiliar lib finds its purpose in a predictable place;
per-concept files make grep-by-filename a navigation primitive. Composes with
[DOC-01](#dimension-documentation-and-discoverability-doc).
*Enforcement:* `caixa-validate` asserts a root `<package>.go` or `doc.go` carries
the `// Package <name>` comment; `gofmt -l`; a filename lint forbids
uppercase/double-underscore; a coverage-presence check requires colocated
`*_test.go` peers.
*Demonstrated by:* `widget-go` root: `widget.go`, `retry.go`+`retry_test.go`,
`health.go`+`health_test.go` — the exact layout of `lifecycle-go`.

**NAME-05** — A repo that produces an executable MUST be named `<thing>` WITHOUT
the `-go` suffix (reserved for importable libraries per
[NAME-01](#dimension-naming-name)). Its module path is
`github.com/pleme-io/<thing>`, the binary name equals `<thing>`, the substrate
`toolName`/`pname` equals `<thing>`, and the installed path is `bin/<thing>`.
Binary repo, module tail, `toolName`, `pname`, `meta.mainProgram`, and CLI
program name are ONE value.
*Why:* suffix discipline lets a user tell library from binary by name alone
(`cli-go` is the library; the CLI built atop it is `clint`). Substrate cements
this: `tool.nix` sets `meta.mainProgram = pname` and wires
`apps.default.program = "${package}/bin/${toolName}"`.
*Enforcement:* `mkGoTool` asserts `nonEmptyStr pname` and pins `bin/${toolName}`;
`caixa-validate` asserts `cli.NewApp(name)` == `toolName` == module tail; CI
`nix build .#<thing>` + `nix run .#<thing> -- --version` smoke-test.
*Demonstrated by:* `widgetctl`: `module …/widgetctl`, flake
`toolName = "widgetctl"`, `cli.NewApp("widgetctl", cli.WithVersion(version))`,
installs to `bin/widgetctl`.

**NAME-06** — CLI command and subcommand tokens (the `cli.Command{Name: …}` value
from `cli-go`) MUST be lowercase, single words or kebab-case, verbs or
verb-objects (`apply`, `auth`, `list-keys`), matched case-sensitively. The tokens
`help`, `-h`, `--help`, `version`, `-v`, `--version` are RESERVED by `cli-go`'s
router and MUST NOT be redefined as command names.
*Why:* `cli-go`'s `App.Run` hard-codes the reserved tokens and sorts usage tables
by `Name`; consistent lowercase kebab tokens render a clean, alphabetized help.
Case-sensitive matching means inconsistent casing yields "unknown command".
Composes with [CLI-02](#dimension-cli-ux-cli)/[CLI-03](#dimension-cli-ux-cli).
*Enforcement:* `caixa-validate` AST-scans `cli.Command{Name: …}` literals,
rejecting non-kebab/uppercase/space/reserved-collision names; cli-go's router
shadowing rules catch reserved collisions in the integration smoke test.
*Demonstrated by:* `widgetctl` registers `cli.Command{Name: "apply"}` and a group
`{Name: "auth", Sub: [{Name:"login"},{Name:"whoami"}]}`, rendered
`widgetctl auth <subcommand>`.

**NAME-07** — Every binary MUST define exactly ONE env-var PREFIX equal to the
binary name UPPER-cased with hyphens → underscores plus a trailing underscore
(`widgetctl` → `WIDGETCTL_`, `list-keys-tool` → `LIST_KEYS_TOOL_`). This single
prefix is passed as the `prefix` argument to
`shikumi.Load[T](path, prefix, defaults)`. No env var read by the program may use
any other prefix (cloud-SDK vars like `AWS_*` excepted, owned by their SDKs).
*Why:* `shikumi-go`'s `envMap(prefix)` collects only `PREFIX_*` vars with `_` as
the nesting delimiter; one prefix per binary makes the whole env surface
discoverable by grepping a single token. Composes with
[CFG-04](#dimension-configuration-cfg)/[NAME-09](#dimension-naming-name).
*Enforcement:* `caixa-validate` asserts the `shikumi.Load` `prefix` ==
`ToUpper(ReplaceAll(binaryName,"-","_"))+"_"`; a lint forbids raw `os.Getenv`
on uppercase identifiers outside the cloud-SDK allowlist; the env-override path
var ([NAME-08](#dimension-naming-name)) is the one sanctioned exception.
*Demonstrated by:* `widgetctl` calls `shikumi.Load[Config](path,"WIDGETCTL_",…)`,
so `WIDGETCTL_LOG_LEVEL`/`WIDGETCTL_SERVER_PORT` map to `log.level`/`server.port`.

**NAME-08** — The config-file discovery name passed to `shikumi.New(app)` MUST
equal the binary name ([NAME-05](#dimension-naming-name)) verbatim (lowercase,
hyphens kept), yielding config at `~/.config/<app>/<app>.{yaml,yml,toml}`. The
env-var path override registered via `.EnvOverride(name)` MUST be
`<PREFIX>CONFIG` (the [NAME-07](#dimension-naming-name) prefix + `CONFIG`), e.g.
`WIDGETCTL_CONFIG`.
*Why:* `shikumi-go`'s `Discovery` keys every search path on the `app` token, so
a user who runs `widgetctl` knows the config lives at
`~/.config/widgetctl/widgetctl.yaml` with zero docs. Composes with
[CFG-03](#dimension-configuration-cfg).
*Enforcement:* `caixa-validate` asserts `shikumi.New(...)` == binary name and
`.EnvOverride(...)` == `<PREFIX>CONFIG`; an integration smoke test sets
`<PREFIX>CONFIG` and asserts the binary loads it.
*Demonstrated by:* `widgetctl` builds
`shikumi.New("widgetctl").EnvOverride("WIDGETCTL_CONFIG").Formats(shikumi.Yaml)`.

**NAME-09** — Config keys (YAML map keys / shikumi's dotted keys) MUST be
lowercase `snake_case` leaf tokens with dotted/nested hierarchy (`server.port`,
`retry.max_attempts`). They MUST be the deterministic image of the env var under
shikumi's transform. Go struct field tags MUST pin each field to its snake_case
key.
*Why:* `shikumi-go` lowercases `PREFIX_FOO_BAR` to `bar` with `_` as the nesting
delimiter; the YAML file and env override MUST agree on snake_case or the two
layers silently key different names. Composes with
[CFG-05](#dimension-configuration-cfg)/[NAME-07](#dimension-naming-name).
*Enforcement:* `caixa-validate` parses config-struct tags asserting snake_case
matching the schema; a round-trip test loads YAML and the equivalent `PREFIX_*`
env asserting identical structs; `golangci-lint` `tagliatelle`.
*Demonstrated by:* `widgetctl`'s `Config` carries `yaml:"port"` under a `server`
sub-struct; `WIDGETCTL_SERVER_PORT=8080` and `server: {port: 8080}` both populate
`Config.Server.Port`.

**NAME-10** — Internal (non-exported-API) packages MUST live under
`internal/<name>/` with `<name>` a short lowercase no-stutter token and the
`package` clause equal to `<name>`. Public sub-packages MUST live in a named
subdirectory whose final path element equals the package clause (`<repo>/store`,
`package store`). Directory final element and package clause are always equal;
the only sanctioned divergence is the root package ([NAME-02](#dimension-naming-name))
and `main`.
*Why:* Go resolves a package by directory; a dir/clause mismatch forces importer
aliases and collapses navigability. `internal/` lets the compiler forbid external
import, encoding the public/private boundary in the type system. Composes with
[LAYOUT-03](#dimension-repo-layout-and-module-layout).
*Enforcement:* `go build` + `go vet` reject importing `internal/` externally
(compiler-enforced); `staticcheck ST1000`/`revive` flag dir↔package mismatches;
`caixa-validate` asserts `Base(dir) == packageClause` for every non-root,
non-`main` directory.
*Demonstrated by:* `widget-go` keeps helpers in `internal/codec/` (`package
codec`) and a public `store/` (`package store`).

**NAME-11** — Executable entry points MUST live under `cmd/<binary>/main.go` with
`package main`, where `<binary>` equals the produced binary name
([NAME-05](#dimension-naming-name)). N binaries → N `cmd/<binary-i>/`
directories, each name distinct and matching its substrate `subPackages`/
`monorepo-binary.nix` entry. A single-binary repo still uses `cmd/<binary>/`.
*Why:* a user looking for "where this binary starts" has exactly one place;
substrate selects build targets by `cmd/*` path, so the directory name IS the
build contract. Composes with [LAYOUT-08](#dimension-repo-layout-and-module-layout).
*Enforcement:* `caixa-validate` asserts every `package main` file is at
`cmd/<x>/main.go` and the `cmd/*` set equals the declared binary set;
`monorepo-binary.nix` fails if a requested `cmd/<binary>` path is absent.
*Demonstrated by:* `widgetkit` has `cmd/widgetctl/main.go` and
`cmd/widgetd/main.go`, the layout the org's `cli` repo uses with
`cmd/clint`/`cmd/yocli`.

**NAME-12** — A GitHub Action repo MUST be named `<verb-object>-action`
(kebab-case, suffix `-action`), MUST build its behavior as a Go binary via
substrate `build/go/action-release-flake.nix`, and its workflow `inputs.<name>`
MUST be kebab-case. Input names are consumed via `pleme-actions-shared-go`
(`actions.ParseInputs`), which reads `INPUT_<NAME>` where `<NAME>` is the input
name UPPER-cased with hyphens/spaces → underscores. Input names MUST therefore be
kebab-case so the transform is unambiguous.
*Why:* `pleme-actions-shared-go` hard-codes the `INPUT_` prefix and the
upper+underscore transform (GitHub's own contract); standardizing on `-action` +
kebab inputs means the workflow key, the env var, and the Go field all derive
from one kebab token — the Actions-surface mirror of [NAME-07](#dimension-naming-name).
*Enforcement:* `caixa-validate` asserts action repos end in `-action`, build via
`action-release-flake.nix` (which renders `action.yml`), and every input key is
kebab-case; a round-trip test sets `INPUT_<NAME>` and asserts `ParseInputs`.
*Demonstrated by:* `notify-slack-action`: `action.yml` declares `webhook-url`;
the Go `main` reads `INPUT_WEBHOOK_URL` into `in.WebhookURL` via
`actions.ParseInputs(&in)`.

**NAME-13** — Acronyms and initialisms in exported identifiers MUST be all-caps
(`HTTPClient`, `ParseURL`, `userID`, `apiKey` unexported) per Go's MixedCaps
initialism rule; they MUST NEVER appear in package names, file names, command
tokens, config keys, or env-var segments, which stay fully lowercase/snake/kebab
(`package http`; key `api_key`; command `parse-url`).
*Why:* Go style requires `URL`/`ID`/`API`/`HTTP` capitalized inside identifiers,
but the non-Go surfaces (paths, env, YAML, CLI) would be ambiguous or shell-
hostile with MixedCaps; the split removes the most common cross-surface naming
inconsistency and keeps shikumi's lowercase env→key transform total
([NAME-09](#dimension-naming-name)).
*Enforcement:* `golangci-lint` `revive var-naming` + `staticcheck ST1003` enforce
identifier initialisms; the [NAME-04](#dimension-naming-name)/[NAME-06](#dimension-naming-name)/
[NAME-09](#dimension-naming-name)/[NAME-07](#dimension-naming-name) lints forbid
uppercase in the non-Go surfaces (pincer enforcement).
*Demonstrated by:* `widget-go` exposes `widget.HTTPClient` and
`widget.NewClient(apiKey string)` while the config key is `api_key` and the env
var is `WIDGETCTL_API_KEY`.

---

## Dimension: CLI UX (CLI)

**CLI-01** — Every Go binary that takes arguments MUST be built on `cli-go`'s
App/Command model: construct exactly one
`cli.NewApp(name, cli.WithVersion(...), cli.WithDescription(...))`, register every
subcommand via `app.Add(cli.Command{...})`, and drive it from `main` with
`app.Run(ctx, os.Args)`. Hand-rolled `os.Args` switches, bespoke `flag.Parse()`
at `main`, third-party CLI frameworks (cobra/urfave/kingpin/pflag), and direct
`flag` use outside a `cli.Command.Flags` closure are forbidden. A pure
zero-argument daemon is exempt only until it grows its first flag.
*Why:* `cli-go` is the single human+machine boundary — it routes
`--help`/`--version`, builds a validated `FlagSet` per invocation, prints
name-sorted usage tables, and returns the `ErrHelp`/`ErrNoCommand` clean-exit
sentinels. One framework means learning one fleet CLI is learning them all.
Composes with [LAYOUT-10](#dimension-repo-layout-and-module-layout) and [NAME-05](#dimension-naming-name).
*Enforcement:* `go vet` + a substrate forbidigo/staticcheck ruleset ban
`flag.Parse`/`NewFlagSet`/`CommandLine` and cobra/pflag/urfave/kingpin imports
outside `_test.go`; a grep gate asserts `package main` imports `cli-go`;
`main`'s dispatch is forced to `cli.App.Run(context.Context, []string)`.
*Demonstrated by:* `cmd/<bin>/main.go` constructs one `*cli.App`, registers all
commands via `.Add(...)`, and ends with the [CLI-12](#dimension-cli-ux-cli) exit
shim; no `flag.Parse` appears in the tree.

**CLI-02** — Subcommand names MUST be lowercase kebab-case verbs or noun-verb
pairs (`list-secrets`, `auth login`, `target create`), never camelCase,
snake_case, or single ambiguous nouns. Nesting is capped at two levels
(`cli.Command.Sub`, one deep). A command is EITHER a runnable leaf (`Run` set,
`Sub` empty) OR a pure group (`Run` nil, `Sub` non-empty); a hybrid group-with-
default-`Run` is permitted only as the group's obvious no-argument behavior.
Every `Command` MUST set a non-empty `Name` and a non-empty one-line `Summary`.
Positional arguments are reserved for the command's primary subject (a path, an
id, a file); every other input MUST be a named flag.
*Why:* a predictable grammar makes the CLI navigable without docs; cli-go renders
the `Summary` in the parent's table and refuses to deepen past `Sub`, so capping
nesting at two and mandating `Summary` keeps `--help` complete. Composes with
[NAME-06](#dimension-naming-name).
*Enforcement:* the `cli-go-conformance` harness walks `app.Commands` asserting
`Name` matches `^[a-z][a-z0-9-]*$`, `Summary` non-empty, no untagged leaf+group
hybrid, and `Sub` depth no greater than 1.
*Demonstrated by:* the example exposes `tool secret list`,
`tool secret create <path>`, `tool auth login` — a pure `secret` group, runnable
leaves, hyphenated verbs, single positional, every `Summary` populated.

**CLI-03** — `--help` and `-h` MUST resolve on EVERY node of the command tree
(root, every group, every leaf), print that node's own usage (summary, usage
line, subcommand table, flag defaults), and exit cleanly. Tools MUST NOT
intercept, shadow, or redefine help — they rely on cli-go's built-in routing. A
command with flags MUST register them via `Command.Flags` so cli-go's
`writeCommandUsage` enumerates them under a `Flags:` block; flags created outside
that closure are forbidden.
*Why:* gapless help is the contract — a user must be able to stop anywhere and
ask `--help` to learn what comes next; a tool registering flags via a captured
global `FlagSet` breaks it because those flags never appear in `PrintDefaults`.
*Enforcement:* the conformance harness invokes `[<each-path>, "--help"]` over the
full tree asserting `cli.ErrHelp` and a non-empty usage block naming every
registered flag; forbidigo bans defining flags on `flag.CommandLine`; a CI matrix
greps for the `Usage:` line.
*Demonstrated by:* `tool --help`, `tool secret --help`,
`tool secret create --help` each print the correct node's usage with the
`Flags:` block; the harness asserts `ErrHelp` on all three.

**CLI-04** — `--version` and `-v` (and the `version` token) MUST print exactly
one line `<name> <semver>` and exit 0, sourced from `cli.WithVersion`. The
version string MUST be build-stamped at link time via the substrate Go builder's
`-X main.version=...` ldflags, NOT a hand-edited const. `-v` MUST mean version
and nothing else (never verbose; use `--log-level`/`-V` per
[CLI-06](#dimension-cli-ux-cli)). The same version string MUST appear in
`--output json` metadata when the tool emits structured output.
*Why:* cli-go wires `-v`/`--version`/`version` through `App.Run`; link-time
stamping keeps the binary's self-reported version identical to the Nix-pinned
release version. Reserving `-v` for version removes the most common cross-tool
ambiguity. Composes with [VER-04](#dimension-versioning-and-compatibility-ver) and
[SEC-01](#dimension-security-and-supply-chain-sec).
*Enforcement:* the substrate builder injects `-ldflags "-X main.version=${version}"`;
a `library-check.nix` assertion fails the build if `main.version` is unset at
link; the harness asserts `version`/`--version` emit `name <nonEmpty>` and no
`-v` means verbose.
*Demonstrated by:* the flake passes `cli.WithVersion(version)` where `version` is
the ldflags-injected var; `tool --version` prints `tool 5.0.22` matching the
flake's pinned version.

**CLI-05** — A fixed, documented set of GLOBAL flags MUST be accepted by every
command with identical names, semantics, and defaults fleet-wide: `--output`/
`-o`, `--log-level`, `--config`, `--no-color`, `--quiet`/`-q`, and
`--version`/`--help`. Global flags MUST be registered through a single shared
`cli.Globals` helper reused by every `Command.Flags` closure — never redefined
per command. Command-specific flags MUST NOT reuse any reserved global short or
long name. Global flags MUST be accepted in either position (before or after the
subcommand) and resolve to the same value.
*Why:* without a shared registrar each command re-declares `--output` with subtly
different defaults; a single registrar guarantees `--output json` behaves
identically everywhere and completions advertise the same global set.
*Enforcement:* `cli.Globals(fs)` is the registrar; the harness asserts every
`Command.Flags` invokes it (the parsed `FlagSet` contains all reserved names with
canonical defaults) and no command collides with the reserved set; a golangci
analyzer flags any `fs.String("output"...)` not routed through `cli.Globals`.
*Demonstrated by:* every command calls `cli.Globals(fs)` first;
`tool -o json secret list` and `tool secret list -o json` produce byte-identical
output.

**CLI-06** — Configuration resolution MUST follow strict precedence
**flags > env > config-file > defaults**, realized by layering cli-go flag values
ON TOP of a `shikumi-go` load. Because `shikumi.Load` internally merges
defaults to env(`PREFIX_`) to file (file winning over env), tools MUST invert
nothing inside shikumi; they load the shikumi value, then overlay
explicitly-set flags last so an operator-supplied flag always wins. Only flags
the user actually set may override config — defaulted flags MUST NOT clobber
config values (use `fs.Visit`, not `fs.VisitAll`). Env vars consumed by the CLI
MUST use the same `PREFIX_` scheme shikumi expects.
*Why:* flags > env > config > defaults is the universal operator expectation; a
config file overriding an explicit `--flag` is astonishing. shikumi's own chain
stops at file-over-env, so the CLI layer is responsible for the flags-on-top
step, and an unset flag must not silently outrank a config value. Composes with
the whole [Configuration](#dimension-configuration-cfg) dimension and
[NAME-07](#dimension-naming-name)/[NAME-09](#dimension-naming-name).
*Enforcement:* `cli.Resolve[T](fs, shikumiStore)` calls `store.Get()` then
overlays only `fs.Visit`-detected flags, returning the merged typed config —
tools MUST NOT hand-merge; a table-driven test asserts all four precedence
permutations; load failures surface via the exit taxonomy
([CLI-09](#dimension-cli-ux-cli)).
*Demonstrated by:* the example's resolve step is `cfg := cli.Resolve(fs, store)`;
a fixture proves flag > env > file > default with no clobbering by defaulted
flags.

**CLI-07** — Every command that emits result DATA (as opposed to logs/
diagnostics) MUST honor `--output`/`-o` with `json`, `yaml`, and `text`,
defaulting to `text`. The data payload MUST be produced by passing a typed result
struct to the shared `cli.Render(w, format, v)` helper — commands MUST NOT branch
on the format with hand-written `fmt.Printf`/`encoding/json` calls. `json` and
`yaml` MUST be the SAME typed struct serialized two ways (stable field names,
sorted keys), MUST be valid parseable documents with nothing else interleaved on
stdout, and MUST be deterministic. When `--output` is `json`/`yaml`, no
human-only decoration (spinners, colors, progress) may touch stdout.
*Why:* a CLI is a machine boundary; `-o json | jq` only works if stdout carries
exactly one valid document. Centralizing serialization in `cli.Render` guarantees
json/yaml are the same struct and stable keys, making a fourth format a one-place
change. Composes with [CLI-08](#dimension-cli-ux-cli).
*Enforcement:* `cli.Render` is the only sanctioned data emitter; forbidigo bans
`fmt.Print*` and `json.NewEncoder(os.Stdout)` inside `Run` bodies; the harness
runs each command with `-o json`/`-o yaml` asserting clean round-trips with zero
trailing bytes; `cli.Globals` validates `--output` via
`cli.OneOf("json","yaml","text")`.
*Demonstrated by:* `tool secret list -o json` pipes cleanly into `jq`; the `Run`
body calls `cli.Render(os.Stdout, g.Output, result)` once and contains no
`fmt.Printf`.

**CLI-08** — `fmt.Println`/`fmt.Printf`/`print`/`log.Println` MUST NOT be used
for ANY user-facing output. Result DATA goes to stdout exclusively via
`cli.Render` ([CLI-07](#dimension-cli-ux-cli)). DIAGNOSTICS (progress, warnings,
human status, errors) go to STDERR exclusively via a `logging-go` logger threaded
through context. stdout is reserved for the machine-consumable result; stderr for
human/operator chatter — so `tool ... -o json > out.json` yields a clean file
while the operator still sees progress. Usage/`--help` text remains on stderr via
cli-go's default `cli.WithOutput`.
*Why:* mixing log lines into the data stream corrupts `| jq` and breaks every
downstream pipeline; `logging-go` exists precisely to kill ad-hoc `fmt.Println`
logging. Composes with [OBS-01](#dimension-observability-obs)/[OBS-02](#dimension-observability-obs).
*Enforcement:* forbidigo bans `fmt.Print*`/`print`/`println`/`log.*` across
`cmd/` and command packages (allowed only inside `cli.Render`/`logging-go`);
the substrate CLI devenv sets `logging-go` `WithWriter(os.Stderr)` (inverting its
library default of stdout); the conformance test captures stdout/stderr
separately and asserts `-o json` stdout is ONLY the JSON document.
*Demonstrated by:* `main` calls
`logging.New(logging.WithWriter(os.Stderr), logging.WithFormat("text"), logging.WithLevelFromEnv(""))`;
commands emit progress via `logging.FromContext(ctx).InfoContext(...)`;
`tool secret list -o json 2>/dev/null` is pure JSON.

**CLI-09** — Binaries MUST translate the returned error into a stable exit-code
taxonomy via the shared `cli.ExitCode(err)` mapping, and `main` MUST call
`os.Exit` with its result. The taxonomy is fixed fleet-wide: `0` = success; `64`
= usage/parse error (`cli.ErrNoCommand`, unknown command/flag, validator failure
— the `EX_USAGE` family); `70` = internal error mapped from `errors-go`
`SeverityError` (the default for any un-annotated failure); a `SeverityWarning`
that nonetheless aborts maps to `75`; `130` = interrupted (context canceled /
SIGINT). `cli.ErrHelp` and a clean version print MUST exit `0`. The mapping reads
severity via `errs.SeverityOf` and MAY refine by `errs.CodeOf`, but MUST be
total: every non-nil error yields a deterministic code, defaulting to `70`.
*Why:* exit codes are the CLI's primary machine signal; `errors-go` already
classifies every error by Severity and carries an optional machine Code, so the
exit taxonomy is a pure total function of that metadata. Distinguishing 64
(user's fault) from 70 (tool/world's fault) is the difference a CI script needs.
Composes with the [Errors](#dimension-errors-err) dimension, especially
[ERR-07](#dimension-errors-err).
*Enforcement:* `cli.ExitCode(err) int` and `cli.Exit(err)` (calling
`os.Exit(ExitCode(err))`) are the only sanctioned exit path; golangci bans
`os.Exit` with a literal other than via `cli.Exit` and bans `log.Fatal*`; a
table-driven test maps each sentinel/severity to its code.
*Demonstrated by:* `main` is
`if err := app.Run(ctx, os.Args); err != nil { cli.Exit(err) }`; a validator
failure exits 64, a wrapped `SeverityError` exits 70, `--help` exits 0.

**CLI-10** — All flag and argument validation MUST run through cli-go validators
registered in the `Command.Flags` closure (`cli.Required`, `cli.OneOf`,
`cli.Range`, `cli.NonEmptyURL`, `cli.Predicate`, `RegisterValidator`) so it
executes after parse and before `Run` — `Run` bodies MUST NOT re-validate inputs
they could have declared. A validation failure MUST produce an actionable stderr
message naming the offending flag and the expected shape, and MUST map to exit 64
([CLI-09](#dimension-cli-ux-cli)). User-facing error messages MUST be lowercase,
free of Go-internal noise, and carried as `errors-go` `Error`s (`errs.New`/
`errs.Wrap` with a `WithCode` where a machine-stable code aids scripting); cli-go
surfaces the code in `-o json` error envelopes.
*Why:* cli-go runs validators between Parse and Run precisely so invalid input
never reaches business logic; duplicating checks inside Run defeats that gate.
Wrapping in `errors-go` means one error value serves both the human (message) and
the `-o json` consumer (code). Composes with [ERR-12](#dimension-errors-err).
*Enforcement:* the harness asserts each constrained-flag command rejects an
out-of-range value before `Run` (instrumented); golangci flags manual `if flagVal
== "" { return … }` shape-checks duplicating a validator; `cli.Render`'s error
path serializes `errs.CodeOf(err)` + message into the json/yaml envelope.
*Demonstrated by:* `secret create` registers
`cli.RegisterValidator(fs, "path", cli.Required())` and
`cli.RegisterValidator(fs, "ttl", cli.Range(1, 3600))`; `tool secret create
--ttl 0` prints `ttl: must be in [1, 3600]` to stderr and exits 64 without
entering `Run`.

**CLI-11** — Every CLI binary MUST implement a hidden top-level `completion`
command supporting bash, zsh, and fish (`<bin> completion {bash|zsh|fish}`),
emitting a valid completion script to stdout. Completions MUST be generated from
the live cli-go command tree (names, summaries, global+command flag sets) via the
shared `cli.Completion(app)` generator — never hand-maintained — so they cannot
drift. The substrate Go builder MUST install them at package time via
`completions = { install = true; command = "<bin>"; }`, wiring
`installShellCompletion` for all three shells.
*Why:* completions are a core human boundary and the most divergence-prone if
hand-written; generating them from the same `cli.App` that drives dispatch means
adding a subcommand makes its completion appear for free; substrate's
`completions.nix` already expects exactly this contract.
*Enforcement:* `app.AddCompletion()` registers the hidden command and
`cli.Completion(app, shell)` generates; the harness asserts each shell emits a
non-empty script referencing every top-level command; the library-check asserts
`completions.install=true` with `command` matching the binary, failing packaging
if `<bin> completion bash` errors.
*Demonstrated by:* the example registers `app.AddCompletion()` and its flake
declares `completions = { install = true; command = "tool"; }`;
`tool completion zsh` lists `secret`, `auth`, etc.

**CLI-12** — `main` MUST use the canonical cli-go exit shim and nothing else: run
the app, treat `cli.ErrHelp` and `cli.ErrNoCommand`-after-help as clean exits,
and route every other error through `cli.Exit`. Signal handling MUST install a
context that cancels on SIGINT/SIGTERM (`signal.NotifyContext`) threaded into
`app.Run`, so an interrupted command unwinds through context cancellation and
maps to exit 130 — tools MUST NOT trap signals ad hoc or call `os.Exit` from
within a command. `lifecycle-go` MUST own startup/teardown ordering for any
command that opens resources, guaranteeing deferred cleanup runs even on
interrupt.
*Why:* a uniform `main` shim makes exit semantics, signal handling, and cleanup
identical across every fleet binary; cli-go's sentinels exist to be recognized
here as clean exits; threading a `NotifyContext` is the only way SIGINT reaches a
long-running command cooperatively and surfaces as 130; lifecycle-go sequencing
ensures an interrupted command still closes its client and flushes logs. Composes
with the [Lifecycle](#dimension-lifecycle-and-health-life) dimension and
[CLI-09](#dimension-cli-ux-cli).
*Enforcement:* the substrate scaffold (`mkGoCliTool`) emits the canonical
`main.go` shim; golangci bans `os.Exit`/`log.Fatal*` outside it and bans direct
`signal.Notify` in command packages; a conformance test sends a simulated cancel
asserting `context.Canceled` to exit 130 and that lifecycle-go closers ran.
*Demonstrated by:* `main` is
`ctx, stop := signal.NotifyContext(...); defer stop(); cli.Exit(app.Run(ctx, os.Args))`;
commands acquire clients via `lifecycle.Register(...)`; interrupting
`tool secret list` exits 130 after cleanup.

**CLI-13** — A command-specific flag or a subcommand is a user-facing
compatibility surface; renaming or removing one is a BREAKING change requiring a
MAJOR bump ([VER-05](#dimension-versioning-and-compatibility-ver)/[VER-06](#dimension-versioning-and-compatibility-ver)).
The CLI mirror of [VER-07](#dimension-versioning-and-compatibility-ver): the prior
name MUST survive as a hidden `cli.DeprecatedAlias` (registered via
`cli.WithDeprecatedAlias(old, new)`) for ≥1 prior MINOR before removal at the
MAJOR; invoking the alias maps the old name to the new and emits a `logging-go`
WARN with a stable greppable deprecation code ([VER-07](#dimension-versioning-and-compatibility-ver)),
classified through `errors-go`. Silent rename/removal in a MINOR or PATCH is
forbidden.
*Why:* the CLI is a boundary of communication ([thesis](#the-boundary-of-communication-thesis));
breaking a flag/subcommand mid-major silently breaks every script and pipeline
calling it, exactly as removing an exported Go identifier breaks importers. A
typed, hidden, warning alias gives operators a tooling-visible migration window
identical to the [VER-07](#dimension-versioning-and-compatibility-ver) Go-symbol
window. Composes with [CLI-02](#dimension-cli-ux-cli)/[CLI-05](#dimension-cli-ux-cli)/
[VER-07](#dimension-versioning-and-compatibility-ver).
*Enforcement:* the `cli-go-conformance` harness records the flag/subcommand set
per tag; a `forge tool check` apidiff-style gate over the CLI surface (derived by
walking `app.Commands`) blocks the Tagged transition if a flag/subcommand
disappeared without (a) the bump being `major` AND (b) a `cli.DeprecatedAlias`
having carried the old name for ≥1 prior MINOR; the harness asserts every alias
still resolves and emits the WARN; golangci flags a non-`logging-go` deprecation
warning.
*Demonstrated by:* the example renames `--ttl` to `--lease-ttl` in v1.6.0, keeps
`--ttl` as a hidden alias warning with code `DEP-CLI-0002`, and removes it only at
v2.0.0; CI rejects a `minor` bump that dropped a subcommand and accepts it once a
`DeprecatedAlias` is present.

---

## Dimension: Configuration (CFG)

**CFG-01** — Every Go binary, service, and daemon MUST model its entire runtime
configuration as exactly ONE exported, package-level typed struct (conventionally
`type Config struct{...}`) whose every field carries a `yaml` struct tag.
`map[string]any`, `interface{}`, untyped nested maps, and per-call `os.Getenv`/
`os.LookupEnv`/`flag.String("env...")` reads for configuration values are
FORBIDDEN. The struct is the sole configuration boundary; nothing downstream may
read the environment or filesystem for config.
*Why:* any reader who finds `Config` knows the COMPLETE configuration surface —
fields, types, and (via tags) wire names — with zero hidden inputs;
`map[string]any` and scattered `os.Getenv` defeat navigability. `shikumi-go`'s
package doc states the mandate verbatim. Composes with [CFG-13](#dimension-configuration-cfg).
*Enforcement:* a `go vet`-style analyzer (from `pleme-actions-shared-go`) flags
`os.Getenv`/`os.LookupEnv` outside the `shikumi-go` import and outside a
`Resolve` closure registered with cli-go's `AuthResolver`; a grep-gate forbids
`map[string]any`/`interface{}` field types in `*config*.go`; `shikumi.Load[T]`/
`LoadStore[T]` are generic over the struct.
*Demonstrated by:* the example declares
`type Config struct { Tenant string \`yaml:"tenant"\`; Port int \`yaml:"port"\` }`
in `internal/config/config.go` with zero `os.Getenv` calls.

**CFG-02** — Configuration MUST be loaded exclusively via `shikumi-go`: discover
the path with
`shikumi.New(app).EnvOverride("APP_CONFIG").Formats(...).Dirs(...).Discover()`,
then load with `shikumi.Load[T](path, "APP_", defaults)` (one-shot tools) or
`shikumi.LoadStore[T](path, "APP_", defaults)` (services/daemons). Hand-rolled
`yaml.Unmarshal`/`toml.Decode`/`json.Unmarshal` of config files, direct
`koanf`/`viper`, and bespoke layering logic are FORBIDDEN.
*Why:* one loader = one precedence model = one mental model fleet-wide;
`shikumi-go` is the Go mirror of the Rust `shikumi` crate, so a reader moving
between a Rust and a Go service sees identical discovery/layering. Composes with
[LAYOUT-10](#dimension-repo-layout-and-module-layout) and [CFG-06](#dimension-configuration-cfg).
*Enforcement:* a grep-gate forbids direct `gopkg.in/yaml`, `knadh/koanf`,
`BurntSushi/toml`, `spf13/viper` imports in non-test files; the loader entry
points are generic functions in `shikumi-go` (auditable via
`find_references("shikumi.Load")`).
*Demonstrated by:* `main` calls
`path, _ := shikumi.New("myapp").EnvOverride("MYAPP_CONFIG").Discover()` then
`store, _ := shikumi.LoadStore(path, "MYAPP_", Config{Port: 8080})`, with no
other config-parsing code.

**CFG-03** — Discovery precedence is FIXED, exactly as `shikumi-go` implements it,
highest first: (1) the `APP_CONFIG` env-override path; (2)
`$XDG_CONFIG_HOME/{app}/{app}.{ext}`; (3) `$HOME/.config/{app}/{app}.{ext}`; (4)
any explicit `Dirs(...)`; (5) legacy `$HOME/.{app}` and `$HOME/.{app}.{ext}`.
Within a directory, formats follow `Formats(...)` order (default
`Yaml, Yml, Toml`). Tools MUST NOT add ad-hoc search paths outside `Dirs(...)`,
and MUST name the override env var `{APP}_CONFIG`.
*Why:* a fixed, documented precedence lets an operator answer "which file is
winning?" purely from the standard — XDG-first with a single escape hatch and a
documented legacy tail, matching the Rust crate. Composes with
[NAME-08](#dimension-naming-name).
*Enforcement:* `shikumi-go`'s `Discovery.candidates()` is the only path-
construction code (precedence by construction); the analyzer asserts the
`EnvOverride` arg matches `^[A-Z0-9]+_CONFIG$`; a `--print-config-path` smoke test
asserts `DiscoverAll()` matches the documented order.
*Demonstrated by:* the example sets `EnvOverride("MYAPP_CONFIG")` and
`Dirs("/etc/myapp")`; its README reproduces the five-step precedence verbatim.

**CFG-04** — The provider/layer chain is FIXED at `defaults to env (PREFIX_) to
file`, with LATER layers winning (the file has highest precedence). Defaults MUST
be supplied as the `defaults T` value passed to `shikumi.Load`/`LoadStore` — NOT
via `init()` mutation, package globals, or `os.Setenv`. The env prefix MUST be
`{APP}_`, and env keys map onto `yaml` tags case-insensitively with `_` as the
nesting delimiter (`MYAPP_DB_HOST` to `db.host`).
*Why:* three layers, one direction, no surprises; shikumi coerces env strings into
the field's real type (`WeaklyTypedInput`), so `MYAPP_PORT=9090` becomes
`int(9090)`, the same serde/figment behavior as the Rust crate. Composes with
[NAME-07](#dimension-naming-name)/[NAME-09](#dimension-naming-name)/[CFG-06](#dimension-configuration-cfg).
*Enforcement:* layer order enforced by construction in `Load[T]` (env first, file
merged over it, both decoded into a copy of `defaults`); the analyzer asserts the
prefix matches `^[A-Z0-9]+_$` == `{APP}_`; defaults-as-globals caught by the
no-`os.Setenv`/no-`init`-mutation grep-gate.
*Demonstrated by:* `LoadStore(path, "MYAPP_", Config{Port: 8080})` passes the
default; a table-test asserts no-file/no-env to 8080, `MYAPP_PORT=9090` to 9090,
env+file to file wins.

**CFG-05** — All config struct fields decoded from files MUST use the `yaml`
struct tag (the shikumi-go `structTag` constant), even when the on-disk format is
TOML. Field names in YAML/TOML MUST match the tag exactly. Mixing
`json:`/`toml:`/`mapstructure:` tags on config fields, or omitting tags on
multi-word fields, is FORBIDDEN.
*Why:* shikumi-go uses ONE tag (`yaml`) to drive both file decoding and env-key
mapping, pinning it on `UnmarshalConf{Tag: structTag}` to defeat a koanf v2
footgun ([CFG-06](#dimension-configuration-cfg)); a field whose tag differs from
its lowercased Go name decodes correctly ONLY because the tag is honored. Composes
with [NAME-09](#dimension-naming-name).
*Enforcement:* the analyzer rejects `json:`/`toml:`/`mapstructure:` tags on any
`Load`/`LoadStore` type and rejects exported multi-word config fields with no
`yaml` tag; shikumi-go hard-codes `TagName: structTag` and `Tag: structTag`, so
any other tag family is ignored at runtime — the CI gate turns that silent
failure into a build failure.
*Demonstrated by:* the example includes a deliberately non-lowercase-matching
`PausePods []string \`yaml:"saasDeploymentsToPause"\`` with a CI test proving it
decodes from a `saasDeploymentsToPause:` YAML key.

**CFG-06** — Tools MUST NOT replicate, fork, or work around shikumi-go's koanf
decoding internals. If a decoding need is unmet (a new format, a custom
coercion), the fix MUST be a typed enhancement upstreamed into shikumi-go, never a
per-tool `mapstructure.DecoderConfig` or a local koanf invocation.
*Why:* shikumi-go's `store.go` documents a sharp koanf v2 footgun — koanf
overwrites `DecoderConfig.TagName` to `"koanf"` unless `UnmarshalConf.Tag` is also
set, silently dropping the `yaml` mapping; every hand-rolled decoder re-steps on
it. Centralizing the workaround once is the prime-directive "extract the shared
shape" applied to the loader.
*Enforcement:* a grep-gate forbids `mapstructure.DecoderConfig`, `koanf.New`,
`koanf.UnmarshalConf` outside `shikumi-go`; new needs are gated to a shikumi-go
PR; `find_references` shows shikumi-go as the sole decoder owner.
*Demonstrated by:* the example has no decoder configuration of its own; the
footgun is covered exactly once, in shikumi-go's `Load[T]`.

**CFG-07** — Secret values MUST NOT be stored as plaintext `string` fields in the
config struct. Any secret configuration value MUST be modeled as a typed
reference (a `SecretRef`, mirroring `cofre-types::SecretRef`: a slug `name`, a
`backend`, optional `generation`/`rotation` policy) that names WHERE the secret
lives, never the secret itself. The config file and struct carry the reference;
plaintext is materialized at point-of-use only.
*Why:* a plaintext secret in a config struct is a plaintext secret in logs, core
dumps, `String()` output, and VCS diffs; cofre's premise is that "the operator
never sees a single secret byte" — the `SecretRef` is the typed pointer and
materialization happens through cofre/cofre-types so plaintext never leaves
process memory except into an encrypted destination. Composes with
[CFG-08](#dimension-configuration-cfg)/[CFG-09](#dimension-configuration-cfg) and
[SEC-11](#dimension-security-and-supply-chain-sec).
*Enforcement:* the analyzer flags config fields whose name matches
`(?i)(password|secret|token|api[_-]?key|credential|private[_-]?key)` typed as
bare `string` (must be `SecretRef`); `SecretRef` has no exported plaintext
accessor; cofre `verify` asserts every declared `SecretRef` resolves in its
backend.
*Demonstrated by:* the config declares `DBPassword SecretRef
\`yaml:"dbPassword"\`` (not `string`), and its `secrets.yaml` is a
`SecretMaterializationPlan` consumed by `cofre apply`; no plaintext password
appears in any committed file.

**CFG-08** — Secrets MUST NEVER be logged, printed, or included in error messages.
The config struct (or any secret-bearing sub-type) MUST implement
`LogValue() slog.Value` and `String()` to redact secret fields, and all logging
MUST go through `logging-go`. Logging a whole `Config`, a `SecretRef`'s resolved
value, or an `AuthResult.Credentials` map at any level is FORBIDDEN.
*Why:* implementing `slog.LogValuer` makes redaction structural — a secret cannot
be accidentally serialized even if someone logs the whole struct; `errors-go`'s
typed `Error` carries machine codes precisely so error reporting needs no
plaintext context. Never-log-secrets is the non-negotiable safety floor. Composes
with [OBS-01](#dimension-observability-obs)/[OBS-09](#dimension-observability-obs).
*Enforcement:* the analyzer flags any logging/`printf` of a `Config`/`SecretRef`/
`AuthResult` that does not implement redacting `slog.LogValuer`; secret types
implement `LogValue()`/`String()` returning `"[REDACTED]"`, verified by a unit
test asserting no secret bytes in the rendered line; logging-go is the only
sanctioned logger.
*Demonstrated by:* `Config` implements `func (c Config) LogValue() slog.Value`
redacting `DBPassword`; a CI test logs the full config and asserts
`"dbPassword":"[REDACTED]"` and never the materialized value.

**CFG-09** — `SecretRef` materialization (resolving a reference to a live value)
MUST occur as late as possible — at the point of use — through the
cofre/cofre-types path or, for auth credentials, through cli-go's
`AuthResolver.Resolve`/`materialize`. The materialized plaintext MUST be held in
the narrowest possible scope, never re-stored into the config struct, never
cached in a package global, and never returned up the call stack as a plain
`string`.
*Why:* late, narrow-scope materialization minimizes the blast radius of a leak and
keeps the config struct itself secret-free
([CFG-07](#dimension-configuration-cfg)); cli-go's `materialize` already models
this by producing credentials on demand rather than persisting them. Composes with
[CFG-14](#dimension-configuration-cfg).
*Enforcement:* the resolved-secret type is returned only from
`AuthResolver.Resolve`/a cofre call and is not assignable back into a config field
(config fields are `SecretRef`); the analyzer flags assignment of a materialized
value into a package var or back into config; `find_references` on the materialize
entry points confirms request/operation-scope call sites.
*Demonstrated by:* the service calls `resolver.Resolve(cfg.AuthMethod)` inside the
request handler (not at startup), using the returned `AuthResult` for that
operation only; the `SecretRef` is never mutated.

**CFG-10** — Every config struct MUST provide a `Validate() error` method
checking all invariants (required fields, ranges, mutually-exclusive options,
well-formed `SecretRef` names) and returning `errors-go` typed `Error`s with
machine codes via `errors.WithCode(...)`. Validation MUST be invoked immediately
after `shikumi.Load`/`LoadStore` and on every hot-reload
([CFG-11](#dimension-configuration-cfg)) BEFORE the new config is published. An
invalid config at startup MUST be fatal; an invalid config on reload MUST be
rejected (the prior valid config stays live).
*Why:* loading without validating defers config errors to runtime — the opposite
of the no-gaps goal; `errors-go` gives a single typed `Error` so a failure is
machine-classifiable (e.g. `E_CONFIG_INVALID`); rejecting bad reloads is what
makes hot-reload safe. Composes with the [Errors](#dimension-errors-err) dimension
and [LIFE-12](#dimension-lifecycle-and-health-life).
*Enforcement:* the analyzer requires a `Validate() error` on every
`Load`/`LoadStore` type returning `errors.New`/`Wrap` with a `WithCode`; a unit
test drives one invalid fixture per invariant asserting `errors.CodeOf`; the
reload path runs a "bad reload is rejected, old config survives" test.
*Demonstrated by:* `Config.Validate()` returns
`errors.New("port out of range", errors.WithCode("E_CONFIG_PORT"), errors.WithSeverity(errors.Fatal))`;
`main` calls it after `Load` and exits non-zero on error.

**CFG-11** — Long-running services/daemons MUST use `shikumi.LoadStore` (never
one-shot `shikumi.Load`) and MUST install `store.Watch(ctx, onReload)` for
hot-reload, calling `store.Close()` on teardown. All runtime config reads MUST go
through `store.Get()` (a lock-free `*Config` snapshot); the returned pointer MUST
be treated as read-only and a fresh `Get()` MUST be called per operation rather
than captured at startup. One-shot CLI tools (cli-go) MUST use `shikumi.Load` and
MUST NOT install a watcher.
*Why:* shikumi-go's `Store` is the ArcSwap analog — `Get()` never blocks and
`Reload`/`Watch` atomically swap; the watcher is symlink-aware (watches the parent
dir for Write/Create/Rename, debounced 150ms) precisely so nix-darwin/Nix store-
symlink swaps trigger a reload; capturing one pointer at startup defeats
hot-reload. Composes with [LIFE-02](#dimension-lifecycle-and-health-life)/
[LIFE-04](#dimension-lifecycle-and-health-life).
*Enforcement:* the analyzer flags one-shot `Load` in a `package main` that also
imports lifecycle-go (a service), a captured `store.Get()` stored in a field/
global, and a `Watch` without a paired `defer store.Close()`; the Watch callback
must invoke `Validate` ([CFG-10](#dimension-configuration-cfg)).
*Demonstrated by:* the daemon does
`store.Watch(ctx, func(c *Config, err error){...})`, defers `store.Close()`, and
every handler calls `cfg := store.Get()` at entry; a CI test mutates the file and
asserts a subsequent `Get()` reflects the change.

**CFG-12** — Hot-reload reload-ability MUST be explicitly classified per field.
Every config struct MUST document (in field doc comments and the schema doc,
[CFG-13](#dimension-configuration-cfg)) whether each field is HOT (takes effect on
next `Get()`), WARM (requires a component restart triggered by the reload
callback), or COLD (requires a full process restart). COLD fields changed at
reload MUST be detected in `onReload` and surfaced as a logged warning instructing
an operator restart; they MUST NOT be silently ignored. A field whose reload
class CHANGES between binary versions (e.g. HOT in v1, COLD in v2) is a breaking
compatibility event: the change MUST bump the config `schema_version`
([CFG-15](#dimension-configuration-cfg)), be release-noted
([VER-08](#dimension-versioning-and-compatibility-ver)), and surface in the
[CFG-13](#dimension-configuration-cfg) schema-doc diff — so a v2 binary never
silently hot-applies a value the operator's v1 expectation said was bound at
startup.
*Why:* hot-reload without a stated reload contract is a trap (an operator edits a
port — COLD, listener already bound — and assumes it took effect); the no-gaps
demand means "what happens when I change this field on a running daemon" must be
answerable from the standard, INCLUDING across a binary upgrade where the field's
reload class may have changed. Composes with [CFG-11](#dimension-configuration-cfg)/
[CFG-15](#dimension-configuration-cfg)/[OBS-08](#dimension-observability-obs).
*Enforcement:* the analyzer requires a `// reload: hot|warm|cold` marker on every
field and its rendering in the schema doc; the `onReload` callback must compare
old vs new for COLD fields and emit a warning; a CI test changes a COLD field on a
live store asserting the warning + unchanged behavior until restart; the
`gen-config-docs` diff ([CFG-13](#dimension-configuration-cfg)) surfaces a
reload-class change between versions and fails the build if it lacks a
`schema_version` bump + a release note.
*Demonstrated by:* `Config` annotates `// reload: cold` on `Port` and
`// reload: hot` on `LogLevel`; the callback re-applies `LogLevel` to the
logging-go logger immediately and logs `"port change requires restart"` when
`Port` differs.

**CFG-13** — Every repo MUST ship machine-generated config schema documentation
derived from the Go struct (NOT hand-maintained): a `docs/config.md` table (field
path, `yaml` key, type, default, required?, reload class, secret?) and a committed
`config.schema.json` (JSON Schema) plus a fully-commented `config.example.yaml`.
These MUST be regenerated and diff-checked in CI so the docs never drift.
*Why:* a config schema doc IS the configuration-dimension boundary of
communication; generating it from the single typed struct
([CFG-01](#dimension-configuration-cfg)) guarantees it is gapless and current
(hand-written config docs rot on the next field); the example + JSON Schema let an
operator author and validate config without reading Go. Composes with
[DOC-13 (config docs)](#dimension-documentation-and-discoverability-doc) and
[CFG-03](#dimension-configuration-cfg).
*Enforcement:* a `todoku-go`/`pleme-actions-shared-go` generator
(`gen-config-docs`) reflects the `Config` struct (reading `yaml` tags, defaults,
the `// reload:`/`// secret:` markers, `Validate` constraints) and emits the three
artifacts; CI runs the generator and fails on any diff against the committed
files; a `--print-schema` subcommand emits the live JSON Schema for the
[CFG-03](#dimension-configuration-cfg) smoke test.
*Demonstrated by:* the repo commits `docs/config.md`, `config.schema.json`, and
`config.example.yaml`, all produced by `go run ./cmd/gen-config-docs`; CI asserts
`git diff --exit-code` is clean and the example validates against the schema.

**CFG-14** — The complete startup configuration flow MUST follow ONE fixed
sequence, wired through the mandated libs in this order: (1)
`shikumi.New(...).Discover()` to a path; (2)
`shikumi.LoadStore[Config](path, prefix, defaults)` to a store; (3)
`store.Get().Validate()` (fatal on error); (4) `logging.New(...)` configured FROM
the validated config (level/format), so the logger reflects config from the first
line; (5) `lifecycle-go` registers `store.Watch`/`store.Close` as managed
start/stop hooks; (6) secrets materialized lazily at use
([CFG-09](#dimension-configuration-cfg)). Bespoke ordering, or configuring the
logger before config is validated, is FORBIDDEN.
*Why:* a single canonical wiring sequence is the keystone that makes the whole
configuration dimension gapless — every reader of any fleet service sees the same
six steps; building the logger from validated config (step 4) means there is never
a window where the service logs with un-configured defaults or logs an invalid
config; registering Watch/Close as lifecycle-go hooks ties hot-reload into the
same start/stop machinery as every subsystem. This sequence composes shikumi-go +
errors-go + logging-go + lifecycle-go + cofre into one spine; see
[LIFE-12](#dimension-lifecycle-and-health-life) for the broader eight-phase
startup it nests inside.
*Enforcement:* `pleme-actions-shared-go` provides `bootstrap.Config[T](...)` (or a
`caixa`-rendered `main`) performing steps 1–5 in order; the analyzer flags any
`package main` that calls `shikumi.LoadStore` but does NOT route through the helper
or calls `logging.New` before `Validate`; lifecycle-go's hook registry type-checks
that a registered store exposes `Close()`; a startup integration test fails fast on
an invalid config before any non-config log line is emitted.
*Demonstrated by:* `main` is ~10 lines calling
`bootstrap.Config[Config]("myapp", "MYAPP_", defaults)` returning a validated
`*shikumi.Store[Config]` and a `*slog.Logger` built from it, with `store.Watch`/
`store.Close` already registered on the lifecycle-go manager.

**CFG-15** — Every `Config` type MUST carry a `SchemaVersion int` field
(`yaml:"schema_version"`), and a breaking schema change (renaming or removing a
field, or changing a field's reload class — [CFG-12](#dimension-configuration-cfg))
MUST bump it and ship a migration. On startup `shikumi-go` compares the loaded
file's `schema_version` to the binary's current version: an OLDER version is
migrated forward via a registered `shikumi.Migration[T]` chain
(`Migrate(old) → new`, generated by `gen-config-migrate`); an UNMIGRATABLE or
NEWER version fails loud with an `errors-go`-classified error carrying a
remediation message — NEVER silent field-loss. A breaking config-schema change is
a release-noted compatibility event ([VER-08](#dimension-versioning-and-compatibility-ver))
and the schema doc ([CFG-13](#dimension-configuration-cfg)) records the version.
*Why:* a binary upgrade that renames/removes a config field would otherwise either
silently drop an operator's value or fail `Validate()` ([CFG-10](#dimension-configuration-cfg))
fatally at startup — a guaranteed upgrade outage. A versioned schema with a
typed forward-migration makes config evolution gapless: the operator's old file
is migrated or rejected with a fix, never silently misread. This closes the
config side of the upgrade scenario ([VER-13](#dimension-versioning-and-compatibility-ver)).
Composes with [CFG-10](#dimension-configuration-cfg)/[CFG-12](#dimension-configuration-cfg)/
[CFG-13](#dimension-configuration-cfg)/[VER-08](#dimension-versioning-and-compatibility-ver).
*Enforcement:* the config analyzer requires a `schema_version`-tagged field on
every `Load`/`LoadStore` type and a registered `Migration[T]` for every prior
version; `shikumi-go` runs the migration chain before `Validate` and returns a
remediation-bearing `WithCode` error on an unmigratable/newer version;
`gen-config-migrate` emits a stub migration on a detected schema break and CI
fails if a renamed/removed field has no migration; a CI test loads a fixture at
`schema_version-1` and asserts it migrates (not drops/crashes), and a fixture at
`schema_version+1` asserts a loud, classified error.
*Demonstrated by:* the example's v1 `Config` has `schema_version: 1`; renaming
`max_conns`→`pool_size` at v2 bumps it to `2`, ships
`Migrate1to2(old) Config2`, and CI shows an operator's v1 file loaded by the v2
binary migrating cleanly while a `schema_version: 3` file fails with
`E_CONFIG_SCHEMA_TOO_NEW: upgrade the binary or pin schema_version 2`.

---

## Dimension: Observability (OBS)

**OBS-01** — Every Go program (service, CLI, daemon, job, action) constructs
exactly ONE root logger via `logging.New(...)` from `logging-go` at process
startup (in `main`, or the CLI bootstrap) and installs it with
`logging.SetDefault(logger)`. No package may construct its own `slog.Logger` via
`slog.New(...)`, `slog.NewJSONHandler`, `slog.Default()`, `log.New`, or any
third-party logging library (logrus/zap/zerolog/klog except a forced vendored
upstream). Libraries obtain their logger exclusively through
`logging.FromContext(ctx)` / `logging.Default()`.
*Why:* a single logger shape is the entire premise — if any package mints its own
handler, the JSON shape, level source, and `correlation_id`/`tenant` injection all
diverge and logs stop being aggregatable at fleet scale; logging-go is the Go
counterpart to the Rust tracing/tracing-subscriber stack. Composes with
[CLI-08](#dimension-cli-ux-cli)/[CFG-08](#dimension-configuration-cfg).
*Enforcement:* forbidigo + depguard ban zap/logrus/zerolog and `slog.New`/
`NewJSONHandler`/`NewTextHandler`/`SetDefault`/`log.New`/`log.Print*` outside
logging-go; substrate `library-check.nix`/`service-flake.nix` run the linter as a
derivation check (FSM-gate: the repo cannot reach a green build), with `go vet` in
the same check.
*Demonstrated by:* the example's `main.go` shows the only `logging.New(...)` call,
immediately followed by `logging.SetDefault(logger)`; a negative fixture under
`testdata/forbidden/` with `zap.NewProduction()` fails the build.

**OBS-02** — The root logger MUST be constructed as JSON to stdout:
`logging.New(logging.WithFormat("json"), logging.WithLevelFromEnv("LOG_LEVEL"))`
(`FormatJSON` is the default). `WithFormat("text")` is permitted ONLY behind a
dev-only flag defaulting to JSON and MUST NOT be reachable in a container.
`WithWriter` MUST NOT redirect production logs to stderr, a file, or a socket;
stdout is the sole sink and the orchestrator (Vector / the K8s log pipeline) owns
shipping.

> **Note on the CLI exception.** [CLI-08](#dimension-cli-ux-cli) directs CLI
> *diagnostics* to **stderr** (so `-o json > out.json` is a clean data stream).
> This does not conflict with OBS-02's "stdout is the sole sink": OBS-02 governs
> **services/daemons** whose stdout *is* the log stream the platform ships; CLIs
> invert the writer precisely because their stdout is reserved for `cli.Render`
> data. Both are the same principle — keep the machine-consumable stream clean —
> applied to two different binary kinds.

*Why:* the 12-factor convention is logs-as-event-streams; JSON is the machine
contract and text breaks aggregation; writing to files/sockets re-implements log
shipping inside every binary.
*Enforcement:* `logging.WithFormat` defaults to JSON and `logging.New` defaults
`writer: os.Stdout` (safe == zero-config); lint asserts no `WithWriter` outside
`_test.go` (for services) and that any `WithFormat` arg is `"json"` or a
JSON-defaulting var; the container image build asserts no log-file mount.
*Demonstrated by:* the service logs
`{"time":...,"level":"INFO","msg":"handled request","status":200,"correlation_id":"req-123","tenant":"acme"}`
to stdout, captured in a golden-output test that parses the line as JSON.

**OBS-03** — The minimum log level MUST be sourced from the environment via
`logging.WithLevelFromEnv("LOG_LEVEL")` (or `WithLevelFromEnv("")` resolving to
`DefaultLevelEnv` = `LOG_LEVEL`). The default when unset is `info`. The accepted
vocabulary is exactly `debug`/`info`/`warn`(`warning`)/`error`, parsed by
`logging.ParseLevel`. Levels MUST NOT be hard-coded with
`logging.WithLevel(slog.LevelDebug)` in committed code except in tests; the
runtime level is an operational knob.
*Why:* a single well-known env var mirrors the Rust stack's one-level-variable
convention and lets operators turn up verbosity in a running pod without a
rebuild; the fixed four-level vocabulary keeps filtering uniform. Composes with
[OBS-08](#dimension-observability-obs).
*Enforcement:* `logging.ParseLevel` rejects out-of-vocabulary names and
`WithLevelFromEnv` falls back to info on an unparseable value (deterministic by
construction); lint flags `WithLevel` in non-test files and out-of-vocabulary
level literals; the config schema types a level field as a four-name enum.
*Demonstrated by:* the deployment sets `LOG_LEVEL=info` and the README documents
flipping to `debug`; a table test feeds `ParseLevel` the four names plus garbage,
asserting garbage yields `(slog.LevelInfo, error)`.

**OBS-04** — A `correlation_id` MUST be established at every inbound entry point
(HTTP/gRPC handler, queue consumer, CLI invocation, scheduled job tick) and
propagated through `context.Context` via `logging.WithCorrelationID(ctx, id)`.
Inbound requests adopt an existing upstream ID from the standard key
(`X-Correlation-ID` HTTP, `correlation-id` gRPC metadata); when absent, the entry
point MINTS one (UUIDv7 or equivalent) before any business logic. The ID MUST be
forwarded on every outbound call. The well-known record key is
`logging.CorrelationIDKey` (`"correlation_id"`) and MUST NOT be re-spelled
(`request_id`, `reqID`, `trace_id`, `cid`).
*Why:* correlation across services is impossible if the join key is missing,
minted inconsistently, or named differently; threading it through context lets
logging-go's `ContextHandler` inject it automatically (the Rust tracing-span
analog); forwarding on egress makes it a true distributed key. Composes with
[NET-12](#dimension-networking-net)/[OBS-06](#dimension-observability-obs)/
[OBS-14](#dimension-observability-obs).
*Enforcement:* a middleware library (net/http + gRPC interceptors) performs the
adopt-or-mint + `WithCorrelationID` step (CI checks the server constructor wires
it); a vet pass flags forbidden synonyms and requires `CorrelationIDKey`; the
lifecycle-go service template won't compile a handler bypassing the correlation
middleware.
*Demonstrated by:* inbound middleware reads `X-Correlation-ID`, falls back to a
fresh UUIDv7, calls `WithCorrelationID`, and the outbound client re-emits the
header — an e2e test asserts the same `correlation_id` in both the server's and
downstream stub's captured logs.

**OBS-05** — For any multi-tenant code path the `tenant` MUST be resolved at the
entry point and carried via `logging.WithTenant(ctx, tenant)` so it is injected as
`logging.TenantKey` (`"tenant"`) on every record. Tenant MUST be derived from
authenticated identity (auth claims / cli-go auth context), NEVER from an
untrusted request body. The key MUST NOT be re-spelled (`tenant_id`, `org`,
`account`, `customer`). In single-tenant tools the field is simply absent — code
MUST NOT emit `tenant="default"` or `tenant=""`.
*Why:* tenant is the second fleet-wide correlation/partition key (tenant-scoped
queries, blast-radius analysis, per-tenant billing); a consistent authenticated
source and single key name make every tenant query uniform; placeholders pollute
cardinality and falsely attribute system events.
*Enforcement:* `logging.WithTenant` ignores an empty tenant and `contextAttrs`
omits an absent tenant (no-placeholder by construction); a vet pass flags tenant
synonyms, literal `WithTenant(ctx, "default")`/`""`, and reading tenant from
`r.FormValue`/decoded request structs.
*Demonstrated by:* the multi-tenant service derives `tenant` from the validated
token in middleware; a test asserts a record carries `"tenant":"acme"` at the top
level, and a sibling single-tenant CLI emits no `tenant` key.

**OBS-06** — Inside any function holding a `context.Context`, logging MUST go
through `logging.FromContext(ctx).<Level>Context(ctx, msg, ...attrs)` — the
`*Context` slog methods (`InfoContext`, `WarnContext`, `ErrorContext`,
`DebugContext`). The plain methods (`Info`, `Warn`, `Error`, `Debug`) are
PERMITTED only in genuinely context-free spots (`init`, top-of-`main`, a
non-context library helper). Passing `context.Background()`/`context.TODO()` to a
`*Context` call solely to satisfy the signature is forbidden when a real ctx is in
scope.
*Why:* logging-go's `ContextHandler` injects `correlation_id`/`tenant` ONLY for
records carrying the active context — i.e. only via the `*Context` methods; a
plain `Info` call passes a background context and silently drops both correlation
fields, breaking aggregation. This rule realizes
[OBS-04](#dimension-observability-obs)/[OBS-05](#dimension-observability-obs) at
every call site.
*Enforcement:* a `go/analysis` vet pass errors if a logging-derived value calls a
non-`Context` level method within a function whose scope has a `context.Context`,
and flags `InfoContext(context.Background(), ...)` when a named ctx is in scope;
build-failing in the substrate go check.
*Demonstrated by:* every log call in the service body is
`logging.FromContext(ctx).InfoContext(ctx, ...)`; the only plain `logger.Info`
sits in `main` before the request context exists, annotated `// no ctx yet`.

**OBS-07** — All log payload data MUST be passed as structured key/value attribute
pairs (or `slog.Attr` via `slog.String`/`slog.Int`/`slog.Any`), never interpolated
into the `msg`. The `msg` is a fixed, low-cardinality, human-readable constant
string literal; dynamic values (IDs, counts, names, durations, statuses) go in
attributes. `fmt.Sprintf` into a log message, `+`-concatenation into `msg`, and
`%v`-formatting a struct into a single attribute are forbidden. Attribute keys are
`snake_case` and stable across calls.
*Why:* string-interpolated logs are unqueryable and unindexable — every distinct
value produces a distinct message, exploding cardinality; structured fields are
the whole point of JSON logging; a constant `msg` lets dashboards group on
message; `snake_case` matches the injected `correlation_id`/`tenant`.
*Enforcement:* a `go/analysis` vet pass flags a non-constant first arg to any slog
level method, `fmt.Sprintf`/concat reaching `msg`, and non-`snake_case` literal
keys; golangci-lint `sloglint` (key-naming=snake, no-mixed-args, static-msg)
enabled in the substrate go check.
*Demonstrated by:* the example logs
`InfoContext(ctx, "handled request", "status", 200, "latency_ms", elapsed.Milliseconds())`
— constant msg, snake_case keys; a negative `Infof`-style fixture fails
`sloglint`.

**OBS-08** — Log level discipline is fixed and uniform: DEBUG = developer detail
off in prod by default; INFO = normal lifecycle/business milestones an operator
wants in steady state; WARN = degraded-but-handled (a retry, a fallback, a
near-limit, an `errors.SeverityWarning`); ERROR = an operation FAILED and a human
may need to act (`errors.SeverityError`). A log call's level MUST agree with the
`errors-go` severity of any error it carries via the canonical mapping
(Notice→Info, Warning→Warn, Error→Error). Expected, handled control-flow (e.g. a
not-found routed to a 404) MUST NOT be logged at ERROR.
*Why:* level inflation destroys alerting signal-to-noise; level deflation hides
incidents; binding log level to the `errors-go` severity ladder makes the two
observability surfaces consistent by construction. Composes with the
[Errors](#dimension-errors-err) dimension and [ERR-11](#dimension-errors-err).
*Enforcement:* `logging.LogError(ctx, logger, msg, err, attrs...)` reads
`errors.SeverityOf(err)` and dispatches to the matching `*Context` method; a vet
pass flags an `ErrorContext` carrying a Notice/Warning error and `ErrorContext` on
a non-failure return.
*Demonstrated by:* the failure path calls
`logging.LogError(ctx, log, "reconcile failed", err, "step", name)` where `err` is
`errors.Wrap(..., WithSeverity(errors.SeverityError))`, emitting at ERROR with
`code` from `errors.CodeOf`; the warning path logs a recovered retry at WARN.

**OBS-09** — When logging an error, attach it via the structured `err`/`error`
attribute carrying `err.Error()` and additionally emit `code` =
`errors.CodeOf(err)` (when non-empty) and `severity` =
`errors.SeverityOf(err).String()`, all from `errors-go`. The error MUST NOT be
folded into `msg`. An error MUST be logged AT MOST ONCE on its path — log-and-
return is forbidden (either log it OR wrap-and-return via `errors.Wrap`, never
both), and the final logging happens at the outermost boundary deciding the
outcome.
*Why:* logging the wrap chain + machine `code` + `severity` gives operators a
single greppable, classifiable record (the Go analog of anyhow context + thiserror
codes); double-logging the same error at every wrap layer produces duplicate
records and inflated counts. Composes with [ERR-09](#dimension-errors-err)/
[ERR-11](#dimension-errors-err)/[CFG-08](#dimension-configuration-cfg).
*Enforcement:* `logging.LogError` emits `err`/`code`/`severity` in one shape; a
vet pass flags the log-and-return antipattern (an ERROR/WARN call whose argument
error is also the function's returned value in the same block); `sloglint`
enforces the `err` key; the shared error-wrapping lint ensures `errors.Wrap` is
used for propagation.
*Demonstrated by:* the service logs the error once in the top-level handler
(`{"level":"ERROR","msg":"request failed","err":"reconcile tenant config: not found","code":"E_NOT_FOUND","severity":"error","correlation_id":...}`)
while inner layers only `return errors.Wrap(err, "...")`.

**OBS-10** — Library packages (anything not `package main`) MUST NOT call `panic`,
`os.Exit`, or `log.Fatal*` for recoverable conditions; they return an `error`
built with `errors-go`. `panic` is reserved for programmer-invariant violations
(impossible switch case, nil the type system should have prevented). Any goroutine
a library spawns that could panic MUST install a `recover()` converting the panic
into a logged ERROR record (with `correlation_id` from the captured ctx) and a
propagated `errors.SeverityError` error — a panicking goroutine MUST NOT silently
crash the process or vanish.
*Why:* a library that panics/exits steals the lifecycle decision from
`main`/lifecycle-go and bypasses graceful teardown, structured error reporting,
and the correlation-tagged log surface; converting panics to logged, classified
errors keeps every failure inside the observability contract. Composes with
[ERR-05](#dimension-errors-err)/[LIFE-02](#dimension-lifecycle-and-health-life).
*Enforcement:* forbidigo bans `panic(`/`os.Exit(`/`log.Fatal`/`log.Panic` in
non-`main`, non-`_test.go` files (allowlisted only for documented
`//nolint:forbidigo // invariant`); the standard ships `lifecycle.Go(ctx, log, fn)`
(recover-wrapped) and a `recover`-to-`errors` helper; a vet pass flags raw
`go func()` in library code lacking the recover wrapper; the substrate go check
fails on any unguarded panic site.
*Demonstrated by:* the library returns
`errors.New("unsupported target", errors.WithCode("E_UNSUPPORTED"))` instead of
panicking; its one worker is launched via `lifecycle.Go(...)`, and a test injects
a panic asserting it surfaces as a single ERROR JSON line with `correlation_id`.

**OBS-11** — `main` (and cli-go command handlers) is the ONLY layer permitted to
terminate the process, and it MUST do so through `lifecycle-go`: derive the root
context from `lifecycle.SignalContext`, run graceful teardown through a
`lifecycle.Shutdown` constructed with the root logger
(`lifecycle.NewShutdown(logger)`), and translate the final error into an exit
code. `os.Exit`/`log.Fatal` directly from `main` mid-flight (bypassing registered
hooks and their logging) is forbidden; exit happens once, after teardown, via a
single `os.Exit(code)` at the very bottom of `main`.
*Why:* centralizing termination in lifecycle-go guarantees every binary logs its
shutdown sequence (each hook's start/failure logged), flushes buffered
observability data, and emits a final structured outcome — instead of a
`log.Fatal` that aborts mid-teardown; this is the observability counterpart of
[OBS-10](#dimension-observability-obs). Composes with
[LIFE-01](#dimension-lifecycle-and-health-life)/[LIFE-02](#dimension-lifecycle-and-health-life)/
[CLI-12](#dimension-cli-ux-cli).
*Enforcement:* forbidigo bans `log.Fatal*`/`os.Exit` except a single allowlisted
`os.Exit` at the end of `main`; the lifecycle-go bringup template requires a
`*slog.Logger` to `NewShutdown` (an un-logged teardown won't compile); CI asserts
`lifecycle.SignalContext` is the root context source.
*Demonstrated by:* `main` calls `lifecycle.SignalContext`, registers hooks on
`lifecycle.NewShutdown(logger)`, waits on `<-ctx.Done()`, runs `sd.Run(...)`, logs
the aggregated outcome, and exits with the single bottom-of-`main` `os.Exit(code)`;
a test sends SIGTERM asserting a `"msg":"shutdown complete"` INFO line precedes
exit.

**OBS-12** — Long-lived background work (reconcile passes, metric scrapes, token
refreshes) MUST run through `lifecycle.RunLoop` wired with
`lifecycle.WithLoopLogger(logger)` so every tick error and backoff decision is
logged at the disciplined level (tick errors at WARN while retrying, escalating to
ERROR only on `WithStopOnError` termination). Hand-rolled
`for { select { <-ticker.C } }` loops are forbidden, as is a RunLoop constructed
without a logger (which silently discards tick failures via slog's discard
handler).
*Why:* a periodic loop that swallows tick errors is the most common silent-failure
shape in services; forcing it through RunLoop + WithLoopLogger guarantees each
failed cycle is a structured, leveled, correlatable record and backoff is visible.
Composes with [LIFE-08](#dimension-lifecycle-and-health-life)/[LIFE-09](#dimension-lifecycle-and-health-life).
*Enforcement:* a vet pass flags raw ticker/`time.Tick` loops in non-test code
requiring `lifecycle.RunLoop`, and flags a RunLoop omitting `WithLoopLogger`
(would default to `slog.DiscardHandler`); the substrate go check fails on either.
*Demonstrated by:* the reconcile loop is
`lifecycle.RunLoop(ctx, 30*time.Second, reconcile, lifecycle.WithLoopLogger(logging.FromContext(ctx)), lifecycle.WithBackoff(5*time.Minute))`;
a test forces consecutive tick errors asserting each produces a WARN line with a
`backoff_ms` attribute.

**OBS-13** — Services (`package main` serving traffic) MUST expose a metrics
surface and a health surface: health/readiness via lifecycle-go's
`lifecycle.Registry`/`Probe` (`/healthz`, `/readyz`), and runtime metrics (RED:
request rate, error rate, duration; plus Go runtime metrics) via a
Prometheus-compatible `/metrics` endpoint scraped by the platform Vector pipeline
(VictoriaMetrics for homelab, Datadog APM for SaaS). Metric names, labels, and the
`correlation_id` exemplar linkage are declared, not ad-hoc. Pure libraries and
one-shot CLIs do NOT expose `/metrics` (no scrape lifecycle) but MUST still emit
the structured logs of [OBS-01](#dimension-observability-obs)..[OBS-12](#dimension-observability-obs).
*Why:* logs answer "what happened to this request", metrics answer "what is the
aggregate rate/error/latency", health answers "should the orchestrator route
to/restart me"; reusing lifecycle-go's probe registry keeps every service's health
endpoints byte-identical and a declared metric schema keeps dashboards/alerts
stable; exempting libs/CLIs prevents over-instrumenting things with no scrape
loop. Composes with [LIFE-05](#dimension-lifecycle-and-health-life)/[NET-10](#dimension-networking-net).
*Enforcement:* the substrate `service-flake.nix`/`grpc-service.nix` archetype
requires mounting `lifecycle.Registry.Handler()` and a `/metrics` handler (typed
required `health`/`metrics` blocks); the generated Helm chart (caixa-helm)
declares the scrape annotations / ServiceMonitor and CI asserts chart-port ==
code-port; libs/CLIs are built via `library-flake.nix`/`tool.nix` which don't
require these.
*Demonstrated by:* the SERVICE example registers
`reg.Register("db", lifecycle.ProbeFunc(db.PingContext))`, serves `reg.Handler()`
and a RED-metrics `/metrics`, and ships a HelmRelease with scrape annotations; the
LIBRARY and CLI examples expose neither, documented as "no scrape lifecycle".

**OBS-14** — Distributed traces, when present, MUST share the request's
`correlation_id`: the trace/span context (OpenTelemetry `trace_id`) and the
logging `correlation_id` MUST be mutually discoverable — emit the active
`trace_id`/`span_id` as structured attributes on records inside a span, and seed
the trace's baggage/attributes with the `correlation_id` and `tenant` from
context. Tracing instrumentation MUST be initialized once at startup alongside the
logger (same `main`/bootstrap site) and flushed in a registered
`lifecycle.Shutdown` hook. `correlation_id` remains the canonical join key even
without tracing; tracing is additive, never a replacement for
[OBS-04](#dimension-observability-obs).
*Why:* logs, metrics, and traces are only useful together when they share join
keys; if `trace_id` and `correlation_id` live in separate universes, an operator
who finds a slow trace cannot pivot to that request's logs; flushing traces in a
teardown hook prevents losing the last spans (the trace analog of
[OBS-11](#dimension-observability-obs)).
*Enforcement:* where the OTel SDK is imported, a vet pass requires tracer init at
the `logging.New` site, a `lifecycle.Shutdown` hook named `tracing` calling the
provider `Shutdown`, and span-scoped records carrying `trace_id`; the
`logging`+otel bridge helper injects `trace_id`/`span_id` and copies
`correlation_id`/`tenant` into span attributes; CI fails if otel is wired without
the flush hook.
*Demonstrated by:* the traced service initializes the tracer in `main` next to
`logging.New`, registers `sd.Add("tracing", tp.Shutdown)`, and logs
`{"trace_id":"...","correlation_id":"req-123",...}` while the span carries matching
attributes — a test asserts the log's `trace_id` equals the span's and the span's
`correlation_id` attribute equals the log's.

---

## Dimension: Errors (ERR)

**ERR-01** — Every Go repo MUST depend on `errors-go` (imported with the alias
`errs`) as the single error-construction and error-inspection surface. All error
VALUES originating in org code MUST be produced by `errs.New`, `errs.Wrap`, or
`errs.Join`. The stdlib `errors` package MAY be imported ONLY for the inspection
verbs `errors.Is`, `errors.As`, `errors.Unwrap` (never `errors.New`/`fmt.Errorf`
for org-originated errors). `fmt.Errorf` with `%w` is FORBIDDEN — `errs.Wrap` is
its only sanctioned replacement because it additionally threads Severity and Code.
*Why:* a single concrete error type (`Error`) makes the fleet navigable — any
error can be asked `SeverityOf`/`CodeOf` and participates in `Is`/`As`; two
parallel error models create the exact gap the GSDS closes; `fmt.Errorf("%w")`
silently produces a chain with no severity. Composes with
[CLI-09](#dimension-cli-ux-cli)/[CLI-10](#dimension-cli-ux-cli)/the whole
[Observability](#dimension-observability-obs) dimension.
*Enforcement:* `gsds-errors-lint` (a Rust binary in `substrate/lib/build/go`) runs
go/analysis passes: forbid `fmt.Errorf` with `%w` or returned-as-error; forbid
stdlib `errors.New` in non-test files; require `errors-go` in `go.mod` of any
module returning `error`; wired as a check derivation so `nix build` fails too.
*Demonstrated by:* the example imports `errs "github.com/pleme-io/errors-go"` and
stdlib `errors` side-by-side; every error-producing `return` uses `errs.Wrap`,
every `errors.Is` uses stdlib verbs.

**ERR-02** — Sentinel errors MUST be declared as package-level
`var Err<Name> = errs.New("<message>", errs.WithCode("E_<SCREAMING_SNAKE>"))`. The
variable name MUST start with `Err`; the message MUST be lowercase, no trailing
punctuation, no leading `error:`; the code MUST be a stable, machine-readable
`E_`-prefixed token that NEVER changes once published (it is a contract).
Sentinels MUST be defined with `errs.New` (a leaf, no cause), never `errs.Wrap`.
*Why:* sentinels are the typed `thiserror` analog — callers match them with
`errors.Is` across wrap layers, and dashboards/automation match on the stable
`E_` code via `errs.CodeOf`; a drifting code breaks every downstream matcher
silently, so it is an API break. Composes with [ERR-09](#dimension-errors-err)/
[VER-07](#dimension-versioning-and-compatibility-ver).
*Enforcement:* `gsds-errors-lint` AST pass requires any package-level `errs.New`
var to be `Err`-prefixed with a `WithCode` matching `^E_[A-Z0-9_]+$`; a
`gsds-error-codes.yaml` manifest is validated against source; removing/renaming a
published code fails CI as a breaking change.
*Demonstrated by:* the example defines
`var ErrTenantNotFound = errs.New("tenant not found", errs.WithCode("E_TENANT_NOT_FOUND"))`,
listed in `gsds-error-codes.yaml`, with a test asserting
`errs.CodeOf(ErrTenantNotFound) == "E_TENANT_NOT_FOUND"`.

**ERR-03** — Every error crossing a function boundary MUST be wrapped with
`errs.Wrap(err, "<intent>")` adding context describing WHAT THE CALLER WAS
ATTEMPTING, in lowercase, no trailing punctuation, no embedding of the wrapped
error's text (errors-go renders the `context: cause` chain itself). Bare
`return err` is permitted ONLY when the function adds no new context (a pure
pass-through) AND the called function is itself org code that already wrapped.
Re-wrapping with the same message at consecutive layers is FORBIDDEN.
*Why:* wrapping at every boundary is the `anyhow .context(...)` discipline,
producing a single-line failure narrative from outermost intent to root cause
without losing `Is`/`As` reachability; embedding the cause's text by hand
double-renders the chain. Composes with [OBS-09](#dimension-observability-obs).
*Enforcement:* `gsds-errors-lint` flags an `errs.Wrap` message containing `: `,
ending in punctuation, containing `%`, or concatenating `err.Error()` (error
severity), and an exported pass-through lacking a wrap (warning, reviewer-gated).
*Demonstrated by:* the example shows
`if err := loadConfig(path); err != nil { return errs.Wrap(err, "load gateway config") }`
producing `reconcile tenant: load gateway config: open /etc/x: no such file`,
asserted verbatim in a test.

**ERR-04** — Severity MUST be set with `errs.WithSeverity(...)` ONLY at the point
an error is FIRST classified (the leaf `errs.New`, or the first `errs.Wrap` that
re-classifies). Context-only wraps (the common case) MUST NOT pass `WithSeverity`
— they inherit the cause's severity. The three rungs have fixed meanings:
`SeverityNotice` = informational; `SeverityWarning` = degraded-but-operating;
`SeverityError` = outright failure (the default). Re-classifying a failure
DOWNWARD (Error→Warning/Notice) at a wrap boundary is FORBIDDEN unless the
wrapping function genuinely recovers the operation.
*Why:* errors-go makes failures loud by default (`DefaultSeverity = SeverityError`)
and makes `Wrap` inherit severity so context-only wrapping never silently
downgrades; arbitrary re-classification would let an outer layer paper over a real
failure. Composes with [OBS-08](#dimension-observability-obs)/[CLI-09](#dimension-cli-ux-cli).
*Enforcement:* `gsds-errors-lint` flags an `errs.Wrap` whose `WithSeverity` lowers
a statically-known cause severity (error) and requires a `//gsds:reclassify
<reason>` comment on any severity-bearing wrap; a property test asserts
`SeverityOf(Wrap(e,"ctx")) == SeverityOf(e)` for the no-option path.
*Demonstrated by:* a quota probe produces
`errs.New("cache 90% full", errs.WithSeverity(errs.SeverityWarning))`; an outer
`errs.Wrap(err, "refresh cache")` carries no severity option, and a test asserts
the warning propagates out.

**ERR-05** — Libraries (any module whose `caixa` kind is `Biblioteca`, or any
non-`main` package) MUST RETURN errors and MUST NOT decide process disposition: no
`os.Exit`, no `log.Fatal`/`log.Panic`, no `panic` for ordinary failures, and no
direct writes to `os.Stderr` for error reporting. Libraries express disposition
ONLY through the returned error's Severity and Code. The single allowed `panic` is
for programmer-invariant violations that can never occur with correct usage,
documented as `// panics if` on the exported symbol.
*Why:* "libraries return, binaries decide" keeps the fleet composable — a library
that calls `os.Exit` cannot be embedded, tested, or wrapped; carrying Severity/Code
hands the binary everything it needs to decide the exit code without owning the
decision. Composes with [OBS-10](#dimension-observability-obs)/[ERR-06](#dimension-errors-err).
*Enforcement:* `gsds-errors-lint` for any non-`main` package forbids
`os.Exit`/`log.Fatal*`/`log.Panic*`, forbids `panic(` except preceded by a
`//gsds:invariant` comment, and forbids `fmt.Fprint*(os.Stderr,...)`; the
`caixa.lisp` kind `Biblioteca` selects the strict profile; build fails via
`library-check.nix`.
*Demonstrated by:* the library returns `errs.Wrap(...)` from every fallible
function and has zero `os.Exit`/`Fatal`/`Stderr`; its one `panic` sits behind a
`//gsds:invariant unreachable: severity ladder is closed` comment.

**ERR-06** — Binaries (packages named `main`, `caixa` kind
`Binario`/`Servico`/`Supervisor`) MUST funnel ALL termination through ONE
`func main()` that calls a single inner `func run(ctx) error` and translates its
returned error to a process exit code via the mandated `errs.ExitCode(err)` mapper
(provided by errors-go / re-exported by cli-go). `main` MUST contain no business
logic, exactly one `os.Exit` call site, and MUST NOT call `log.Fatal`. The exit
code is derived from the error's Severity and Code, never hand-assigned per call
site.
*Why:* a single exit funnel makes a binary's failure behavior knowable from one
place; scattering `os.Exit(1)`/`log.Fatal` reintroduces the gap (deferred
functions don't run on `os.Exit`, codes drift); deriving the code from
Severity/Code keeps the decision a pure function of the library's returned value
([ERR-05](#dimension-errors-err)). Composes with [CLI-09](#dimension-cli-ux-cli)/
[CLI-12](#dimension-cli-ux-cli)/[OBS-11](#dimension-observability-obs).
*Enforcement:* `gsds-errors-lint` strict-binary profile: at most ONE `os.Exit`
(in `func main`); forbid `os.Exit`/`log.Fatal*` elsewhere; require a `run(...)
error` indirection and a call to `errs.ExitCode`; the `caixa-validate` lifecycle
gate refuses to advance a `Binario` to `publishable` unless the funnel shape is
detected.
*Demonstrated by:* the binary's `main.go` is
`func main(){ if err := run(context.Background(), os.Args); err != nil { logging.Default().Error("fatal", "err", err, "code", errs.CodeOf(err)); os.Exit(errs.ExitCode(err)) } }`.

**ERR-07** — The error→exit-code mapping is FIXED and provided by
`errs.ExitCode(err) int`, the only mapper used fleet-wide: nil → 0;
`errors.Is(err, cli.ErrHelp)` or `cli.ErrNoCommand` after usage was printed → 0;
otherwise the base code is keyed off `errs.SeverityOf(err)` — `SeverityNotice`
→ 0, `SeverityWarning` → 0 (degraded but the operation completed),
`SeverityError` → non-zero. Within `SeverityError`, a configurable
`gsds-exit-codes.yaml` maps specific `errs.CodeOf(err)` tokens to distinct codes in
the 1–125 range (126/127/128+ reserved for shell/OS); any unmapped error falls
back to `1`. Code `2` is reserved for usage/parse errors (cli flag errors).

> **Note on the two exit taxonomies.** [CLI-09](#dimension-cli-ux-cli) describes
> the CLI-facing exit codes (64/70/75/130 — the BSD `EX_*` family that cli-go
> emits), while ERR-07 describes the library-level `errs.ExitCode` mapper
> (severity-keyed, YAML-extensible). These are **layered, not contradictory**:
> `cli.ExitCode` ([CLI-09](#dimension-cli-ux-cli)) is the cli-go wrapper that maps
> the cli-go sentinels (`ErrHelp`→0, `ErrNoCommand`/usage→64) and otherwise
> delegates to / aligns with `errs.ExitCode` for the severity-keyed rungs. A repo
> uses `cli.Exit` for CLIs (which composes both) and `errs.ExitCode` directly for
> non-cli-go binaries. Both are total and both treat success/help as 0 and a
> `SeverityError` as non-zero.

*Why:* a stable, single-sourced exit-code table is the contract between a binary
and its CI/orchestration callers (todoku-go, shigoto-go, pleme-actions); keying off
Severity first (so Warning never fails a pipeline) and Code second (so specific
failures get specific codes) is the gapless rule; the YAML lets repos extend
without forking the mapper.
*Enforcement:* errors-go ships `ExitCode` with an exhaustive Severity `switch`
(compile-checked via the `exhaustive` linter); `gsds-errors-lint` forbids any
`os.Exit(<int>)` other than `os.Exit(errs.ExitCode(...))`/`os.Exit(0)`; a golden
test asserts the full table; `gsds-exit-codes.yaml` is schema-validated.
*Demonstrated by:* the example includes `gsds-exit-codes.yaml` mapping
`E_TENANT_NOT_FOUND: 3`, and a table test asserts
`errs.ExitCode(ErrTenantNotFound)==3`, `nil==0`, `warningErr==0`,
`cli.ErrHelp==0`.

**ERR-08** — No swallowed errors. Every value of type `error` MUST be inspected:
returned, wrapped-and-returned, joined via `errs.Join`, or — only as a deliberate
terminal decision — logged AND explicitly discarded with `_ = err` accompanied by
a mandatory `//gsds:ignore <reason>` comment. Assigning an error to `_` without
the comment, dropping a fallible call's error result, or an empty
`if err != nil {}` body are all FORBIDDEN. Deferred `Close()`/`Flush()` whose
error matters MUST capture it (named-return aggregation or `errs.Join`).
*Why:* the swallowed error is the single most common way the contract is broken —
a dropped error means a failure is invisible and the severity/exit-code machinery
never runs; an explicit, commented `//gsds:ignore` makes every intentional discard
a reviewable, greppable decision. Composes with [ERR-10](#dimension-errors-err)/
[NET-07](#dimension-networking-net).
*Enforcement:* `errcheck` (`-blank -asserts`) fails on any unchecked error; a
custom pass requires a `//gsds:ignore` comment on any `_ = <err>`; empty
`if err != nil {}` blocks flagged; deferred fallible calls in named-error-return
functions must aggregate; wired as a failing check derivation.
*Demonstrated by:* a best-effort emit reads
`_ = emitMetric(ctx, m) //gsds:ignore best-effort telemetry, failure must not abort reconcile`;
a `defer func(){ err = errs.Join(err, f.Close()) }()` captures the close error;
`errcheck` passes clean.

**ERR-09** — Error identity MUST be matched with `errors.Is` (sentinels) or
`errors.As` (typed/structured errors), NEVER by string comparison of `err.Error()`
and NEVER by direct `==` against anything but a documented sentinel. Machine
branching on a category MUST use `errs.CodeOf(err) == "E_..."` against a published
code, not substring matching of the message. Typed errors carrying extra fields
(e.g. todoku-go's `NonRetryableError`) MUST implement `Unwrap` so
`Is`/`As`/`CodeOf`/`SeverityOf` traverse them.
*Why:* string matching on error messages is brittle — messages are human-facing
and change freely ([ERR-03](#dimension-errors-err) even mandates they compose), so
any logic keyed on them silently breaks; `Is`/`As`/`CodeOf` are the stable,
wrap-transparent contract; requiring `Unwrap` keeps custom types first-class.
Composes with [NET-07](#dimension-networking-net).
*Enforcement:* `gsds-errors-lint` forbids `err.Error() == ...`,
`strings.Contains(err.Error(), ...)`, and `==` against non-`Err`-prefixed values
(error severity); any local type with an `error` field MUST also have an
`Unwrap() error`/`[]error` method.
*Demonstrated by:* the example branches with
`switch { case errors.Is(err, ErrTenantNotFound): ...; case errs.CodeOf(err)=="E_RATE_LIMITED": ... }`
and defines `type ValidationError struct{ Field string; cause error }` with
`func (e *ValidationError) Unwrap() error { return e.cause }`.

**ERR-10** — Concurrent and fan-out failures MUST be aggregated with `errs.Join`
(not first-error-wins, not last-error-wins) whenever the operation has independent
sub-units whose individual failures all matter (multi-probe health checks,
multi-step teardown, batch processing). The aggregate's reported Severity is the
most-severe member and its Code is the first non-empty member code (errors-go
contract) — callers MUST rely on `errs.SeverityOf`/`errs.CodeOf` of the joined
value. A loop that abandons remaining work on the first error is permitted ONLY
when later steps genuinely depend on earlier success (documented short-circuit).
*Why:* short-circuiting a fan-out swallows every subsequent failure (the
swallowed-error gap in disguise); `errs.Join` is the standardized aggregator used
by lifecycle-go's health/teardown paths, and most-severe-wins severity means the
exit code and logging are correct for the worst sub-failure. Composes with
[JOB-10](#dimension-concurrency-and-jobs-job)/[LIFE-02](#dimension-lifecycle-and-health-life).
*Enforcement:* `gsds-errors-lint` warns on a range loop with first-error-return,
no aggregation, and no inter-iteration dependency; a property test asserts
`SeverityOf(Join(a,b)) == max(SeverityOf(a),SeverityOf(b))`; any hand-rolled
`[]error` join other than `errs.Join` is forbidden.
*Demonstrated by:* the example mirrors lifecycle-go:
`func (s *Set) Err() error { return errs.Join(errs...) }`, with a test asserting a
joined Notice+Error reports `SeverityError` and the first code, driving
`errs.ExitCode` non-zero.

**ERR-11** — Errors MUST be logged exactly ONCE, at the binary's top-level funnel
([ERR-06](#dimension-errors-err)) or at a deliberate recovery/swallow point
([ERR-08](#dimension-errors-err)) — never both wrapped-and-logged at the same
layer, and never logged then re-returned. When logged, the call MUST use
`logging-go` and MUST attach `err` (the error), `err.code` (`errs.CodeOf(err)`),
and the slog level MUST be derived from `errs.SeverityOf(err)` via the mandated
`logging.LevelForSeverity` mapping (`SeverityNotice`→`slog.LevelInfo`,
`SeverityWarning`→`slog.LevelWarn`, `SeverityError`→`slog.LevelError`).
`fmt.Print*`/`log.Print*` for error reporting are FORBIDDEN.
*Why:* log-and-return is double-logging (the same failure appears N times as it
unwinds); logging once at the funnel keeps a 1:1 failure→log-line invariant;
binding log level to errors-go Severity means the operator-facing loudness the
author encoded at the origin is exactly what surfaces. Composes with
[OBS-08](#dimension-observability-obs)/[OBS-09](#dimension-observability-obs).
*Enforcement:* `gsds-errors-lint` flags any function that BOTH logs an error and
returns that same error (error severity) and forbids `fmt.Print*`/stdlib
`log.Print*` carrying an error outside `main`; `logging.LevelForSeverity` is
exhaustive-linted with a golden three-rung test.
*Demonstrated by:* the example logs only in `main` via
`logging.Default().Log(ctx, logging.LevelForSeverity(errs.SeverityOf(err)), "command failed", "err", err, "err.code", errs.CodeOf(err))`;
a test greps the package asserting no error value is passed to a logger outside
`main`.

**ERR-12** — Crossing an external boundary (HTTP/gRPC handler, CLI command `Run`,
queue consumer, exported SDK call) MUST translate between the org error model and
the foreign protocol at exactly that boundary — never deeper. Inbound: foreign
errors (stdlib `net`, SDK errors, `context.Canceled`/`DeadlineExceeded`) MUST be
`errs.Wrap`-ed with a Code AT FIRST CONTACT so they enter the model classified.
Outbound: a handler MUST map `errs.CodeOf`/`errs.SeverityOf` to the protocol
status (HTTP status, gRPC code, CLI exit via [ERR-07](#dimension-errors-err)) and
MUST NOT leak the raw internal message/chain to untrusted callers (log the chain
internally; return a sanitized message + code externally).
*Why:* boundaries are where the typed model meets the untyped world — if foreign
errors enter unwrapped they have no Code and default Severity, and if internal
chains leak outward they expose internals and break the protocol's status
contract; doing the translation once, at the boundary, keeps the interior
uniformly errors-go-typed and gives external callers a stable status/code contract
— the GSDS "boundary of communication" made literal. Composes with
[CLI-10](#dimension-cli-ux-cli)/[NET-07](#dimension-networking-net).
*Enforcement:* `gsds-errors-lint` requires the first wrap of a recognized foreign
error in a handler signature to carry `WithCode` (warning) and forbids returning
an internal chain's `err.Error()` in an HTTP/gRPC response body (taint analysis,
error severity); cli-go's `cli.ErrHelp`/`ErrNoCommand` are already mapped to exit 0
in `errs.ExitCode`, demonstrating the outbound contract.
*Demonstrated by:* the HTTP handler does
`if err := svc.Get(ctx,id); err != nil { logging.Default().Error("get", "err", err); http.Error(w, errs.CodeOf(err), httpStatusFor(errs.SeverityOf(err), errs.CodeOf(err))) }`,
and an inbound adapter wraps an SDK 404 as
`errs.Wrap(sdkErr, "fetch tenant", errs.WithCode("E_TENANT_NOT_FOUND"))` at first
contact.

---

## Dimension: Lifecycle and Health (LIFE)

**LIFE-01** — Every long-running Go binary (any `cmd/*` whose process outlives a
single request — daemons, services, reconcilers, work-graph workers) MUST
establish its root context exactly once via
`lifecycle.SignalContext(context.Background())`, deferring the returned `stop`
CancelFunc, and MUST thread that context (or children) into every blocking call.
Hand-rolled `os/signal.Notify`, `signal.NotifyContext`, bare
`make(chan os.Signal)`, or `context.Background()` used as a blocking root are
forbidden in `cmd/*` and `internal/server`/`internal/daemon` packages.
*Why:* `SignalContext` is the single intention-revealing root every other
lifecycle primitive keys off — its cancellation means "the process was asked to
stop"; it watches `lifecycle.DefaultSignals` (SIGINT, SIGTERM) so every binary
reacts identically to Ctrl-C, `systemd stop`, and K8s pod termination, and its
`stop` restores default disposition so a second signal hard-kills. A
`context.Background()` root can never be cancelled. Composes with
[CLI-12](#dimension-cli-ux-cli)/[OBS-11](#dimension-observability-obs)/[NET-09](#dimension-networking-net).
*Enforcement:* forbidigo bans `os/signal.Notify`/`NotifyContext`/`Ignore` in
`cmd/**` and daemon packages; a `caixa-validate` AST gate asserts exactly one
`lifecycle.SignalContext` per `main` in a Servico/daemon caixa with a deferred
CancelFunc.
*Demonstrated by:* the service `main.go` opens with
`ctx, stop := lifecycle.SignalContext(context.Background()); defer stop()` as its
first two statements; every downstream `srv.ListenAndServe`, `RunLoop`, and `Tick`
receives `ctx`.

**LIFE-02** — All teardown MUST be registered on a single `*lifecycle.Shutdown`
(constructed with `lifecycle.NewShutdown(logger)`) via `sd.Add(name, hookFn)`,
where every hook is named, has the `lifecycle.HookFunc` signature
`func(context.Context) error`, and releases exactly one resource. The supervising
goroutine MUST call `sd.Run(context.Background(), timeout)` exactly once, after
`<-ctx.Done()` returns. `defer`-based cleanup for process-lifetime resources
(HTTP servers, DB pools, caches, flushers, shigoto schedulers) and direct
`os.Exit` in the teardown path are forbidden — `os.Exit` skips deferred and
registered teardown alike.
*Why:* `Shutdown` is the observable, bounded analog of a defer stack — hooks run
LIFO, errors aggregate via `errors.Join` (never short-circuit), and each hook is
logged; a scattered set of `defer`s is invisible to operators, unordered, and
silently swallows close errors. Composes with [LIFE-03](#dimension-lifecycle-and-health-life)/
[OBS-11](#dimension-observability-obs)/[ERR-10](#dimension-errors-err).
*Enforcement:* `caixa-validate` requires a `lifecycle.Shutdown` construction,
`sd.Run` reached only after a `<-ctx.Done()` (control-flow check), and flags
`defer x.Close()`/`Shutdown()` on process-lifetime resources in `main`; forbidigo
bans `os.Exit` inside any function referencing the shutdown variable.
*Demonstrated by:* the example builds `sd := lifecycle.NewShutdown(logger)` then
`sd.Add("http-server", srv.Shutdown)` and
`sd.Add("db", func(c context.Context) error { return db.Close() })`, ending with
`<-ctx.Done()` followed by `_ = sd.Run(context.Background(), 30*time.Second)`.

**LIFE-03** — Teardown hooks MUST be registered in resource-acquisition order, so
the LIFO execution of `Shutdown.Run` releases them in strict reverse. The inbound
HTTP/gRPC listener MUST be registered LAST so it stops accepting FIRST; backing
dependencies (DB pool, cache client, message bus) registered before it so they
close after the listener drains; the metrics/log flusher registered FIRST so it
flushes LAST. Acquiring a resource without registering its teardown hook in the
same lexical block is forbidden.
*Why:* lifecycle-go runs hooks LIFO deliberately — the server must stop accepting
new work before the DB pool it depends on closes, and the pool must close before
the metrics flusher that records the closes; out-of-order registration produces
use-after-close panics or lost in-flight requests; co-locating acquisition and
registration eliminates the "forgot the hook" gap. Composes with
[LIFE-02](#dimension-lifecycle-and-health-life)/[NET-09](#dimension-networking-net).
*Enforcement:* `caixa-validate` collects `sd.Add` order and asserts the inbound-
listener hook is the last `Add` with no `Add` after the first `ListenAndServe`/
`Serve` goroutine for a different resource; a diagnostic names any resource
constructed in `main` with no corresponding `sd.Add`.
*Demonstrated by:* the example registers `db`, `cache`, then `http-server` last;
an integration test asserts the recorded hook-completion log order is
`http-server` → `cache` → `db`.

**LIFE-04** — `Shutdown.Run` MUST be invoked with a finite, positive timeout
sourced from typed config (shikumi-go key `lifecycle.shutdown_timeout`, default
30s) and MUST be strictly less than the platform's termination grace window (K8s
`terminationGracePeriodSeconds`, systemd `TimeoutStopSec`). The base context
passed to `Run` MUST be a fresh `context.Background()` (or a context with its own
deadline), NOT the already-cancelled root `ctx` from `SignalContext`.
*Why:* `Shutdown.Run` derives a single per-teardown deadline from `timeout`; once
it passes, remaining hooks are skipped and reported as errors via `errors.Join`. A
`timeout <= 0` means no deadline (hooks run forever) — fatal under a K8s grace
window ending in SIGKILL. Passing the already-cancelled root context would make
every hook see `ctx.Err()` immediately and be skipped, so nothing drains. Composes
with [CFG-11](#dimension-configuration-cfg)/[NET-09](#dimension-networking-net)/
[LIFE-14](#dimension-lifecycle-and-health-life).
*Enforcement:* shikumi-go types `lifecycle.shutdown_timeout` as a positive
`time.Duration` with a default; `caixa-validate` asserts `sd.Run` uses
`context.Background()` (not the signal ctx) and a non-zero duration; the substrate
`service-module.nix` cross-checks that the rendered systemd `TimeoutStopSec` /
Helm `terminationGracePeriodSeconds` is greater than the configured timeout,
failing `nix flake check` otherwise.
*Demonstrated by:* config declares `lifecycle: { shutdown_timeout: 30s }`; `main`
calls `sd.Run(context.Background(), cfg.Lifecycle.ShutdownTimeout)`; the rendered
Helm chart sets `terminationGracePeriodSeconds: 45` and the gate confirms 45 > 30.

**LIFE-05** — Every service that listens on the network MUST expose a
`*lifecycle.Registry` (from `lifecycle.NewRegistry()`) served via `reg.Handler()`
on a dedicated health port (shikumi-go `ports.health`, default 8081 per substrate
`service-module.nix`), serving `/healthz` (liveness) and `/readyz` (readiness).
Hand-written `http.HandleFunc("/healthz", …)`, bespoke `/health` or `/ping` paths,
returning bare 200s, or serving health on the primary traffic port are forbidden.
*Why:* `Registry.Handler` is the one health surface — it returns 200/503 keyed on
plane outcome with a `{"status":..,"checks":{name:..}}` JSON body and aggregates
probe failures with `errors.Join`; the canonical paths match the substrate
`healthcheck.path` default and the rendered K8s probe paths exactly; a separate
health port keeps probes reachable while the traffic listener is saturated or
draining, letting the listener be the LIFO-last hook. Composes with
[OBS-13](#dimension-observability-obs)/[NET-10](#dimension-networking-net)/
[LIFE-06](#dimension-lifecycle-and-health-life).
*Enforcement:* `caixa-validate` requires a `lifecycle.Registry` bound to
`reg.Handler()`; forbidigo bans `HandleFunc`/`Handle` whose path matches
`^/(health|healthz|readyz|ready|ping|livez)$` outside lifecycle-go; the substrate
`service-module.nix` `healthcheck` option surface (path `/healthz`, port
`ports.health`=8081) is the single source for the rendered probe; `nix flake
check` asserts the Go health port == rendered probe port.
*Demonstrated by:* the example builds `reg := lifecycle.NewRegistry()` and a
second `http.Server{Addr: ":"+cfg.Ports.Health, Handler: reg.Handler()}` started
in its own goroutine and registered as a teardown hook; the rendered Deployment's
`livenessProbe.httpGet.path` is `/healthz` on port `health`.

**LIFE-06** — Liveness probes (registered with `reg.RegisterLiveness(name, probe)`)
MUST be dependency-free — they may only check in-process invariants (event loop
responsive, no deadlock sentinel, queue not wedged) and MUST NOT perform I/O
against any external dependency. External dependencies (DB, cache, upstream API,
message bus) MUST be registered as readiness probes via
`reg.RegisterReadiness(name, probe)` (or the alias `reg.Register`). A liveness
probe that pings a database is a defect.
*Why:* lifecycle-go's `kind` distinction is load-bearing — `/healthz` failure
restarts the pod, `/readyz` failure only pulls it from rotation; if a flaky
downstream feeds a liveness probe, a transient DB blip restarts every replica
simultaneously (a self-inflicted outage). Composes with [LIFE-05](#dimension-lifecycle-and-health-life)/
[LIFE-07](#dimension-lifecycle-and-health-life)/[NET-10](#dimension-networking-net).
*Enforcement:* `caixa-validate` builds the probe-registration graph; any
`RegisterLiveness` whose `Probe`/`ProbeFunc` body transitively calls a known I/O
symbol (`*sql.DB.PingContext`, `http.Client.Do`, `net.Dial`, a registered client
method) is a hard error; dependency checks are permitted only under
`RegisterReadiness`.
*Demonstrated by:* the example uses
`reg.RegisterLiveness("self", lifecycle.ProbeFunc(func(context.Context) error { return nil }))`
and `reg.RegisterReadiness("db", lifecycle.ProbeFunc(db.PingContext))` plus
`reg.RegisterReadiness("cache", lifecycle.ProbeFunc(cache.Ping))`.

**LIFE-07** — Every `Probe.Check` implementation MUST honour its passed `ctx`
deadline to bound its own I/O, MUST be cheap and side-effect-free, and MUST return
an `errors-go` error — never a bare `errors.New`/`fmt.Errorf` — so the failure
carries a machine code and severity that surfaces verbatim in the `/readyz` JSON
`checks` body. Any probe whose cost exceeds a single fast round-trip MUST be
fronted by a cached/last-known-good value refreshed on a `RunLoop`, not computed
inline on each poll.
*Why:* `Registry.evaluate` runs every probe of a plane concurrently on each HTTP
poll (k8s polls every few seconds); an expensive or ctx-ignoring probe blocks the
health endpoint and risks probe-timeout-driven restarts; `writeReport` serialises
each probe's `err.Error()` into the `checks` map, so an errors-go error gives
operators a coded, severity-tagged failure; caching expensive checks decouples
probe latency from dependency latency. Composes with [LIFE-06](#dimension-lifecycle-and-health-life)/
[LIFE-08](#dimension-lifecycle-and-health-life)/[ERR-01](#dimension-errors-err).
*Enforcement:* `caixa-validate` requires every `ProbeFunc`/`Probe.Check` body to
reference its `ctx` parameter (unused-ctx is an error) and its error returns to
originate from errors-go constructors; golangci flags `errors.New`/`fmt.Errorf`
inside probe bodies; a perf lint warns when a probe body calls more than one I/O
symbol without a cache read.
*Demonstrated by:* the example wraps a derived-deadline ping
(`c, cancel := context.WithTimeout(ctx, 500*time.Millisecond); defer cancel(); if err := upstream.Health(c); err != nil { return errs.Wrap(err, "upstream readiness").WithCode("UPSTREAM_DOWN") }`)
and an expensive license-validity probe reads `lastKnownGood.Load()` populated by a
`lifecycle.RunLoop`.

**LIFE-08** — All periodic in-process work (reconcile passes, metric scrapes,
token/secret refreshes, cache warmers, work-graph ticks) MUST run under
`lifecycle.RunLoop(ctx, every, tick, opts...)` with the root `ctx` from
`SignalContext`. Hand-rolled `for { select { case <-ticker.C: …; case <-ctx.Done(): return } }`,
`time.Sleep`-based polling loops, and `time.Ticker`/`time.Tick` driving recurring
work in `cmd/*`/daemon packages are forbidden. The `tick` MUST honour `ctx` so an
in-flight tick aborts on cancellation.
*Why:* `RunLoop` is the single supervised cadence — it stops on `ctx.Done()`
returning `ctx.Err()`, never spins (a zero interval is clamped), and offers
`WithImmediateTick`/`WithStopOnError`/`WithBackoff`/`WithLoopLogger` so every
periodic loop shares one shape and knobs; bespoke ticker loops re-derive
cancellation, backoff, and logging inconsistently and leak goroutines past
teardown (`time.Tick` leaks an un-stoppable ticker). Composes with
[OBS-12](#dimension-observability-obs)/[LIFE-09](#dimension-lifecycle-and-health-life)/
[JOB-05](#dimension-concurrency-and-jobs-job).
*Enforcement:* forbidigo bans `time.Tick` and `time.NewTicker`/`time.Sleep` inside
loop bodies in `cmd/**` and daemon packages; `caixa-validate` flags a `for`-`select`
whose cases are `<-ctx.Done()` plus a timer channel as a reimplemented RunLoop; the
tick signature is checked == `lifecycle.TickFunc` (`func(context.Context) error`).
*Demonstrated by:* the example launches
`go lifecycle.RunLoop(ctx, cfg.Lifecycle.ReconcileEvery, reconcile, lifecycle.WithLoopLogger(logger), lifecycle.WithBackoff(5*time.Minute))`,
and a token-refresh loop uses `lifecycle.WithImmediateTick()` to warm credentials
at startup before settling into cadence.

**LIFE-09** — `RunLoop` error policy MUST be chosen explicitly per loop and
documented in a one-line comment stating the failure intent. Use
`WithBackoff(max)` (max sourced from typed config) for loops whose failures are
transient and self-healing (default); use `WithStopOnError()` ONLY for loops whose
failure is fatal to the process, in which case the loop's return MUST be wired so
the supervisor cancels the root context and triggers `Shutdown.Run`. A
`WithStopOnError` loop whose return value is discarded (`go RunLoop(...)` with the
error dropped) is forbidden.
*Why:* runloop.go makes the two policies mutually exclusive in effect —
`WithBackoff` has no effect under `WithStopOnError` because the loop exits on first
error; defaulting silently to non-fatal-with-no-backoff means a hot-looping failing
tick floods logs every interval; choosing `WithStopOnError` but discarding the
return makes the fatal condition invisible. Composes with [LIFE-08](#dimension-lifecycle-and-health-life)/
[LIFE-02](#dimension-lifecycle-and-health-life).
*Enforcement:* `caixa-validate` requires every `RunLoop` to pass at least one of
`WithBackoff`/`WithStopOnError`/an explicit `// non-fatal: retried next interval`
annotation; a `WithStopOnError` call MUST NOT be go-spawned-and-discarded (its
return must feed a cancel/shutdown path, control-flow check); `WithBackoff` max
must be a typed shikumi-go duration, not a literal.
*Demonstrated by:* the reconcile loop uses `WithBackoff(cfg.Lifecycle.MaxBackoff)`
with `// non-fatal: transient source errors back off and self-heal`; a leader-lease
loop uses `WithStopOnError()` and its returned error is captured by a channel that
calls `stop()` so the LIFO `Shutdown.Run` fires.

**LIFE-10** — Work-graph daemons (any daemon whose internal work forms a
dependency-ordered, fallible, retryable graph) MUST model the graph with
`shigoto-go`: typed `Job[I,O]` units with stable `JobID{Scope,Kind,Subject}`, a
`*shigoto.Dag` validated via `dag.Validate()` (cycle rejection) before first use,
and a `shigoto.NewScheduler(tool)` whose single-step `Scheduler.Tick(ctx, dag)` is
driven by a `lifecycle.RunLoop` — NEVER by a loop internal to shigoto. The RunLoop
owns the cadence; `Tick` advances the FSM exactly one round per call.
*Why:* shigoto's scheduler is deliberately single-step ("the LOOP is the CALLER's
responsibility"); lifecycle-go owns supervised cadence + cancellation + backoff,
shigoto owns the typed FSM, DAG ordering, budget, retry, and gate algebra;
composing them — RunLoop tick → `sched.Tick(ctx, dag)` → wait — is the one
sanctioned shape, identical to the Rust shigoto + service-lifecycle pairing;
`dag.Validate()` before the first tick turns a cycle into a startup error.
Composes with the [Concurrency/Jobs](#dimension-concurrency-and-jobs-job) dimension
and [LIFE-08](#dimension-lifecycle-and-health-life)/[LIFE-11](#dimension-lifecycle-and-health-life).
*Enforcement:* `caixa-validate` requires any shigoto-go consumer to (a) call
`dag.Validate()` fatally at startup and (b) call `sched.Tick` only inside a
`lifecycle.RunLoop` `TickFunc` (a `for`-loop directly wrapping `Tick` is a
reimplemented-scheduler-loop error); golangci bans bare `for { sched.Tick(...) }`;
the mandatory shigoto-go + lifecycle-go pairing is asserted at the dependency
level.
*Demonstrated by:* the work-graph daemon does
`if err := dag.Validate(); err != nil { return errs.Wrap(err, "dag has a cycle") }`
at startup, then
`lifecycle.RunLoop(ctx, cfg.Lifecycle.TickEvery, func(c context.Context) error { _, err := sched.Tick(c, dag); return err }, lifecycle.WithBackoff(cfg.Lifecycle.MaxBackoff), lifecycle.WithLoopLogger(logger))`.

**LIFE-11** — A work-graph daemon's `RunLoop` tick MUST treat the `error` returned
by `Scheduler.Tick` (a malformed-DAG error, e.g. a cycle from dynamic mutation) as
a hard, loop-stopping failure, while per-job failures — surfaced via the returned
`TickReceipt.PhaseCounts`/`Transitions` and never via the error — drive backoff and
operator-attention reporting, NOT loop termination. The tick MUST inspect
`TickReceipt.Unhealed` and, when non-empty (jobs `Deadlettered` or
`WaitingForOperator`), reflect that drift in the daemon's readiness probe and emit
an errors-go warning-severity log; it MUST NOT silently discard the receipt.
*Why:* scheduler.go is explicit — `Tick`'s non-nil error means the DAG itself is
malformed (an unrecoverable structural fault — stop and alert), whereas per-job
failures are reported through phases/transitions and self-heal via the per-kind
retry policy; conflating the two either kills a healthy daemon on a single
retryable job failure or hides a structural cycle; `TickReceipt.Unhealed` is the
typed "needs a human" signal. Composes with [LIFE-05](#dimension-lifecycle-and-health-life)/
[JOB-14](#dimension-concurrency-and-jobs-job).
*Enforcement:* `caixa-validate` forbids discarding the `TickReceipt` while the
daemon has readiness probes (blank-identifier is an error) and requires
referencing `receipt.Unhealed`; the DAG error must propagate; a readiness probe
reflecting `len(receipt.Unhealed) == 0` is required for work-graph caixas; the
emitted-log severity is checked per `Unhealed` phase.
*Demonstrated by:* the tick is
`receipt, err := sched.Tick(c, dag); if err != nil { return err } /* malformed DAG: stop */; if n := len(receipt.Unhealed); n > 0 { unhealed.Store(int32(n)); logger.Warn("jobs need operator attention", "count", n, "jobs", receipt.Unhealed) }; return nil`,
with `reg.RegisterReadiness("work-graph", lifecycle.ProbeFunc(func(context.Context) error { if unhealed.Load() > 0 { return errs.New("deadlettered jobs present").WithCode("WORKGRAPH_UNHEALED") }; return nil }))`.

**LIFE-12** — Startup MUST follow a fixed ordering and MUST be fail-fast: (1) load
+ validate typed config via shikumi-go; (2) build the logger via logging-go and
`SetDefault`; (3) establish the root signal context
([LIFE-01](#dimension-lifecycle-and-health-life)); (4) construct the shutdown
registry ([LIFE-02](#dimension-lifecycle-and-health-life)); (5) acquire
dependencies, registering each one's teardown hook and its readiness probe in the
same block ([LIFE-03](#dimension-lifecycle-and-health-life)/[LIFE-06](#dimension-lifecycle-and-health-life));
(6) start the health server ([LIFE-05](#dimension-lifecycle-and-health-life)) and
only then the traffic listener and any `RunLoop`s; (7) block on `<-ctx.Done()`;
(8) run `sd.Run`. Any acquisition failure in step 5 MUST return an errors-go error
from `main` (causing a non-zero exit) BEFORE the traffic listener starts —
partial startup that begins serving without a required dependency is forbidden.
*Why:* a deterministic startup order makes a service navigable (every fleet
`main.go` shows the same eight phases); health-before-traffic ensures K8s sees
`/readyz` ready only after dependencies are wired so it never routes to a
half-initialised pod; fail-fast-before-listen turns a missing dependency into a
clean crash-loop rather than a process accepting traffic it cannot serve; building
the logger second means every subsequent failure is structured. This nests
[CFG-14](#dimension-configuration-cfg)'s six-step config wiring inside the broader
eight-phase startup. Composes with [LIFE-13](#dimension-lifecycle-and-health-life).
*Enforcement:* `caixa-validate` parses `main` and asserts the canonical phase
sequence (config → logger → SignalContext → Shutdown → deps → health-server →
traffic+loops → ctx.Done → Run), flagging any traffic `ListenAndServe`/`grpc.Serve`
lexically preceding a dependency acquisition or the health server; dependency
constructors returning errors must be checked and returned (errcheck); the
substrate `service-typed.nix` daemon subcommand wiring asserts this shape.
*Demonstrated by:* the example `main.go` is eight clearly-commented phases in this
order; a `TestStartupFailFast` sets an unreachable DB and asserts the process exits
non-zero with an errors-go `DB_UNAVAILABLE` code and never opened the traffic port.

**LIFE-13** — A daemon/service binary MUST expose its long-running mode under a
dedicated cli-go subcommand — by convention `daemon` for work-graph/background
daemons and `serve` for network services — matching the substrate
`daemon.subcommand` (default `daemon`) / `httpSubcommand` (default `serve`) used by
the rendered systemd/launchd unit (`module-trio.nix`) and the Helm chart. The
lifecycle wiring ([LIFE-01](#dimension-lifecycle-and-health-life)..[LIFE-12](#dimension-lifecycle-and-health-life))
lives in that subcommand's `Run`, which receives the framework `ctx`. Defining the
daemon entrypoint as a bare `main` with no subcommand, or under a name diverging
from the rendered unit's `ExecStart` subcommand, is forbidden.
*Why:* the unit file generated by `module-trio.nix`/`service-module.nix` invokes
the binary with a specific subcommand; if the Go side names its long-running mode
differently the unit fails at `ExecStart` with an unknown-subcommand error (a
silent deploy-time gap); routing lifecycle through one named cli-go subcommand also
keeps the binary multi-modal while giving operators one predictable invocation.
Composes with [CLI-01](#dimension-cli-ux-cli)/[CLI-02](#dimension-cli-ux-cli)/
[LIFE-01](#dimension-lifecycle-and-health-life).
*Enforcement:* `nix flake check` cross-gate asserts the rendered systemd
`ExecStart` subcommand equals a registered cli-go `Command.Name` (the substrate
spec's `daemon.subcommand` matched against the Go AST `app.Add(cli.Command{Name:
...})` set); `caixa-validate` requires the lifecycle primitives inside a subcommand
`Run`, not directly in `main`; mismatch fails the build.
*Demonstrated by:* the example registers
`app.Add(cli.Command{Name: "serve", Summary: "Run the service", Run: serve})`
where `serve(ctx, args, fs)` contains the full [LIFE-12](#dimension-lifecycle-and-health-life)
startup; the rendered `service-module.nix` sets `daemon.subcommand = "serve"` and
the generated systemd unit's `ExecStart` ends in `... serve`.

**LIFE-14** — The traffic HTTP/gRPC server's graceful-stop call MUST be the
resource released by its teardown hook and MUST receive the deadline-bearing
context from `Shutdown.Run`, so drain is bounded by the same single deadline as
every other hook. For `net/http`, register `sd.Add("http-server", srv.Shutdown)`
(the method signature is already `func(context.Context) error` ==
`lifecycle.HookFunc`); for gRPC, wrap `GracefulStop` in a `HookFunc` that falls
back to `Stop` when the hook's context deadline elapses. Calling `srv.Close()`
(hard close, drops in-flight requests) in the normal teardown path, or
`srv.Shutdown` with a `context.Background()` ignoring the deadline, is forbidden.
*Why:* graceful stop is the load-bearing reason the listener is registered
LIFO-last ([LIFE-03](#dimension-lifecycle-and-health-life)) — it must drain
in-flight requests before its dependencies close but also respect the overall
deadline so it cannot hang the sequence past the orchestrator grace window;
bypassing it with `Close()` drops live connections and ignoring the deadline
reintroduces the unbounded-hang failure [LIFE-04](#dimension-lifecycle-and-health-life)
prevents. Composes with [NET-09](#dimension-networking-net).
*Enforcement:* forbidigo bans `(*http.Server).Close` in daemon/service packages
outside test files; `caixa-validate` asserts the http/grpc server hook uses the
context the hook is invoked with (the `HookFunc` param), not a fresh `Background()`;
a shared `lifecycle`-adjacent gRPC graceful-with-fallback helper standardises the
shape.
*Demonstrated by:* the HTTP example registers `sd.Add("http-server", srv.Shutdown)`
directly; the gRPC example registers
`sd.Add("grpc-server", func(ctx context.Context) error { done := make(chan struct{}); go func() { gs.GracefulStop(); close(done) }(); select { case <-done: return nil; case <-ctx.Done(): gs.Stop(); return ctx.Err() } })`.

**LIFE-15** — The canonical service port and probe paths are FIXED fleet-wide:
the health server binds `:8081` and serves `/healthz` (liveness),
`/readyz` (readiness), and `/metrics` ([OBS-13](#dimension-observability-obs)/
[NET-10](#dimension-networking-net)); the traffic server's port is a required,
typed `shikumi-go` field. A repo MUST NOT pick an ad-hoc health port or probe
path; the Go health-server bind and the rendered probe config (Helm/systemd) are
derived from the same typed value and cross-checked.
*Why:* a navigator who knows "this is a Servico" must know where to `curl` its
health without reading code — the [Identity-derivation table](#identity-derivation-table)
promises `:8081`/`/healthz`/`/readyz`/`/metrics` with zero lookups. Divergent
ports/paths break that promise and silently mis-wire probes at deploy. Composes
with [LIFE-05](#dimension-lifecycle-and-health-life)/[OBS-13](#dimension-observability-obs)/
[NET-10](#dimension-networking-net).
*Enforcement:* `nix flake check` asserts the Go health-server bind port == the
rendered probe port and that the registered paths are exactly
`/healthz`,`/readyz`,`/metrics`; `caixa-validate` rejects a hard-coded health
port literal outside the typed config; the Identity-derivation table is the
documented contract ([DOC-14](#dimension-documentation-and-discoverability-doc)).
*Demonstrated by:* the example service exposes
`curl localhost:8081/healthz` (200), `/readyz` (200 once ready), `/metrics`
(Prometheus text); the chart's `livenessProbe`/`readinessProbe` point at the
same port/paths.

**LIFE-16** — Every `Servico`/`Binario` README `## Usage` MUST carry a runnable
local-invocation recipe: the `nix run .#<app> -- <subcommand>` form, the minimal
config/env to boot ([CFG-13](#dimension-configuration-cfg) required fields), and
(for `Servico`) the canonical ports to hit ([LIFE-15](#dimension-lifecycle-and-health-life)).
This is the same recipe as [Run & debug recipes](#run--debug-recipes) and MUST
agree with it.
*Why:* the standard mandates the `serve` subcommand exists
([LIFE-13](#dimension-lifecycle-and-health-life)) but a new engineer still needs
to be TOLD how to invoke it and what it needs to boot — "build" was covered, "run"
was a gap. A runnable recipe in a known anchor closes it. Composes with
[DOC-05](#dimension-documentation-and-discoverability-doc)/[LIFE-13](#dimension-lifecycle-and-health-life)/
[LIFE-15](#dimension-lifecycle-and-health-life).
*Enforcement:* the README-shape linter ([DOC-05](#dimension-documentation-and-discoverability-doc))
fails a `Servico`/`Binario` whose `## Usage` lacks a `nix run .#` invocation and
(for `Servico`) a health-curl line; `caixa-validate` cross-checks the recipe's
app name against the binary set and the port against [LIFE-15](#dimension-lifecycle-and-health-life).
*Demonstrated by:* the `widgetd` README `## Usage` shows
`nix run .#widgetd -- serve` with `WIDGETD_CONFIG=...`, then
`curl localhost:8081/healthz`; the `widgetctl` README shows
`nix run .#widgetctl -- secret list`.

---

## Dimension: Networking (NET)

**NET-01** — ALL outbound HTTP from any org Go binary MUST go through a
`todoku.Client` constructed with `todoku.New(opts...)`. Direct use of `http.Get`,
`http.Post`, `http.DefaultClient`, `(&http.Client{}).Do`, `http.NewRequest`
issued outside todoku, or any third-party HTTP client (resty, sling, gentleman,
etc.) is forbidden in non-test code. The only place a raw `*http.Client` may
appear is passed INTO todoku via `todoku.WithHTTPClient(hc)` for custom
transports/proxies/TLS.
*Why:* `todoku-go` (届く) is the single fleet HTTP surface — one builder, one auth
model, one retry/backoff, JSON helpers, default User-Agent, URL joining; a second
client multiplies retry semantics, auth plumbing, and timeout defaults; a reader
who knows todoku knows every outbound call in every repo. Composes with
[LAYOUT-10](#dimension-repo-layout-and-module-layout)/[NET-02](#dimension-networking-net)..[NET-08](#dimension-networking-net).
*Enforcement:* CI lint gate `gsds-net-outbound` (a go/analysis pass + a ripgrep
rule in the substrate Go release flake) fails the build if `net/http`'s
`Get|Post|Head|PostForm|DefaultClient|DefaultTransport` or any non-todoku
HTTP-client import appears in a non-`_test.go` package; allowlist is exactly
`todoku-go` and `net/http` types used only as `todoku.WithHTTPClient` arguments;
wired in `service-flake.nix`/`tool-release-flake.nix` checks.
*Demonstrated by:* the example's `internal/client` exposes one
`newAPIClient(cfg) (*todoku.Client, error)` calling
`todoku.New(todoku.WithBaseURL(cfg.BaseURL), todoku.WithAuth(...), todoku.WithTimeout(cfg.Timeout), todoku.WithRetry(todoku.DefaultRetry()))`;
`grep -rn 'http.Get\|http.DefaultClient' .` returns zero hits.

**NET-02** — There MUST be exactly ONE retry/backoff implementation per binary,
and it MUST be `todoku.RetryWithBackoff[T]` / `todoku.RetryWithBackoffClass[T]`
(the `Client` routes through it internally). Hand-rolled
`for attempt := 0; ...` loops with `time.Sleep`, third-party backoff libraries
(`cenkalti/backoff`, `avast/retry-go`, `hashicorp/go-retryablehttp`), and per-call
ad-hoc retry are forbidden. ANY flaky non-HTTP operation (NATS publish, DB write,
subprocess, cloud-SDK call) that needs retry MUST consume
`todoku.RetryWithBackoff` rather than reimplement a loop.
*Why:* `todoku.retry` is "the single backoff implementation in this package";
backoff math, jitter (anti-thundering-herd), max-attempt counting, and
context-aware sleep cancellation are subtle and must live in exactly one place; a
second loop will drift in jitter, cap, or cancellation. Composes with
[NET-03](#dimension-networking-net)/[JOB-07](#dimension-concurrency-and-jobs-job).
*Enforcement:* `gsds-net-retry` flags `time.Sleep` inside a loop performing
network/IO, imports of the known backoff libs, and `for .*attempt`+`time.Sleep`;
allowed sleeps need a `//nolint:gsds-net-retry — <reason>` justification; retry
config is constructable only via `todoku.DefaultRetry()`/`NoRetry()`/
`AggressiveRetry()` or an explicit `todoku.RetryConfig{...}` to `WithRetry`.
*Demonstrated by:* the flaky publish path is
`todoku.RetryWithBackoff(ctx, todoku.DefaultRetry(), func(ctx context.Context) (Ack, error) { return bus.Publish(ctx, msg) })`;
the HTTP path inherits retry from `todoku.WithRetry(todoku.DefaultRetry())`; no
`time.Sleep` exists in `internal/`.

**NET-03** — Retry policy MUST be selected from the three canonical fleet profiles
— `todoku.DefaultRetry()` (3 retries, 500ms→30s, 20% jitter, statuses
429/500/502/503/504), `todoku.NoRetry()` (exactly once, for non-idempotent
writes), or `todoku.AggressiveRetry()` (5 retries, 200ms→60s, for critical reads).
A bespoke `todoku.RetryConfig{...}` literal is permitted ONLY with a doc comment
justifying why the three profiles do not fit, and its `RetryStatuses` MUST be a
subset of safe-to-retry statuses (never 4xx other than 429). Non-idempotent
operations (POST/PUT/PATCH that are not idempotent) MUST use `todoku.NoRetry()`
unless protected by an idempotency key.
*Why:* retrying a non-idempotent write doubles side effects; standardizing on
three named profiles makes the retry posture readable at a glance and prevents
silently retrying a 400/422 forever or hammering a 429-throttled upstream.
*Enforcement:* `gsds-net-retry` flags a `RetryConfig` literal whose
`RetryStatuses` contains any 4xx other than 429, and any client used for a
POST/PUT/PATCH with a non-`NoRetry` policy unless an `Idempotency-Key`-style
header is set; reviewers gate the justification comment for custom literals.
*Demonstrated by:* reads use `todoku.AggressiveRetry()`, the idempotent GET client
uses `todoku.DefaultRetry()`, and the order-submission POST client is constructed
with `todoku.WithRetry(todoku.NoRetry())` plus an idempotency key, each with a
one-line comment citing NET-03.

**NET-04** — Every outbound call MUST thread a caller-supplied `context.Context` as
the first argument (`Do`/`Get`/`Post`/`GetJSON`/`PostJSON` all take `ctx` first).
`context.Background()`/`context.TODO()` MUST appear ONLY at process entry points
(main, the root of a `lifecycle.SignalContext`, a top-level CLI command handler)
and NEVER inside library/handler code that has a context available. Inbound HTTP
handlers MUST propagate `r.Context()` into every downstream outbound call so
cancellation and deadlines flow end-to-end.
*Why:* todoku's retry loop and the underlying `http.NewRequestWithContext` honour
cancellation and deadlines; a detached `context.Background()` deep in the call
graph defeats request-scoped timeouts, leaks goroutines on client disconnect, and
breaks correlation-ID propagation ([NET-12](#dimension-networking-net)); end-to-end
context is the backbone of [NET-05](#dimension-networking-net) and observability.
Composes with [OBS-06](#dimension-observability-obs)/[JOB-08](#dimension-concurrency-and-jobs-job).
*Enforcement:* `gsds-net-ctx` flags `context.Background()`/`TODO()` outside `cmd/`
and `main` and any IO function lacking a `context.Context` first parameter; `go
vet` `lostcancel` and the `contextcheck` linter enabled in the substrate Go check
set.
*Demonstrated by:* the HTTP handler does `ctx := r.Context()` then
`todoku.GetJSON(ctx, c.upstream, "/inventory/"+id, &inv)`;
`context.Background()` appears exactly once, in `cmd/<svc>/main.go`, feeding
`lifecycle.SignalContext(context.Background())`.

**NET-05** — Timeouts are MANDATORY and layered. (1) Every `todoku.Client` MUST be
given an explicit total per-request timeout via `todoku.WithTimeout(d)` (or a
`WithHTTPClient` whose `*http.Client.Timeout` is set) — relying on the 30s default
is forbidden in service code; the value MUST come from the shikumi-go YAML config,
never a hardcoded literal. (2) Every individual call that can outlive its parent
SHOULD additionally bound itself with `context.WithTimeout(ctx, d)`. (3) A
`todoku.Client` with `Timeout == 0` (unbounded) is forbidden.
*Why:* an unbounded outbound call is the classic cascading-failure vector — one
slow upstream exhausts the caller's connection/goroutine pool; todoku defaults to
30s precisely so a forgotten timeout still terminates, but services must choose a
value matched to their SLO and source it from config so it is tunable without a
rebuild; this is the outbound mirror of [NET-11](#dimension-networking-net).
Composes with [CFG-01](#dimension-configuration-cfg).
*Enforcement:* `gsds-net-timeout` flags any `todoku.New(...)` whose options omit
`WithTimeout`/`WithHTTPClient`, and a hardcoded duration literal to `WithTimeout`
(must reference a config field); the canonical client factory returns an error if
the resolved timeout `<= 0`; shikumi-go's typed config declares `HTTPTimeout
time.Duration` as a required field with a validated lower bound.
*Demonstrated by:* `internal/config` has `Upstream struct { BaseURL string; Timeout time.Duration }`
with YAML `timeout: 5s`; the factory passes `todoku.WithTimeout(cfg.Upstream.Timeout)`
and errors when `cfg.Upstream.Timeout <= 0`.

**NET-06** — Outbound authentication MUST be expressed through the `todoku.Auth`
abstraction — `todoku.BearerAuth(token)`, `todoku.BasicAuth(user,pass)`,
`todoku.HeaderAuth(name,value)`, or `todoku.NoAuth()` — passed via
`todoku.WithAuth`. Manually setting `req.Header.Set("Authorization", ...)` or
splicing API keys into URLs/headers at the call site is forbidden. For
short-lived/rotating tokens, a custom type implementing the `Auth` interface
(`Apply(*http.Request)`) that reads the current token per request MUST be used,
because `Auth.Apply` runs on EVERY attempt rather than being baked in at
construction.
*Why:* `todoku.auth` centralizes credential attachment so it is applied uniformly
on every request and every retry attempt; hand-set headers scatter credential
logic, miss retries, and make secret-handling un-auditable; one abstraction makes
rotating from Bearer to a vendor header a one-line `WithAuth` change. Composes with
[CFG-07](#dimension-configuration-cfg)/[CFG-09](#dimension-configuration-cfg)/
[SEC-11](#dimension-security-and-supply-chain-sec).
*Enforcement:* `gsds-net-auth` flags any
`req.Header.Set("Authorization", ...)`/`.Set("X-Api-Key", ...)` outside an
`Auth.Apply` impl and credential-shaped string literals in URLs; secrets feeding
`BearerAuth`/`BasicAuth` MUST originate from shikumi-go config / a
cofre-materialized secret (cross-checked by the secret-scan gate).
*Demonstrated by:* the example defines `type rotatingAuth struct { src TokenSource }`
with `func (a rotatingAuth) Apply(r *http.Request) { r.Header.Set("Authorization", "Bearer "+a.src.Current()) }`,
wired via `todoku.WithAuth(rotatingAuth{tokens})`; a unit test asserts the header
is re-read across two retry attempts.

**NET-07** — Outbound errors MUST be classified and wrapped, never swallowed or
string-matched. Callers MUST inspect todoku's typed error surface with
`errors.As` — `*todoku.HTTPError` (non-retryable/final status, carries
`Status`+`Body`), `*todoku.ExhaustedError` (all attempts failed, carries
`Attempts`), `*todoku.NonRetryableError`, and
`context.Canceled`/`context.DeadlineExceeded` — and re-wrap with `errors-go`
`errors.Wrap(err, "<intent>")` (optionally `WithCode`/`WithSeverity`) before
returning. Comparing `err.Error()` substrings or branching on raw status strings
is forbidden.
*Why:* todoku exposes a precise typed error model; string-matching it is brittle
and breaks silently when messages change; wrapping through `errors-go` preserves
the cause chain for `Is`/`As`, attaches the fleet severity ladder and machine
code, and feeds the audit surface; a 404 (act) vs a 503-exhausted (alert) vs a
context-cancel (caller gave up) demand different handling. Composes with
[ERR-09](#dimension-errors-err)/[ERR-12](#dimension-errors-err)/[ERR-08](#dimension-errors-err).
*Enforcement:* `gsds-net-err` flags `strings.Contains(err.Error(), ...)` patterns
and bare returns of a network error without an `errors.Wrap`; `errcheck` +
`errorlint` enabled in the substrate Go check set.
*Demonstrated by:* the handler does
`var he *todoku.HTTPError; if errors.As(err, &he) && he.Status == http.StatusNotFound { return errs.Wrap(err, "fetch inventory", errs.WithCode("E_NOT_FOUND"), errs.WithSeverity(errs.SeverityNotice)) }`,
with a fallback `errs.Wrap(err, "fetch inventory")` and a test table covering each
todoku error type.

**NET-08** — The `todoku.Client` MUST be constructed ONCE per upstream at startup
(in the composition root / via the shikumi-go-driven factory) and shared across
goroutines for the process lifetime — it is documented safe for concurrent use.
Constructing a `todoku.Client` (or a `*http.Client`) per-request,
per-handler-invocation, or inside a loop is forbidden. One distinct `Client` per
logical upstream (distinct base URL + auth + retry posture) is the unit; do not
collapse unrelated upstreams onto one client nor spawn many for one upstream.
*Why:* a fresh client per request defeats connection pooling/keep-alive, leaks
file descriptors, and re-pays TLS handshakes (a top cause of port exhaustion and
latency); todoku is concurrency-safe so the correct lifetime is process-scoped;
one-client-per-upstream keeps auth and retry posture coherent per dependency.
Composes with [LIFE-12](#dimension-lifecycle-and-health-life).
*Enforcement:* `gsds-net-client-lifetime` flags `todoku.New(` inside
`http.HandlerFunc` bodies, loop bodies, or hot-path functions; clients must be
struct fields constructed in `main`/factory; reinforced by DI-wiring review.
*Demonstrated by:* `internal/app.App` holds `inventory *todoku.Client` and
`pricing *todoku.Client` built in `app.New(cfg)` and injected into handlers; no
handler calls `todoku.New`.

**NET-09** — Every long-running inbound server (HTTP/gRPC) MUST mount its lifecycle
on `lifecycle-go`: the root context comes from
`lifecycle.SignalContext(context.Background())` (SIGINT+SIGTERM), and graceful
teardown is registered as a `lifecycle.Shutdown` hook in LIFO acquisition order.
The HTTP listener MUST be torn down with `srv.Shutdown(ctx)` (NOT `srv.Close()`)
under a bounded deadline via `shutdown.Run(ctx, drainTimeout)`, where
`drainTimeout` comes from shikumi-go config. The server hook MUST be registered
FIRST (so it is the LAST acquired before serving and the FIRST released — stop
accepting new connections before dependencies close).
*Why:* lifecycle-go is the one fleet teardown/signal model; graceful `Shutdown`
drains in-flight requests (`Close` drops them); LIFO ordering guarantees the HTTP
server stops accepting before the DB pool/bus closes; bounded drain prevents a hung
connection from blocking pod termination past the K8s grace period. This is the
networking-side restatement of [LIFE-01](#dimension-lifecycle-and-health-life)/
[LIFE-02](#dimension-lifecycle-and-health-life)/[LIFE-03](#dimension-lifecycle-and-health-life)/
[LIFE-04](#dimension-lifecycle-and-health-life)/[LIFE-14](#dimension-lifecycle-and-health-life).
*Enforcement:* `gsds-net-lifecycle` flags direct `signal.Notify`/`NotifyContext`
(must be via `lifecycle.SignalContext`), `srv.Close()` on an `http.Server`, and an
`http.Server`/`ListenAndServe` whose teardown is not registered on a
`lifecycle.Shutdown`; `service-typed.nix` wires SIGTERM delivery and the binary
MUST consume it.
*Demonstrated by:* `cmd/<svc>/main.go` does
`ctx, stop := lifecycle.SignalContext(context.Background()); defer stop()`,
`sd.Add("http-server", srv.Shutdown)` registered before `sd.Add("bus", bus.Close)`,
and after `<-ctx.Done()`: `sd.Run(context.Background(), cfg.Server.DrainTimeout)`.

**NET-10** — Health endpoints MUST be served by `lifecycle.Registry` via
`reg.Handler()`, exposing exactly `GET /healthz` (liveness) and `GET /readyz`
(readiness) — no per-service hand-rolled health handlers. Liveness probes MUST be
dependency-free; readiness probes MUST register each external dependency via
`reg.Register(name, lifecycle.ProbeFunc(dep.PingContext))`. Health routes MUST
listen on the dedicated health port (substrate default `8081`, separate from the
main `8080` traffic port) so probes are reachable independent of the main mux's
middleware/auth.
*Why:* lifecycle-go's health surface is the single fleet convention — its
`Handler()` returns the right JSON shape and 200/503 K8s+human both consume;
separating liveness (restart) from readiness (de-rotate) prevents a flaky DB from
triggering restarts; a separate health port (matching
`service-module.nix` `ports.health = 8081`, `healthcheck.path = /healthz`) keeps
probes off the authenticated mux. This is the same surface as
[LIFE-05](#dimension-lifecycle-and-health-life)/[LIFE-06](#dimension-lifecycle-and-health-life),
viewed from networking, and feeds [OBS-13](#dimension-observability-obs).
*Enforcement:* `gsds-net-health` flags manual
`mux.HandleFunc("/healthz"|"/readyz", ...)` and any service `main` lacking a
`lifecycle.Registry` + `reg.Handler()` on the health port; `service-typed.nix`
validates `ports.health`/`healthcheck.path` at Nix-eval; the generated K8s/systemd
probe config points at `/healthz` on `:8081`, so a missing handler fails the
deployment health gate.
*Demonstrated by:* the example registers
`reg.RegisterReadiness("inventory-upstream", lifecycle.ProbeFunc(func(ctx context.Context) error { _, err := app.inventory.Get(ctx, "/healthz"); return err }))`
and `reg.RegisterLiveness("self", ...)`, served by
`http.Server{Addr: ":8081", Handler: reg.Handler()}` registered as its own
`sd.Add("health-server", healthSrv.Shutdown)` hook.

**NET-11** — Every inbound `http.Server` MUST set explicit timeouts:
`ReadHeaderTimeout` (mandatory — guards against Slowloris), `ReadTimeout`,
`WriteTimeout`, and `IdleTimeout`, all sourced from shikumi-go config.
Constructing an `http.Server` with zero-valued timeouts, or using
`http.ListenAndServe(addr, handler)` (the package-level helper that yields an
unconfigured server), is forbidden. The main traffic server and the health server
are configured independently.
*Why:* Go's default `http.Server` has NO timeouts; an unconfigured server is
vulnerable to slow-client resource exhaustion (the `gosec` G114 finding); explicit
config-driven timeouts make the server's resource posture readable and tunable —
the inbound mirror of [NET-05](#dimension-networking-net)'s outbound mandate.
*Enforcement:* `gsds-net-server-timeout`: `gosec` G112/G114 enabled (flags
`http.ListenAndServe` and missing `ReadHeaderTimeout`); a custom analyzer
additionally requires non-zero `ReadTimeout`/`WriteTimeout`/`IdleTimeout` on every
`http.Server` literal, sourced from a config field rather than a literal.
*Demonstrated by:* the example builds
`srv := &http.Server{Addr: cfg.Server.Addr, Handler: mux, ReadHeaderTimeout: cfg.Server.ReadHeaderTimeout, ReadTimeout: cfg.Server.ReadTimeout, WriteTimeout: cfg.Server.WriteTimeout, IdleTimeout: cfg.Server.IdleTimeout}`
with the `Server` block in shikumi-go YAML; `http.ListenAndServe` appears nowhere.

**NET-12** — Inbound request logging MUST flow through `logging-go`. The middleware
chain MUST: (1) extract or mint a correlation ID from the inbound
`X-Correlation-ID`/`X-Request-ID` header and attach it via
`logging.WithCorrelationID(ctx, id)` (plus `logging.WithTenant` where resolvable),
storing the enriched context back on the request with `r.WithContext(ctx)`; (2)
emit one structured access-log record per request via
`logging.FromContext(ctx).InfoContext(ctx, ...)` carrying method, path, status,
duration, and bytes — so `correlation_id`/`tenant` auto-attach through the
`ContextHandler`. Per-handler `fmt.Println`/`log.Printf`/bespoke access logs are
forbidden, and the correlation ID MUST be propagated onto outbound calls
([NET-04](#dimension-networking-net) carries the same ctx into todoku).
*Why:* logging-go is the single fleet structured-logging surface on `log/slog`
with a `ContextHandler` that injects `correlation_id`/`tenant` automatically;
threading the ID from inbound header → context → outbound todoku call is what makes
a request traceable across hops; ad-hoc logging breaks the JSON shape and loses
correlation. Composes with [OBS-04](#dimension-observability-obs)/[OBS-06](#dimension-observability-obs)/
[OBS-07](#dimension-observability-obs)/[NET-13](#dimension-networking-net).
*Enforcement:* `gsds-net-reqlog` flags `fmt.Print*`/`log.Print*`/`log.Println` in
handler/middleware packages and any access-log middleware not calling
`logging.WithCorrelationID`; forbidigo bans `fmt.Println`/the std `log` package
fleet-wide; reviewers verify outbound re-emission.
*Demonstrated by:* `internal/middleware.RequestLog` reads
`cid := orNew(r.Header.Get("X-Correlation-ID")); ctx := logging.WithCorrelationID(r.Context(), cid); r = r.WithContext(ctx)`,
defers
`logging.FromContext(ctx).InfoContext(ctx, "request", "method", r.Method, "path", r.URL.Path, "status", rec.status, "dur_ms", took.Milliseconds())`,
and downstream todoku calls reuse that ctx so `correlation_id` appears on both
logs.

**NET-13** — Inbound middleware MUST be applied in ONE canonical order, outermost
→ innermost: (1) panic-recovery, (2) request-ID/correlation-ID injection, (3)
request logging/access log, (4) timeout (`http.TimeoutHandler` or a
`context.WithTimeout` middleware) bounding total handler time from config, (5)
auth/authorization, (6) the business handler. Recovery is outermost so it catches
panics from every inner layer (including logging); correlation-ID precedes logging
so the ID is present in the access record; timeout precedes auth so even auth is
bounded. The chain MUST be assembled by a single shared `middleware.Chain(...)`
helper, not re-spelled per route.
*Why:* middleware order is load-bearing and a classic source of subtle bugs (a
recovery handler inside the logger never logs the panic; a logger before
correlation-ID injection logs without the ID; auth before timeout lets a slow auth
backend hang unbounded); fixing ONE order fleet-wide makes every request pipeline
identical, and a single `Chain` helper makes the order un-reorderable per route.
Composes with [NET-12](#dimension-networking-net)/[OBS-10](#dimension-observability-obs).
*Enforcement:* `gsds-net-mw-order` asserts `middleware.Chain` is the only assembler
of the server's handler and its layers appear in the mandated order (matched by
known middleware names); routes registering raw handlers that bypass `Chain` are
flagged; the recovery middleware logs the panic via `logging-go` with
`SeverityError`.
*Demonstrated by:* the example exposes
`func Chain(h http.Handler, cfg Config, log *slog.Logger) http.Handler` returning
`recover(reqID(reqlog(timeout(auth(h)))))` in exactly that nesting;
`cmd/<svc>/main.go` mounts `srv.Handler = middleware.Chain(mux, cfg, log)` and no
route wires middleware itself; a test asserts a panic in the business handler
yields a 500 access-log record carrying the correlation ID.

**NET-14** — TLS is floored fleet-wide: every `tls.Config` on an inbound
`http.Server` AND every `todoku-go` client ([NET-01](#dimension-networking-net))
MUST set `MinVersion` ≥ `tls.VersionTLS12` (TLS 1.3 preferred), sourced from a
typed `shikumi-go` field that defaults to TLS 1.2 and MUST NOT be lowered below
it. `tls.Config{InsecureSkipVerify: true}` is FORBIDDEN in non-test code (no
silent downgrade, no cert bypass), and weak primitives are banned in
security-relevant paths: `crypto/md5`, `crypto/sha1`, `crypto/des`, `crypto/rc4`,
and `math/rand` for any security/credential/token use ([SEC-13a](#dimension-security-and-supply-chain-sec)).
*Why:* SC-8 / SC-13 (FedRAMP) require TLS 1.2+ and forbid downgrade; an
unconfigured `tls.Config` defaults to whatever the toolchain permits and
`InsecureSkipVerify` silently disables the entire authentication guarantee; weak
crypto/`math/rand` in a credential path defeats the FIPS posture
([SEC-02](#dimension-security-and-supply-chain-sec)) regardless of boringcrypto
linkage. A typed floor makes the TLS posture readable and un-loweringable.
Composes with [NET-01](#dimension-networking-net)/[NET-06](#dimension-networking-net)/
[NET-11](#dimension-networking-net)/[SEC-13a](#dimension-security-and-supply-chain-sec).
*Enforcement:* `gsds-net-tls`: a custom analyzer requires `MinVersion` ≥
`VersionTLS12` sourced from config on every `tls.Config` literal and on the
todoku client factory, bans `InsecureSkipVerify: true` outside `_test.go`, and
flags `crypto/{md5,sha1,des,rc4}` / `math/rand` imports in non-test crypto paths;
`gosec` G402/G404/G401/G501-G505 are enabled in the substrate Go check set
([SEC-13a](#dimension-security-and-supply-chain-sec)); the todoku factory errors
if the resolved `MinVersion` < TLS 1.2.
*Demonstrated by:* the example service builds
`&tls.Config{MinVersion: cfg.TLS.MinVersion}` (default `tls.VersionTLS12`); a
fixture setting `InsecureSkipVerify: true` or importing `crypto/md5` for HMAC
fails the analyzer; the todoku client rejects a configured `MinVersion` of TLS
1.0.

---

## Dimension: Concurrency and Jobs (JOB)

**JOB-01** — Any unit of internal work that is dependency-ordered, fallible,
retryable, OR parallelism-bounded — i.e. forms a work graph — MUST be modeled with
`shigoto-go`, not with hand-rolled goroutines/channels/`sync.WaitGroup`/`errgroup`.
Declare each unit as a `shigoto.Job[I,O]` (or the `shigoto.JobFunc[I,O]` adapter)
with a stable `shigoto.JobID{Scope,Kind,Subject}`; declare ordering as a
`shigoto.Dag`; drive progress with `shigoto.InProcessScheduler.Tick`. Ad-hoc
`go func(){…}()` is permitted ONLY for a single leaf operation with no dependents,
no retry need, and no shared concurrency budget.
*Why:* shigoto-go IS the org's typed job-system primitive (仕事), the Go
counterpart to the Rust shigoto crate family carrying the same algebra;
reinventing scheduling per-tool is the duplication the prime directive forbids and
the source of every leak/ordering/aggregation bug; one algebra means any reader who
knows shigoto can navigate any repo's concurrency. Composes with
[LIFE-10](#dimension-lifecycle-and-health-life)/[JOB-05](#dimension-concurrency-and-jobs-job).
*Enforcement:* `library-check.nix` `go build ./...` + a golangci-lint custom
analyzer `nogofunc` forbid bare `go ` statements and direct `errgroup`/
`sync.WaitGroup` imports in non-test, non-`shigoto` packages (allowlist requires a
`//shigoto:exempt-leaf` annotation with a justification); the only legal way to
advance a Job is `shigoto.Advance`, so any work graph not expressed as Jobs is
structurally invisible to the scheduler and fails the work-graph coverage check.
*Demonstrated by:* the example's `internal/jobs/` declares every pipeline step as a
`shigoto.JobFunc[Req,Resp]{Identity: shigoto.JobID{Scope:"repo:pleme-io/<repo>", Kind:"fetch", Subject:url}, Run: …}`,
wires them into a `shigoto.NewDag()`, and exposes zero bare goroutines (verified by
`nogofunc`).

**JOB-02** — Every Job's identity MUST be a fully-populated
`shigoto.JobID{Scope,Kind,Subject}` that is stable across scheduler cycles AND
process restarts (the same logical work yields the same triple every tick). Scope
encodes breadth ("global", "workspace:<name>", "repo:<org>/<name>"); Kind names the
work class (budgets, gates, retry policies are registered per-Kind); Subject names
the concrete thing operated on (empty only when the Kind has no finer subject).
Identity MUST be derived deterministically from inputs — never from time, a random
value, a pointer address, or an autoincrement counter.
*Why:* `Job.Id()` is pure and read many times per cycle; the scheduler recognizes
the same work only by triple equality, and crash-recovery + idempotent
re-execution depend on identity being reconstructible after restart; a
nondeterministic JobID silently creates a NEW job every tick — defeating dedup,
retry-attempt accounting, and the `AllUpstreamsTerminal` edge gate. Composes with
[JOB-03](#dimension-concurrency-and-jobs-job)/[JOB-04](#dimension-concurrency-and-jobs-job).
*Enforcement:* JobID is a comparable struct used directly as a map key, so a
non-deterministic field cannot be silently absorbed; an analyzer flags JobID
literals whose Subject/Scope reference `time.Now`/`rand`/`uuid`/`&`; the mandated
`TestJobIDStableAcrossCycles` constructs the DAG twice from the same inputs
asserting byte-equal JobID sets.
*Demonstrated by:* the example derives `Subject` from the input URL/path and
`Scope` from the repo coordinate, and ships `jobid_stable_test.go` asserting two
independent builds produce identical `dag.TopoOrder()` JobID sequences.

**JOB-03** — `Job.Execute` MUST be idempotent and MUST honour ctx cancellation.
Re-running Execute after a crash-between-side-effect-and-record-Succeeded (which
the scheduler WILL do on the next cycle) must be safe; Execute must return promptly
with a non-nil error when ctx is cancelled, timed out, or the deadline elapses.
Execute MUST NOT spawn goroutines that outlive its own return (no detached
background work).
*Why:* the shigoto-go Job contract states Execute is the side-effecting work and
MUST be idempotent because a scheduler crash re-invokes it; timeout/operator-cancel
map to a failing ctx-aware return (Running→Failed); a non-idempotent or ctx-deaf
Execute turns the at-least-once scheduler into a double-apply / un-cancellable
hazard, and a goroutine outliving Execute is an unowned leak. Composes with
[JOB-08](#dimension-concurrency-and-jobs-job)/[JOB-09](#dimension-concurrency-and-jobs-job).
*Enforcement:* the `ctxfirst` analyzer ([JOB-08](#dimension-concurrency-and-jobs-job))
requires Execute's first param be `context.Context` and flags blocking calls
(`http`/`exec`/`sql`/channel recv) that ignore it; `go vet` + `-race` +
`goleak.VerifyTestMain` catch leaked goroutines; a per-Job
`Test<Kind>ExecuteIdempotent` runs Execute twice asserting converged state.
*Demonstrated by:* each example Job's Run threads ctx into every IO call
(`http.NewRequestWithContext`), writes via an upsert/CAS so a second run is a
no-op, and `main_test.go` calls `goleak.VerifyTestMain(m)`.

**JOB-04** — Dependency ordering MUST be expressed exclusively via `shigoto.Dag`
edges (`AddNode`/`AddEdge`), and the DAG MUST be validated with `dag.Validate()`
(or via `TopoOrder`/`Waves`) BEFORE the first `Tick`. A non-nil
`*shigoto.CycleError` (matching `shigoto.ErrCycle`) MUST abort startup — never be
ignored. Cross-Job ordering MUST NOT be encoded with channels, sleeps, or mutexes;
an edge from→to is the ONLY sanctioned "to may not start until from is terminal"
primitive.
*Why:* `shigoto.Dag` is the typed dependency graph — edges desugar into the
implicit `AllUpstreamsTerminal` gate the scheduler evaluates each tick, and
`Validate`/`TopoOrder`/`Waves` reject cycles via Kahn's algorithm with a
deterministic witness; encoding order any other way reintroduces deadlock and the
ad-hoc-synchronization class shigoto retires. Composes with
[LIFE-10](#dimension-lifecycle-and-health-life)/[JOB-11](#dimension-concurrency-and-jobs-job).
*Enforcement:* the scheduler's `evaluateGates` always installs
`AllUpstreamsTerminal` from the DAG (ordering not expressed as edges shows up as a
wrong-order `TickReceipt` in tests); a startup smoke test asserts `dag.Validate()`
is called and its error checked (errcheck forbids discarding it);
`errors.Is(err, shigoto.ErrCycle)` is the mandated branch.
*Demonstrated by:* `buildDag()` returns `(*shigoto.Dag, error)`, calls
`dag.Validate()`, and `main` exits non-zero on `errors.Is(err, shigoto.ErrCycle)`;
a `dag_cycle_test.go` injects a back-edge asserting the `CycleError` witness.

**JOB-05** — The scheduler loop is the CALLER's responsibility — `shigoto.Tick`
advances the graph exactly one round and never loops internally. Long-running
daemons MUST drive `Tick` from lifecycle-go's `lifecycle.RunLoop(ctx, interval,
tick)` (or the equivalent event-driven map, e.g. one Tick per K8s CR event). Code
MUST NOT hand-roll a `for { … time.Sleep() … }` loop, a bare ticker, or a
`select{}` driver around `Tick`.
*Why:* `shigoto.Tick` is single-step by design; lifecycle-go.RunLoop is the org's
single cancellable-cadence shape with built-in backoff-on-error, immediate-first-
tick, and stop-on-error; two competing loop idioms is duplication, and a
hand-rolled loop usually drops ctx cancellation and leaks the loop goroutine.
Composes with [LIFE-08](#dimension-lifecycle-and-health-life)/[LIFE-10](#dimension-lifecycle-and-health-life)/
[OBS-12](#dimension-observability-obs).
*Enforcement:* `noadhocloop` forbids `time.Sleep` inside a `for` and bare
`time.NewTicker`/`time.Tick` in service packages, directing to
`lifecycle.RunLoop`; `TestLoopStopsOnContextCancel` asserts RunLoop returns
`ctx.Err()` on cancellation; goleak verifies no loop goroutine survives ctx cancel.
*Demonstrated by:* the daemon's `Serve(ctx)` calls
`lifecycle.RunLoop(ctx, cfg.Interval, func(ctx) error { _, err := sched.Tick(ctx, dag); return err }, lifecycle.WithLoopLogger(log), lifecycle.WithBackoff(cfg.MaxBackoff))`
and contains no bare loop.

**JOB-06** — Bounded parallelism MUST be enforced through a `shigoto.BudgetTree`
installed via `scheduler.InstallBudget` — never through a hand-rolled semaphore,
buffered-channel token pool, or `errgroup.SetLimit`. Limits are declared per
dimension (`SetGlobal`/`SetKind`/`SetScope`) and admission is min-intersection: a
Job runs only when EVERY applicable dimension has slack. Every Job's Kind and Scope
that needs a cap MUST have a budget entry; unbounded (no spec) is permitted only
with an explicit `//shigoto:unbounded` justification comment.
*Why:* `BudgetTree` is the typed three-dimension envelope (global × by-kind ×
by-scope) with atomic Acquire/saturating Release; the scheduler's Ready→Running
transition becomes a real admission check once a budget is installed; a separate
semaphore per call site is the canonical duplication + the classic source of
unbounded fan-out exhausting connections/file-descriptors. Composes with
[JOB-01](#dimension-concurrency-and-jobs-job).
*Enforcement:* lint forbids `make(chan struct{}, n)` token pools and
`golang.org/x/sync/semaphore` in service packages (routes to BudgetTree);
`TestBudgetNeverExceeds` under `-race` asserts `budget.RunningKind(k)` never
exceeds the configured `MaxConcurrent` across thousands of ticks; the
Acquire/Release symmetry is enforced by the scheduler (runJob always Releases).
*Demonstrated by:* the example sets
`b.SetGlobal(shigoto.MaxConcurrent(10)); b.SetKind("flake-update", shigoto.MaxConcurrent(1)); b.SetScope("workspace:pleme-io", shigoto.MaxConcurrent(5))`,
calls `sched.InstallBudget(b)`, and asserts the min-intersection bound under
`-race`.

**JOB-07** — Retry/backoff MUST be expressed as a `shigoto.RetryPolicy` registered
per Kind via `scheduler.RegisterRetryPolicy(kind, policy)` using the typed
constructors `shigoto.NoRetry`/`Fixed`/`Exponential`/`Custom`. Hand-rolled retry
loops, manual `for attempt := 0; …` with sleeps, or third-party retry libraries
inside `Job.Execute` are FORBIDDEN. Production network/IO Jobs MUST use
`Exponential` with jitter; the absence of a registered policy means `NoRetry`
(deadletter on first failure) and MUST be a deliberate, documented choice.

> **Note: two retry layers (resolving an apparent overlap).**
> [NET-02](#dimension-networking-net)/[NET-03](#dimension-networking-net) mandate
> `todoku`'s transport-layer retry for *outbound HTTP*; JOB-07 mandates shigoto's
> *job-graph* retry for *work-graph Job execution*. These are **distinct layers and
> MUST NOT be stacked**: an HTTP call inside a Job retries at the todoku transport
> layer (one logical HTTP attempt = one todoku call with its own backoff), while
> the Job itself is retried/deadlettered by the shigoto scheduler. A Job's Execute
> calls `todoku` (which may internally retry the request) and returns once; the
> scheduler then decides whether to retry the *Job* per its `RetryPolicy`. Putting
> a manual retry loop in either place is the violation.

*Why:* `shigoto.RetryPolicy` is the typed failure-recovery strategy; the scheduler
drives Failed→Retrying→(backoff)→Pending entirely through the FSM and tracks
attempt counts itself, so retry inside Execute double-counts attempts, breaks the
JobPhase audit trail, and reintroduces per-tool retry duplication; jittered
exponential backoff is the only safe default against thundering-herd retries.
Composes with [JOB-12](#dimension-concurrency-and-jobs-job)/[JOB-14](#dimension-concurrency-and-jobs-job).
*Enforcement:* the `noinlineretry` analyzer flags retry loops + external retry-lib
imports inside packages implementing `shigoto.Job`; `TestRetryDeadletters`
registers `shigoto.Fixed(3, d)`, forces failures, and asserts Deadlettered after
exactly N attempts via TickReceipt transitions; jitter determinism is asserted
reproducible.
*Demonstrated by:* the example calls
`sched.RegisterRetryPolicy("fetch", shigoto.Exponential(5, 200*time.Millisecond, 30*time.Second, 0.2))`
and contains zero retry loops inside any Run.

**JOB-08** — Every concurrency-bearing function — `Job.Execute`, `Gate.Check`,
lifecycle `HookFunc`, `RunLoop` `TickFunc`, and any internal helper that performs
IO or may block — MUST take `context.Context` as its FIRST parameter and MUST
propagate it unmodified (or via a derived child) to every downstream blocking
call. `context.Background()`/`context.TODO()` may appear ONLY at the true program
root (main, test setup) — never deeper. Storing a context in a struct field is
forbidden; it is always a parameter.
*Why:* context-first is the org's single cancellation + deadline + value-
propagation channel; the shigoto Job/Gate contracts, lifecycle.HookFunc, and
RunLoop.TickFunc are all ctx-first; logging-go's ContextHandler injects
`correlation_id`/`tenant` ONLY when the active ctx flows through the `*Context`
slog methods; a dropped ctx severs cancellation (leaked goroutines), deadlines
(unbounded hangs), and observability correlation simultaneously. Composes with
[NET-04](#dimension-networking-net)/[OBS-06](#dimension-observability-obs)/
[JOB-03](#dimension-concurrency-and-jobs-job).
*Enforcement:* `containedctx` + `contextcheck` + a custom `ctxfirst` analyzer (ctx
must be param 0, named `ctx`, and forwarded) run in CI golangci-lint; `go vet`
`lostcancel` catches dropped CancelFuncs; `goleak` in TestMain fails the suite on
any goroutine surviving a cancelled ctx.
*Demonstrated by:* every signature in the example (`Run(ctx context.Context, …)`,
`Check(ctx context.Context)`, hook `func(ctx context.Context) error`) is ctx-first;
the daemon logs via `log.InfoContext(ctx, …)` after
`ctx = logging.WithCorrelationID(ctx, id)`.

**JOB-09** — NO GOROUTINE LEAKS — every goroutine that IS spawned MUST have (a) a
single named owner responsible for its lifetime, (b) a deterministic teardown path
tied to ctx cancellation, and (c) a teardown hook registered with lifecycle-go's
`lifecycle.Shutdown.Add(name, hook)` so it is awaited under the deadline. A
goroutine started in a constructor or handler with no corresponding registered
teardown is a defect. Channels owned by a goroutine MUST be closed by exactly one
owner on teardown.
*Why:* `lifecycle.Shutdown` collects named teardown hooks and runs them LIFO under
one bounded deadline — the observable analog of a defer stack — aggregating
failures with `errors.Join` rather than short-circuiting; without a registered
owner+hook a goroutine becomes an orphan that survives teardown, hangs the process,
or leaks resources; shigoto-managed work needs no hand-owned goroutines, so this
rule governs the unavoidable few (server accept loops, signal handlers). Composes
with [LIFE-02](#dimension-lifecycle-and-health-life)/[LIFE-04](#dimension-lifecycle-and-health-life)/
[ERR-10](#dimension-errors-err).
*Enforcement:* `goleak.VerifyTestMain` (mandated in every service's TestMain) fails
the suite on any goroutine outliving the test; `noownerless-go` flags `go `
statements whose enclosing constructor does not also call `shutdown.Add`;
`TestShutdownBoundedByDeadline` asserts a hook ignoring ctx is skipped past the
deadline and reported, never hung-on.
*Demonstrated by:* the example's `NewServer(ctx, sd *lifecycle.Shutdown)` starts its
accept loop in one goroutine and immediately `sd.Add("http-server", srv.Shutdown)`;
`main` defers `sd.Run(ctx, 15*time.Second)` and goleak confirms zero survivors.

**JOB-10** — Concurrent errors MUST be aggregated, never silently dropped or
first-wins-discarded. Use errors-go's `errors.Join` (severity-aware) for
fan-in/wave aggregation and `lifecycle.Shutdown.Run`'s built-in `errors.Join` for
teardown; wrap each contributing error with `errors.Wrap` to name what was
attempted before joining. A goroutine/Job/hook that returns an error MUST route it
into an aggregate the owner inspects — discarding an error from a concurrent unit
(`_ = f()`, empty error branch) is forbidden.
*Why:* `errors.Join` drops nils, returns nil when all-nil, makes `errors.Is`/`As`
fan out across every member, and reports the MOST-SEVERE member's Severity plus the
first non-empty Code — so a partial-failure wave surfaces a correctly-classified,
fully-inspectable aggregate; per-Job failures additionally surface structurally as
Failed→Deadlettered phases in the TickReceipt; the two surfaces are complementary.
Composes with [ERR-10](#dimension-errors-err)/[JOB-14](#dimension-concurrency-and-jobs-job).
*Enforcement:* `errcheck` (no discarded errors) + a custom `noconcurrentdrop`
analyzer flag errors returned inside `go func`/hook/Job bodies that are not sent to
a collector or returned; `TestWaveAggregatesAllErrors` fails three Jobs in a wave
asserting the joined error's `SeverityOf` is the max member severity and
`errors.Is` matches each member; `TestShutdownJoinsHookErrors`.
*Demonstrated by:* the fan-in helper collects per-unit errors into a slice and
returns `errors.Join(errs...)`, each pre-wrapped via
`errors.Wrap(err, "fetch "+subject)`; the deadletter path is asserted via
`TickReceipt.Unhealed`.

**JOB-11** — Preconditions that admit or hold a Job MUST be modeled as
`shigoto.Gate` values registered per Kind via `scheduler.RegisterGate(kind, gate)`,
and Gates MUST be PURE — they evaluate in-memory state with NO IO and return
promptly. A precondition needing IO MUST be modeled as an upstream Job that
performs the IO and emits a typed fact, plus a downstream pure Gate that checks the
fact — never as an IO-performing Gate. `Gate.Check` returns (true=Pass, false=Wait,
error=Skip-permanently).
*Why:* `shigoto.Gate` is the typed precondition; an IO-performing gate is an
antipattern because the scheduler re-evaluates every gate cohort each tick — IO in
a gate means unbounded, uncontrolled, un-budgeted IO on the hot path; Gate cohorts
reduce worst-outcome-wins (Skip > Wait > Pass), keeping the FSM agnostic of how the
rollup was computed; pure gates are deterministically testable offline. This is the
shigoto-go discipline behind [LIFE-06](#dimension-lifecycle-and-health-life)/
[LIFE-07](#dimension-lifecycle-and-health-life) (dependency-free liveness) and the
FSM gates in the [Delivery FSM Type System](#delivery-fsm-type-system).
*Enforcement:* the `puregate` analyzer flags `http`/`sql`/`exec`/`os` calls inside
any type implementing `shigoto.Gate`; `TestGateIsPure` runs Check 1000× asserting
identical results + zero IO syscalls; `TestGateCohortWorstWins` asserts the
`CheckAll` reducer's short-circuit-on-first-refusal.
*Demonstrated by:* the `deploy` Kind registers
`shigoto.GateFunc(func(ctx) (bool,error){ return approved.Load(), nil })` (pure
atomic read); the actual approval-fetch is a separate upstream Job of Kind
`fetch-approval` that sets the atomic — edge in the DAG, not IO in the gate.

**JOB-12** — Phase transitions MUST flow exclusively through `shigoto.Advance` — no
code outside the scheduler may invent, infer, or mutate a `JobPhase` by assignment,
except the explicit, FSM-constrained `scheduler.OperatorTransition` (for
WaitingForOperator→Ready|Skipped and Deadlettered→Pending) and `scheduler.SetPhase`
(test/seed setup only). An illegal (phase,signal) pair returns
`shigoto.ErrIllegalTransition` and MUST be treated as a programmer bug (fail loud),
never swallowed.
*Why:* the load-bearing invariant of the scheduler is that EVERY phase change goes
through `Advance`; Advance is pure and exhaustive over the legal JobPhase×Signal
cross-product, every other cell returning `ErrIllegalTransition` with the input
phase unchanged; inventing transitions outside Advance breaks the audit trail, the
TickReceipt phase counts, and the deadletter/operator-revival contract. This is the
exact idiom the four [Delivery FSMs](#delivery-fsm-type-system) reuse.
*Enforcement:* the FSM IS the enforcement — `Advance` is the only function
returning a new JobPhase from a Signal, and `SetPhase` is documented test-only
(`notestonlyinprod` flags it outside `_test.go`); `TestIllegalTransitionRejected`
asserts a representative illegal cell returns `ErrIllegalTransition`;
`TestEveryTransitionViaAdvance` asserts the scheduler never assigns phases except
in dispatch/OperatorTransition (verified by the FSM coverage table mirrored from
the Rust theory).
*Demonstrated by:* the example never assigns a `JobPhase` directly outside test
setup; operator revival of a deadlettered Job goes through
`sched.OperatorTransition(id, shigoto.Pending, shigoto.ReasonOperatorAction("revived by oncall"))`,
its error checked and surfaced.

**JOB-13** — Every scheduler MUST be constructed with `shigoto.NewScheduler(tool)`
tagged with the binary's tool name and MUST have a real
`shigoto.TransitionEmitter` attached via `WithEmitter` in any non-test build —
minimum a `shigoto.NewJSONLEmitter(w)` (use `shigoto.NewMultiEmitter` to fan to
additional sinks). The default `shigoto.NullEmitter` is permitted ONLY in tests.
Per-job timeouts for IO Jobs MUST be set via `scheduler.SetTimeout(id, d)` so a
hung Execute maps to Timeout→Failed rather than blocking the wave.
*Why:* the TransitionEmitter is the append-only audit/observability sink the
scheduler calls on every phase change (non-blocking and best-effort —
JSONLEmitter serializes writes and retains LastErr rather than failing the
scheduler); without it the entire JobPhase lifecycle is invisible to operators; a
missing per-job timeout lets one hung Execute stall a whole wave. Composes with
[OBS-13](#dimension-observability-obs)/[JOB-14](#dimension-concurrency-and-jobs-job).
*Enforcement:* `requireemitter` flags `NewScheduler` in a main package not followed
by `WithEmitter`; a build-tag-gated startup assertion fails the binary if the
emitter is a `NullEmitter` outside tests; `TestTimeoutMapsToFailed` sets a short
`SetTimeout`, blocks Execute, and asserts Running→Failed via `ReasonTimedOut` in
the TickReceipt; the JSONL audit line is parsed and validated against the
Transition schema.
*Demonstrated by:* the example builds
`shigoto.NewScheduler("<tool>").WithEmitter(shigoto.NewMultiEmitter(shigoto.NewJSONLEmitter(auditFile), metricsEmitter))`,
calls `sched.SetTimeout(fetchID, 30*time.Second)`, and an integration test tails
the JSONL audit asserting the full Pending→…→Succeeded sequence.

**JOB-14** — Jobs that reach a terminal-needs-attention phase (Deadlettered or
WaitingForOperator) MUST be surfaced operationally via the per-Tick
`shigoto.TickReceipt` — its `PhaseCounts`, `Transitions`, and `Unhealed`
(`[]UnhealedDrift`) fields. The daemon's RunLoop tick MUST inspect
`receipt.Unhealed` every tick and route it to logging-go
(`log.WarnContext` with correlation_id/tenant from context) and to
metrics/alerting. A Deadlettered Job MUST NEVER be silently abandoned; revival is
an explicit, audited `OperatorTransition`.
*Why:* `TickReceipt` is the derived per-tick rollup; `Unhealed` names exactly the
jobs requiring operator attention; ignoring the receipt means failures vanish — the
work graph silently stops making progress with no signal, the precise failure mode
this dimension forbids; logging-go's ContextHandler ensures the warning carries
correlation_id/tenant for cross-service triage. Composes with
[LIFE-11](#dimension-lifecycle-and-health-life)/[JOB-12](#dimension-concurrency-and-jobs-job)/
[OBS-04](#dimension-observability-obs).
*Enforcement:* the `noignoredreceipt` analyzer flags a `Tick` call whose returned
TickReceipt is discarded (`_, _ = sched.Tick(...)`); `TestUnhealedSurfaced`
deadletters a Job and asserts (a) it appears in `receipt.Unhealed` in deterministic
order (sorted by jobKey for stable alerting), (b) a `WarnContext` line carries
correlation_id, (c) an alert metric increments.
*Demonstrated by:* the tick closure does
`receipt, err := sched.Tick(ctx, dag); for _, u := range receipt.Unhealed { log.WarnContext(ctx, "job needs operator", "job", jobKey(u.JobID), "phase", u.Phase.String()); stuckJobs.Inc() }`
and never discards the receipt.

---

## Dimension: Documentation and Discoverability (DOC)

**DOC-01** — Every Go package MUST have a package-level doc comment, and for any
package whose source is more than one file OR whose package doc exceeds ~15 lines,
that doc comment MUST live in a dedicated `doc.go` whose ONLY content is the
`// Package <name> ...` block immediately followed by the `package <name>` clause
(no types, vars, funcs, or imports). Single-file packages may carry the package doc
atop the single `.go` file. The package doc MUST follow the canonical four-part
shape: (1) one sentence stating what the package IS and which pleme-io Pillar /
Rust crate it mirrors; (2) a summary of the surface; (3) a `// The mandate ...`
paragraph stating the ban it enforces; (4) at least one runnable, indented usage
block.
*Why:* pkg.go.dev renders the package doc as the landing page a first-time
navigator hits — the highest-leverage paragraph in the repo; a dedicated `doc.go`
gives that landing copy a stable, greppable home; the four-part shape is already
the de-facto house style and codifying it removes the "what belongs in a package
doc" gap. Composes with [NAME-04](#dimension-naming-name)/[DOC-08](#dimension-documentation-and-discoverability-doc).
*Enforcement:* `check-all` runs `go doc ./<pkg>` per package (fail on empty
synopsis) + a `package-doc-shape` analyzer that fails when a multi-file package
lacks `doc.go`, `doc.go` declares anything other than the package clause, or the
mandate sentinel line is missing; the `caixa-validate` FSM cannot advance a
Biblioteca past `documented` without a non-empty synopsis on every package.
*Demonstrated by:* the example library ships `doc.go` modeled on
`pleme-actions-shared-go/doc.go` — opening sentence names the Pillar/Rust crate, a
`The mandate ...` line states the ban, and an indented usage block closes the
comment.

**DOC-02** — Every EXPORTED symbol — type, func, method, const, var, interface —
MUST have a godoc comment, and that comment MUST begin with the symbol's own name
(`// New creates ...`, `// Error is the one concrete error type ...`). No exported
symbol may be documented with a comment starting with any word other than its
identifier. Deprecations MUST use the `// Deprecated:` convention as a standalone
paragraph.
*Why:* this is the contract that makes the package a boundary of communication — a
consumer reading pkg.go.dev or hovering in gopls must find prose on every name they
can call; the name-first convention is what gopls and pkg.go.dev key on for the
one-line summary list. Composes with [DOC-03](#dimension-documentation-and-discoverability-doc)/
[VER-07](#dimension-versioning-and-compatibility-ver).
*Enforcement:* `golangci-lint` with `revive` `exported` and `package-comments` set
to error, plus `godot` for terminal periods, wired into `check-all` (shared config,
fleet-uniform); zero-tolerance — any `exported` finding fails the check and blocks
merge.
*Demonstrated by:* in errors-go every exported name (`Error`, `Option`,
`WithSeverity`, `WithCode`, `New`, `Wrap`, `Severity`, `SeverityOf`, `CodeOf`)
carries a name-first comment; the example mirrors this and adds a `// Deprecated:`
block on one symbol.

**DOC-03** — Godoc comments MUST use square-bracket doc links (`[New]`,
`[errors.Is]`, `[Severity]`) for every reference to another exported symbol,
package, or stdlib identifier, instead of bare backticks or plain names.
Cross-package links to the mandated runtime libs MUST use the fully-qualified form
(`[logging.FromContext]`, `[shikumi.LoadStore]`, `[lifecycle.Run]`,
`[todoku.Client]`) so pkg.go.dev renders a clickable hyperlink across module
boundaries.
*Why:* doc links turn the documentation into a navigable graph — a user on
`errors.Wrap` can click through to `errors.Is` and the stdlib `errors` package;
cross-linking the mandated libs wires the whole runtime ecosystem into one
explorable web, directly serving the "anyone can navigate" mandate. Composes with
[DOC-08](#dimension-documentation-and-discoverability-doc).
*Enforcement:* a custom doc-link analyzer in `check-all` (a Rust tool, per the
NO-SHELL law) parses each comment, resolves every backtick-or-bareword matching an
exported identifier in the import graph, and fails if it is not a `[...]` doc link;
`go vet`'s doclink checking is enabled to catch unresolved links.
*Demonstrated by:* errors-go links `[Severity]`, `[errors.Is]`, `[errors.As]`,
`[errors.Unwrap]`, `[New]`, `[Wrap]`, `[SeverityOf]`, `[CodeOf]`; the example adds
a cross-module link to `[logging.FromContext]` and `[shikumi.LoadStore]`.

**DOC-04** — Every exported package MUST ship at least one runnable `Example` test
in an `example_test.go` file in an external `<pkg>_test` package, and EVERY
non-trivial exported function/type (constructors, primary entry points, any symbol
whose use is non-obvious) MUST have its own `ExampleXxx`/`ExampleType_Method`
function with an `// Output:` (or `// Unordered output:`) comment so it both
compiles and asserts behavior.
*Why:* runnable examples are the only documentation Go executes — they cannot rot,
render inline on pkg.go.dev as copy-pasteable starter code, and the `// Output:`
assertion makes them a test; an example is the fastest path from "I found the
package" to "I have working code" — the load-bearing artifact of the
under-N-minute navigation test ([DOC-09](#dimension-documentation-and-discoverability-doc)).
Composes with [TEST-01](#dimension-testing-and-quality-test)/[DOC-12](#dimension-documentation-and-discoverability-doc).
*Enforcement:* `check-all` runs `go test ./...` executing all `Example*` with
`Output:` comments; an examples-coverage linter fails if a `//gsds:example-required`
symbol (default for all exported constructors and entry points) has no `Example`;
`caixa-validate` blocks `documented → publishable` until `go test` reports ≥1
executed example per package.
*Demonstrated by:* the example library adds `example_test.go` in package `errs_test`
with `ExampleNew`, `ExampleWrap`, `ExampleSeverityOf`, each ending in `// Output:`
— closing the gap where none of the runtime libs yet ship example tests.

**DOC-05** — Every repo MUST have a top-level `README.md` containing, in this order,
these exact `##` sections (anchors are normative): `## What`, `## Why`,
`## Install`, `## Usage`, `## Configuration`, `## Release`. `## Configuration` MUST
document the shikumi-go config struct, its env-var prefix, and XDG discovery path
when the unit consumes shikumi-go (and state "No runtime configuration" explicitly
otherwise — the section is never omitted). `## Install` MUST give the
`go get <module-path>` line AND the Nix consumption snippet (the substrate
`library-flake.nix`/`tool-release-flake.nix` overlay). `## Release` MUST state the
publish model (Go's tag-only pull model) and link to CHANGELOG.md.
*Why:* the README is the GitHub landing page (pkg.go.dev shows the package doc,
GitHub shows the README) — both must be gapless; fixed, ordered section anchors
mean a navigator can deep-link `#configuration` on ANY org repo and land on the
same content. Composes with [LAYOUT-04](#dimension-repo-layout-and-module-layout)/
[CFG-13](#dimension-configuration-cfg)/[VER-12](#dimension-versioning-and-compatibility-ver).
*Enforcement:* a Rust README-shape linter (invoked by `check-all`, NO-SHELL)
parses the markdown AST and fails on a missing/out-of-order/empty required anchor,
a `## Install` lacking both a `go get` block and a Nix snippet, or a `## Release`
lacking a CHANGELOG.md link; the section list comes from a shared
`gsds-readme-sections.yaml`; `caixa-validate` `documented` requires all six anchors.
*Demonstrated by:* the example README carries exactly
`## What / ## Why / ## Install / ## Usage / ## Configuration / ## Release`; its
`## Install` shows both `go get github.com/pleme-io/<lib>` and the
`library-flake.nix` overlay snippet.

**DOC-06** — Every repo MUST maintain a `CHANGELOG.md` in Keep-a-Changelog 1.1.0
format with an `## [Unreleased]` section at top and reverse-chronological released
sections headed `## [x.y.z] - YYYY-MM-DD`, using only the canonical change groups
(`Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`). Every release
git tag MUST correspond to a dated CHANGELOG section of the same version, and that
version MUST match the module's reported version. The `## [Unreleased]` section
MUST be non-empty (or contain an explicit `_No unreleased changes._`) at all times.
*Why:* Go's release model is tag-only (no registry changelog), so the CHANGELOG is
the ONLY human-curated record of what changed between tags; without it a consumer
upgrading `go get`-pulled versions has no narrative for breaking changes;
Keep-a-Changelog gives a typed, parseable shape so release tooling can verify
tag↔entry correspondence mechanically. Composes with
[VER-08](#dimension-versioning-and-compatibility-ver)/[VER-12](#dimension-versioning-and-compatibility-ver)/
[FSM-MODULE](#module-delivery-fsm-module).
*Enforcement:* a Rust changelog linter in `check-all` fails on non-canonical
groups, malformed dates, or a missing `[Unreleased]`; the substrate release helper
(`forge tool release`) REFUSES to push a version tag unless a matching
`## [x.y.z] - <today>` section exists and `[Unreleased]` has been promoted into it
(an FSM hard gate between `publishable` and `released`); CI fails a PR that changes
exported API (via `go/apidiff`) without an `[Unreleased]` entry.
*Demonstrated by:* the example ships `CHANGELOG.md` with `## [Unreleased]`,
`## [1.0.0] - 2026-06-03`, and `### Added`; the release app rejects a tag push when
the dated section is absent.

**DOC-07** — Every repo MUST render cleanly and completely on pkg.go.dev: zero
broken doc links, zero unrendered symbols, and a non-empty module synopsis. The
repo MUST carry a recognized OSI `LICENSE` file (the fleet license is MIT per
[LAYOUT-04](#dimension-repo-layout-and-module-layout); pkg.go.dev requires a
recognized license to display full documentation and source), and the module path
in `go.mod` MUST be the canonical `github.com/pleme-io/<repo>` (or `/vN` for major
versions ≥2) so the published doc URL is deterministic and linkable.

> The "recognized OSI license" required here is **MIT**, the single fleet license
> ([LAYOUT-04](#dimension-repo-layout-and-module-layout)); there is no second
> license. The license check pins MIT exactly.

*Why:* pkg.go.dev is the public boundary of communication for the org — a module
that fails to render (missing/unrecognized LICENSE, non-resolving import path,
broken links) effectively has no documentation for external navigators;
deterministic module paths mean every cross-reference in
[DOC-03](#dimension-documentation-and-discoverability-doc) resolves to a stable
URL. Composes with [LAYOUT-01](#dimension-repo-layout-and-module-layout)/
[VER-02](#dimension-versioning-and-compatibility-ver).
*Enforcement:* `check-all` runs `go vet` (broken doc links) +
`golang.org/x/pkgsite/cmd/pkgsite` in local-render mode against the module, greping
the rendered HTML for per-symbol blocks and failing on any absent symbol or dead
link; a license check fails if `LICENSE` is missing or not a recognized OSI
license; a module-path check fails if the `module` line does not match
`github.com/pleme-io/<repo>(/vN)?`; a post-release scheduled probe hits the live
`pkg.go.dev/github.com/pleme-io/<repo>` and alerts on "documentation not
available".
*Demonstrated by:* the runtime libs ship `LICENSE`; the example pins
`module github.com/pleme-io/<lib>` and the local pkgsite render in CI shows every
exported symbol with resolved `[...]` links.

**DOC-08** — Documentation MUST cross-reference the mandated runtime libraries by
name and symbol wherever the unit consumes them, and MUST NOT document a
hand-rolled equivalent of a capability one of them provides: config docs reference
`shikumi-go`; error construction/wrapping docs reference `errors-go`
(`[errors.New]`/`[errors.Wrap]`/`[errors.WithCode]`); logging docs reference
`logging-go` (`[logging.New]`/`[logging.FromContext]`); CLI/flag/auth docs
reference `cli-go`; process lifecycle/health/teardown docs reference `lifecycle-go`
(`[lifecycle.Run]`); HTTP/retry/client docs reference `todoku-go`; task/DAG/
scheduling docs reference `shigoto-go`; GitHub-Action I/O docs reference
`pleme-actions-shared-go` (`[actions.ParseInputs]`/`[actions.SetOutput]`). Each
README `## Usage` MUST list the mandated libs it depends on as a "Built on" bullet
list with doc-links.
*Why:* the standard's value compounds only if documentation routes readers toward
the shared libraries rather than re-explaining bespoke variants — duplication in
docs is the same bug as duplication in code (the prime directive); naming the libs
in docs makes the dependency graph discoverable from prose alone. Composes with
[LAYOUT-10](#dimension-repo-layout-and-module-layout)/[DOC-03](#dimension-documentation-and-discoverability-doc).
*Enforcement:* a Rust doc-dependency-coherence linter in `check-all` reads
`go.mod`'s require list and, for every mandated lib imported, fails if the README
`## Usage` "Built on" list omits it or its symbols are referenced un-doc-linked; an
anti-duplication check flags doc comments describing a re-implemented mandated
capability for human review; the "Built on" list is generated by a `forge` doc step
so it cannot drift from go.mod.
*Demonstrated by:* the example README `## Usage` opens with "Built on: [shikumi-go],
[errors-go], [logging-go], [lifecycle-go]"; its package doc cross-links
`[logging.FromContext]` and `[errors.Wrap]`; it contains NO hand-rolled
config/error/logging helpers.

**DOC-09** — Every repo MUST satisfy the "anyone can navigate in under N minutes"
test with N=5: starting from a cold open (the GitHub repo root or the pkg.go.dev
page), a reader who has never seen the repo MUST be able to reach (a) what it does,
(b) how to install it, and (c) a working copy-paste example, in ≤5 minutes, using
ONLY the README and pkg.go.dev — no source reading. This is operationalized as a
checklist the canonical example must pass and a periodic verification run.
*Why:* this is the dimension's acceptance criterion — the human-facing definition
of gapless discoverability; all other DOC rules are the mechanisms, this is the
end-state they guarantee; fixing N=5 makes the otherwise-fuzzy "navigable" claim a
measurable, enforceable property. Aggregates
[DOC-01](#dimension-documentation-and-discoverability-doc)..[DOC-08](#dimension-documentation-and-discoverability-doc).
*Enforcement:* a `forge doc navigate-test` Rust tool runs in CI confirming the
README answers what/install/usage above the fold, ≥1 example exists and `go test`
executes it, and the pkg.go.dev synopsis is non-empty, emitting a structured
pass/fail receipt; a quarterly scheduled agent run performs a live cold-open
navigation against a random sample of org repos and files an issue on any repo
failing the three checkpoints; `caixa-validate` `documented` aggregates
[DOC-01](#dimension-documentation-and-discoverability-doc)..[DOC-08](#dimension-documentation-and-discoverability-doc)
as the machine proxy.
*Demonstrated by:* the example is the reference pass: `## What` answers (a) in the
first sentence, `## Install` answers (b) with go get + Nix, and `## Usage` answers
(c) with a fenced block identical to the runnable `Example` in `example_test.go`.

**DOC-10** — All documentation artifacts MUST be deterministically generatable/
verifiable from typed sources — never hand-maintained where a generator exists. The
README "Built on" list, the Nix install snippet, the module path references, and
the CHANGELOG version↔tag correspondence MUST be produced/checked by `forge` doc
subcommands driven by `caixa.lisp` + `go.mod`, not authored free-hand.
Documentation generation/verification MUST be implemented in Rust + tatara-lisp +
Nix + YAML; no shell scripts may implement any doc lint, render, or generation
step.
*Why:* per the org laws, the documentation toolchain is itself a fleet capability
and must obey the same discipline as the code it documents — otherwise the
enforcement layer becomes the very kind of ad-hoc shell glue the org bans;
generating doc fragments from the single typed source guarantees
README↔code↔CHANGELOG coherence by construction. Composes with
[LAYOUT-07](#dimension-repo-layout-and-module-layout)/[DOC-08](#dimension-documentation-and-discoverability-doc).
*Enforcement:* all
[DOC-01](#dimension-documentation-and-discoverability-doc)..[DOC-09](#dimension-documentation-and-discoverability-doc)
checks are Rust analyzers (or `go vet`/golangci-lint/`go test`) wired into
`check-all` + the caixa-validate FSM; the section spec, changelog vocabulary, and
required-anchor list live in shared YAML
(`gsds-readme-sections.yaml`, `gsds-changelog.yaml`); a meta-lint greps the repo's
CI/flake definitions AND the substrate libraries it depends on (`lib/security/**`,
`lib/build/go/**`, `lib/service/**`) and FAILS if any doc, build, or
security-pipeline step is a `pkgs.writeShellScript`/bash/zsh script — the
NO-shell prime directive applies to the substrate's own enforcement code, not just
consumer repos ([SEC-13b](#dimension-security-and-supply-chain-sec)).
*Demonstrated by:* the example's CI invokes only `forge doc verify` (Rust) plus
`go test`/`go vet`/golangci-lint via `check-all`; its README "Built on" list and
Nix snippet are emitted by `forge doc render` from caixa.lisp; zero shell scripting
exists in its doc pipeline.

**DOC-11** — The canonical example repos (`widget-go`, `widgetctl`, `widgetd`,
`widgetkit`, `notify-slack-action`) MUST exist as live pleme-io repos, each
passing `check-all` + its FSM gates, and the standard MUST carry their resolvable
URLs. Every `Demonstrated by:` reference to a canonical-example repo MUST resolve
to a live repo. The canonical example IS the acceptance fixture for the standard's
own tooling.
*Why:* the single most-cited navigation aid is "go read the canonical example";
if those repos do not exist, the entire `Demonstrated by:` column is a dead link
and a new engineer cannot do the one thing the standard tells them to do to learn
the shape. Composes with the [thesis](#the-boundary-of-communication-thesis).
*Enforcement:* `caixa-validate --meta` resolves every canonical-example URL and
fails if any is unreachable or fails `check-all`/its FSM; the example repos run
the substrate `check-all` in their own CI; the GitHub-posture IaC owns their
existence so deletion is a reconcile error.
*Demonstrated by:* the five example repos live at
`github.com/pleme-io/{widget-go,widgetctl,widgetd,widgetkit,notify-slack-action}`
and each green CI run is the acceptance proof; `caixa-validate --meta` is green.

**DOC-12** — The standard MUST carry a [Glossary](#glossary) defining every
load-bearing proper noun (`caixa`, `caixa-validate`, `forge`, `Pillar`, the five
caixa kinds, `tatara-lisp`, `defcaixa`, `pleme-doc-gen`, `mkGoDevShell`,
`check-all`, `lock-platform`, the eight libs, the attestation ecosystem) and
pointing each to its owning repo/skill.
*Why:* a brand-new engineer has no entry point to decode "what IS a caixa" or
"what does `forge` install as"; an undefined proper noun is a cold-start barrier
and a boundary-of-communication leak.
*Enforcement:* `caixa-validate --meta` asserts the Glossary section exists and
that every proper noun the document uses ≥3 times appears as a Glossary row (a
greppable term-coverage check); a missing term fails the meta-check.
*Demonstrated by:* the [Glossary](#glossary) section near the top of this document.

**DOC-13** — The standard MUST carry a role-based reading-order on-ramp
(navigate/build/run → author → ship) so a new engineer reads the relevant 20%
first instead of all 14 dimensions + 4 FSMs flat.
*Why:* "How to use this document" describes organization but a navigator needs a
PATH; 80% of the document is enforcement detail a runner does not yet need.
*Enforcement:* `caixa-validate --meta` asserts the on-ramp is present in "How to
use this document" and references the navigation sections (Glossary, identity
table, concern map, day-one, run/debug, extending).
*Demonstrated by:* the on-ramp in [How to use this document](#how-to-use-this-document).

**DOC-14** — The standard MUST carry an [Identity-derivation table](#identity-derivation-table)
that derives every identity fact from the repo name with zero lookups, and
`caixa-validate` MUST derive identity from exactly the rules that table cites.
*Why:* the thesis claims "zero-lookup navigation" but, without a single table, a
navigator must reconstruct the bijection from 13 sections; the table is the literal
realization of the thesis.
*Enforcement:* `caixa-validate --meta` asserts the table is present and that each
cited owning rule exists; the identity checks in `caixa-validate` reference the
same cells.
*Demonstrated by:* the [Identity-derivation table](#identity-derivation-table).

**DOC-15** — The standard MUST carry a [Concern → library → symbol map](#concern--library--symbol-map)
answering "where is X handled?" in one lookup for every mandated concern.
*Why:* the navigator's core question is "where is config / errors / the HTTP
client?"; the answer was distributed across dense enforcement prose with no index.
*Enforcement:* `caixa-validate --meta` asserts the map is present and lists all
eight libraries with an entry symbol and a construction site.
*Demonstrated by:* the [Concern → library → symbol map](#concern--library--symbol-map).

**DOC-16** — The standard MUST carry the [inter-library composition graph](#inter-library-composition-graph)
(who-imports-whom + canonical wiring order), and the order MUST match
[LIFE-12](#dimension-lifecycle-and-health-life).
*Why:* the eight libs compose; "extend the software" has no map without the
dependency/wiring order. A consumer adopting a breaking major must know the
topological order ([VER-15](#dimension-versioning-and-compatibility-ver)).
*Enforcement:* `caixa-validate --meta` asserts the graph is present and acyclic and
that no lib's `go.mod` imports a lib above it in the graph (cross-checked against
the eight libs' actual `require` blocks).
*Demonstrated by:* the [composition graph](#inter-library-composition-graph); the
eight libs' `go.mod`s match it.

**DOC-17** — The standard MUST carry a gate-triage table mapping each enforcement
family AND each delivery-FSM gate verdict to its local reproduce command, how to
read its output, and the owning rule / fix action.
*Why:* nearly every rule is a build-failing gate; a new engineer who hits a red
gate has no triage path. A gate refusal that names the owning rule and the fix is
the difference between a wall and a fixable error.
*Enforcement:* `caixa-validate --meta` asserts the triage table is present and
covers every analyzer family and every FSM gate; the [FSM status](#fsm-status--observability)
section provides the per-gate verdict→rule→fix mapping that `forge tool status`
emits.
*Demonstrated by:* the [Run & debug recipes](#run--debug-recipes) triage table and
the [FSM status / observability](#fsm-status--observability) gate-verdict table.

**DOC-18** — Generated files MUST carry the sentinel header `# GENERATED BY
pleme-doc-gen — DO NOT EDIT (edit caixa.lisp and regenerate)`, the standard MUST
document the [authored-vs-generated manifest](#authored-vs-generated-files), and
the canonical regenerate command (`pleme-doc-gen caixa --source caixa.lisp --out
.`) MUST be the only sanctioned way to change a generated file.
*Why:* editing the generated surface is forbidden ([LAYOUT-07](#dimension-repo-layout-and-module-layout)/
[LAYOUT-09](#dimension-repo-layout-and-module-layout)), but a navigator who must
legitimately change one was never told the edit→regenerate loop nor which files
are safe to edit; the sentinel + manifest draw the boundary explicitly.
*Enforcement:* `caixa-validate` rejects a generated file lacking the sentinel and a
generated file whose content differs from a fresh `pleme-doc-gen caixa` render
(hand-edit drift); the manifest is asserted present by `caixa-validate --meta`.
*Demonstrated by:* the example's `flake.nix` and `auto-release.yml` carry the
sentinel; the [authored-vs-generated manifest](#authored-vs-generated-files).

**DOC-19** — The standard MUST carry a [Tunables & defaults](#tunables--defaults)
appendix listing every threshold, its default, and whether it is per-repo
overridable and where.
*Why:* magic numbers (`N=5`, `coverage_floor 80%`, glue budget ≤3, grace>timeout,
CVE failOn) were scattered; a navigator cannot find the authoritative tunables in
one place or tell which are overridable.
*Enforcement:* `caixa-validate --meta` asserts the appendix is present and lists
every threshold the document names (a greppable number-coverage check).
*Demonstrated by:* the [Tunables & defaults](#tunables--defaults) appendix.

**DOC-20** — The standard MUST carry an [annotation / escape-hatch catalog](#annotation--escape-hatch-catalog)
listing every `//gsds:*`, `//nolint:*`, `//shigoto:*`, and `//go:build`
annotation, its meaning, and the rule it suppresses; `caixa-validate` MUST reject
any `//gsds:`/`//shigoto:` annotation NOT in the catalog.
*Why:* exemptions and escape hatches were scattered; a navigator encountering one
in code had no central index of what it means or when it is legal, and an
unrecognized annotation could silently suppress a rule.
*Enforcement:* `caixa-validate --meta` asserts the catalog is present and complete
vs the set of annotations the analyzers recognize; `caixa-validate` errors on an
unknown `//gsds:`/`//shigoto:` annotation in any repo.
*Demonstrated by:* the [annotation / escape-hatch catalog](#annotation--escape-hatch-catalog).

> **Day-one DOC alias.** [DOC-03a](#dimension-documentation-and-discoverability-doc):
> every repo README `## Install` MUST state the same day-one path as the
> [Day-one setup](#day-one-setup) section (`nix develop` → `nix run .#check-all` →
> `forge tool status`); enforced by the README-shape linter
> ([DOC-05](#dimension-documentation-and-discoverability-doc)).

---

## Dimension: Versioning and Compatibility (VER)

**VER-01** — Every pleme-io Go repo MUST be versioned with strict Semantic
Versioning 2.0.0 — versions are exactly three dot-separated non-negative integers
`MAJOR.MINOR.PATCH`. MAJOR is bumped only for breaking changes to any exported
(capitalized) identifier in any non-internal package; MINOR for backward-compatible
additions; PATCH for backward-compatible bug fixes. No four-part versions, no
date-versions, no build metadata in the published version, and (outside pre-release
windows, [VER-09](#dimension-versioning-and-compatibility-ver)) no pre-release
suffixes. Bumps are performed exclusively through
`nix run .#bump -- {patch|minor|major}`, never by hand.
*Why:* Go modules and the proxy are built on semver; the entire compatibility
contract (minimal version selection, /vN gating, `go get -u` behavior) assumes
well-formed semver; hand-editing version numbers is the repeatable, error-prone
operation the org bans; a consumer must be able to look at any tag and know, from
the number alone, whether upgrading is safe. Composes with
[VER-05](#dimension-versioning-and-compatibility-ver)/[VER-12](#dimension-versioning-and-compatibility-ver)/
[FSM-MODULE](#module-delivery-fsm-module).
*Enforcement:* `forge tool bump` (`nix run .#bump`, wired by
`build/go/{tool-release,library,workspace-release}-flake.nix` via
`release-helpers.nix mkBumpApp`) parses through `forge/cli/src/version.rs`
(`parse_semver` `bail!`s on non-X.Y.Z, `bump_semver` enforces the transition); CI
rejects any tag push failing `^v\d+\.\d+\.\d+$` ([VER-03](#dimension-versioning-and-compatibility-ver)).
*Demonstrated by:* the example tags releases only via `nix run .#bump -- minor`
then the FSM ([VER-12](#dimension-versioning-and-compatibility-ver)); no runtime lib
carries a `version =` field (Go has no manifest version — [VER-04](#dimension-versioning-and-compatibility-ver)).

**VER-02** — For any major version v2 or higher, the module path declared on the
`module` line of go.mod MUST end with the matching `/vN` major-version suffix (e.g.
`module github.com/pleme-io/cli-go/v2`). v0 and v1 carry NO suffix. The suffix MUST
equal the MAJOR component of the current version exactly. Importers MUST import
using the suffixed path, and the suffix MUST be reflected in every internal
intra-module import.
*Why:* this is Go's Semantic Import Versioning hard rule — different major versions
are different modules so v1 and v2 can coexist without diamond conflicts; omitting
the suffix makes `go get module/v2@v2.0.0` fail with a path-mismatch and strands
consumers on v1; the module path must self-describe its compatibility horizon.
Composes with [LAYOUT-01](#dimension-repo-layout-and-module-layout)/
[VER-06](#dimension-versioning-and-compatibility-ver)/[DOC-07](#dimension-documentation-and-discoverability-doc).
*Enforcement:* CI runs `go vet` plus a forge check asserting the go.mod `module`
suffix equals the MAJOR of the latest semver tag (the Tagged transition in
[VER-12](#dimension-versioning-and-compatibility-ver) is blocked when MAJOR≥2 and
the suffix is absent/mismatched); `library-flake.nix`/`workspace-release-flake.nix`
accept `modRoot` so multi-module roots are tagged path-correctly
([VER-11](#dimension-versioning-and-compatibility-ver)); `go build ./...` in the
Nix sandbox fails on suffix/import mismatch.
*Demonstrated by:* akeyless-go is the live exemplar — go.mod declares
`module github.com/akeylesslabs/akeyless-go/v5` and
`go get .../akeyless-go/v5` resolves the v5.x line; the canonical example ships at
v1 with the bare path and documents the exact go.mod edit + import rewrite for a v2
crossover.

**VER-03** — Released versions MUST be published as annotated git tags in the exact
format `vX.Y.Z` — lowercase `v` prefix, no `release-`/`rel/` prefixes, no
`-rc`/build suffix on a final release, no leading zeros. There is exactly one tag
per release; tags are immutable and MUST NEVER be force-moved, deleted-and-
recreated, or re-pointed. For multi-module repos the tag is `<modRoot>/vX.Y.Z`
([VER-11](#dimension-versioning-and-compatibility-ver)).
*Why:* Go derives the module version directly from the git tag —
`proxy.golang.org` caches `(module, vX.Y.Z) -> content hash` permanently on first
fetch; a moved/deleted tag produces a `checksum mismatch` / `SECURITY ERROR` for
every downstream consumer forever; the `v` prefix is mandatory (Go does not
recognize a bare `1.2.3` tag); immutability is the bedrock of the whole
compatibility promise. Composes with [LAYOUT-05](#dimension-repo-layout-and-module-layout)/
[VER-12](#dimension-versioning-and-compatibility-ver)/[FSM-MODULE](#module-delivery-fsm-module).
*Enforcement:* `forge tool release` (`nix run .#release` →
`release-helpers.nix mkReleaseApp` → `forge tool release --language go`) is the only
sanctioned tagging path; a CI/branch-protection gate rejects any tag push not
matching `^v\d+\.\d+\.\d+$` and any force-update/deletion of an existing `v*` tag;
the module proxy enforces immutability downstream.
*Demonstrated by:* the example's release workflow runs only `nix run .#release`;
there is no `git tag` call anywhere; akeyless-go's published tags are all `vX.Y.Z`
(e.g. v5.0.22).

**VER-04** — For a Go module the SINGLE source of truth for the version is the git
tag itself — there is NO `version = ` field in go.mod, no VERSION file, and no
constant that participates in release identity. Any version string a binary needs
at runtime (e.g. a `--version` flag) MUST be injected at build time via
`-ldflags -X` from the substrate builder's `version` argument, never read from a
committed file.
*Why:* Go deliberately has no manifest version field; inventing one creates a second
source of truth that drifts from the tag (the anti-duplication prime directive
forbids a second hand-maintained copy); build-time injection keeps the binary's
self-reported version provably equal to the tag the artifact was built from.
Composes with [CLI-04](#dimension-cli-ux-cli)/[SEC-01](#dimension-security-and-supply-chain-sec).
*Enforcement:* `forge/cli/src/version.rs` implements readers for Cargo.toml,
build.zig.zon, Chart.yaml, and package.json but NONE for go.mod (nothing to read),
so `forge tool bump --language go` computes the next version from the latest tag;
substrate Go builders inject `version` via ldflags; CI greps the repo and fails if a
`VERSION` file or `var Version = "x.y.z"` literal is committed.
*Demonstrated by:* all eight runtime libs contain no version field (their go.mod
carries only `module …` and `go 1.25`); `workspace-release-flake.nix` threads a
single `version` arg into ldflags for every binary; the example binary prints its
version from that injected value.

**VER-04a** — The ldflags version-injection TARGET is declared, not assumed. The
default is `main.version` ([CLI-04](#dimension-cli-ux-cli)); a monorepo binary that
injects into a different package (e.g. the k8s-style
`k8s.io/component-base/version` with `gitVersion`/`gitMajor`/`gitMinor`/
`gitTreeState`/`buildDate`) MUST declare its `:version-package` per binary in
`caixa.lisp`, and the `--version` conformance harness reads the declared package.
*Why:* `monorepo.nix` injects into a configurable `versionPackage`; a maintainer
following CLI-04's `main.version` blindly on a k8s-style monorepo gets a
`--version` that reads `version.gitVersion` and the smoke test fails. Declaring the
target closes the gap between the rule and the builder. Composes with
[CLI-04](#dimension-cli-ux-cli)/[VER-04](#dimension-versioning-and-compatibility-ver)/
[VER-11a](#dimension-versioning-and-compatibility-ver).
*Enforcement:* `caixa-validate` records the injection target per binary from
`caixa.lisp` `:version-package` (default `main`) and asserts the substrate builder's
`versionPackage` matches; the `--version` harness reads the declared package; a
mismatch fails the build.
*Demonstrated by:* `widgetkit`'s `caixa.lisp` declares
`:binaries [ (:name "widgetctl" :version-package "main") (:name "widgetkube" :version-package "k8s.io/component-base/version") ]`;
each binary's `--version` reads its declared package.

**VER-05** — API stability is governed by the MAJOR component. While MAJOR = 0 (the
0.x line) there is NO stability promise: any 0.y.z → 0.(y+1).0 MAY break the
exported API, and the standard treats a 0.x MINOR bump as the breaking-change
channel. From MAJOR ≥ 1 onward the exported surface of every non-internal package
is FROZEN within a major line: no exported identifier may be removed, renamed, have
its signature changed, or have its documented semantics altered without a MAJOR
bump (which, per [VER-02](#dimension-versioning-and-compatibility-ver), also moves
the module path to /v(N+1)).
*Why:* Go tooling encodes exactly this split — `go get -u` upgrades within a major
line but never jumps majors automatically, because v1+ promises non-breakage and
v0 promises nothing; spelling the promise out per-line removes the gap a consumer
hits when deciding whether a `minor` bump is safe and tells authors when they MUST
cross a major boundary. Composes with [VER-06](#dimension-versioning-and-compatibility-ver)/
[VER-08](#dimension-versioning-and-compatibility-ver).
*Enforcement:* CI runs an exported-API diff (apidiff/`go/packages`-based) between
the latest tag and HEAD; on a v1+ module a detected incompatible change blocks the
Tagged transition unless the bump level is `major`; on a v0 module the diff is
advisory (recorded in release notes, [VER-08](#dimension-versioning-and-compatibility-ver));
`forge tool bump`'s level argument is the typed gate selecting which promise
applies.
*Demonstrated by:* the example's CI apidiff job is shown failing a `minor` bump that
removed an exported function, then passing once re-run as `major`.

**VER-06** — Breaking the exported API of a v1+ module is permitted ONLY by crossing
a major boundary, which is an atomic three-part operation that MUST happen together
in one change: (a) bump MAJOR via `nix run .#bump -- major`, (b) update the go.mod
`module` line to the new `/vN` suffix and rewrite all intra-module imports, and (c)
for the v2→v3+ case keep the prior major's source reachable (its tags remain, its
module path remains importable). Cherry-picking only (a) or only (b) is forbidden.
*Why:* a MAJOR bump without the matching /vN suffix produces a module the proxy
refuses to serve at the new version; a suffix change without a MAJOR bump
misrepresents compatibility; tying the three together as one typed operation is the
only way to make major transitions mechanically repeatable and gap-free. Composes
with [VER-02](#dimension-versioning-and-compatibility-ver)/[VER-07](#dimension-versioning-and-compatibility-ver).
*Enforcement:* `forge tool release` on a major bump validates go.mod suffix == new
MAJOR before it will create the tag (FSM gate); `go build ./...` fails if
intra-module imports were not rewritten; a CI invariant asserts prior-major tags
still resolve via the proxy after the transition.
*Demonstrated by:* akeyless-go has crossed multiple majors and now sits at `/v5`
with all prior major paths resolvable; the example documents the one-shot
`bump -- major` + suffix-rewrite procedure and shows the CI gate rejecting a
half-done transition.

**VER-07** — Deprecation is a typed, staged process, never a silent removal. To
retire an exported identifier on a v1+ module: (1) in a MINOR release add a
`// Deprecated: <reason; replacement; earliest-major-for-removal>` doc comment per
the gofmt/godoc convention, keeping it fully functional; (2) where the deprecated
path is hit at runtime, surface it through `logging-go` at WARN with a stable,
greppable deprecation code (NOT via panic, fmt.Println, or a bespoke logger); (3)
classify any error a deprecated path returns through `errors-go`; (4) remove the
identifier ONLY in the next MAJOR (with the [VER-06](#dimension-versioning-and-compatibility-ver)
transition). Removal in a MINOR or PATCH is forbidden.
*Why:* Go's `Deprecated:` convention is understood by gopls, staticcheck, and
pkg.go.dev, so marking-then-removing gives consumers a tooling-visible migration
window without breaking them mid-major; routing the runtime warning through
logging-go and error classification through errors-go means deprecations are
observable and queryable across the fleet. Composes with
[ERR-02](#dimension-errors-err)/[OBS-08](#dimension-observability-obs)/[DOC-02](#dimension-documentation-and-discoverability-doc).
*Enforcement:* staticcheck SA1019 flags use of deprecated identifiers; a forge
check PARSES the `// Deprecated:` comment's `earliest-major-for-removal` field and
asserts any exported identifier removed since the last tag (a) carried the comment
for ≥1 prior MINOR, (b) is being removed at or after its stated
`earliest-major-for-removal` (NOT earlier), AND (c) the current bump is `major`,
else the Tagged transition is blocked; lint rejects deprecation warnings emitted
via anything other than logging-go.
*Demonstrated by:* the example deprecates an exported helper in v1.4.0 with
`// Deprecated: use Foo; removal earliest v2`, emits a logging-go WARN with code
DEP-0001 wrapped in an errors-go-classified error when the old path runs, and the
gate blocks a removal attempted at v1.9→v2 only if the comment promised v3, while
allowing removal at v2 when the comment said v2.

**VER-08** — Every released version MUST ship machine-checkable release notes that
classify the change set as breaking / feature / fix, and the classification MUST be
consistent with the chosen bump level (a `major` bump REQUIRES at least one
breaking entry; a `minor` MUST have at least one feature and zero breaking; a
`patch` MUST be fixes-only). Release notes are generated, not hand-curated, from
conventional-commit-style messages collected since the previous tag.
*Why:* the bump level and the change classification are two views of the same truth
— if they disagree, the semver promise ([VER-05](#dimension-versioning-and-compatibility-ver))
is a lie; deriving notes from commits removes a duplicated, drift-prone
hand-maintained changelog and gives downstream consumers (and the apidiff gate) a
single authoritative statement. Composes with [VER-05](#dimension-versioning-and-compatibility-ver)/
[DOC-06](#dimension-documentation-and-discoverability-doc).
*Enforcement:* `forge tool release` generates the notes from `<prev-tag>..HEAD` and
cross-checks the classification against the bump level (a mismatch blocks the Tagged
transition); CI rejects a release whose notes are empty or whose classification
contradicts the apidiff result from [VER-05](#dimension-versioning-and-compatibility-ver).
*Demonstrated by:* the example's GitHub Release body is produced entirely by
`nix run .#release`; a `minor` release is rejected because a commit was tagged
`feat!:` (breaking) and accepted once re-run as `major`.

**VER-09** — Pre-release versions are permitted only as explicitly-suffixed semver
pre-releases of the form `vX.Y.Z-rc.N` (or `-alpha.N`/`-beta.N`) on tags, and they
are NEVER a stable target: a pre-release tag MUST be lower-precedence than its final
and MUST NOT be consumed by any production go.mod `require`. Final releases carry no
pre-release suffix ([VER-01](#dimension-versioning-and-compatibility-ver)).
Pseudo-versions (the `v0.0.0-YYYYMMDDHHMMSS-abcdef` form Go synthesizes for
untagged commits) are tolerated transiently in a consumer's go.mod ONLY when
depending on an unreleased upstream fix, and MUST be replaced with a real tagged
version before that consumer is itself released.
*Why:* semver precedence makes `vX.Y.Z-rc.1 < vX.Y.Z`, so MVS prefers the final
over the rc automatically — but only if rcs are spelled in the canonical
pre-release form; pseudo-versions are how Go pins an untagged commit, and leaving
one in a released module's go.mod ships an unauditable, non-reproducible dependency
and defeats the tag-as-source-of-truth contract
([VER-04](#dimension-versioning-and-compatibility-ver)). Composes with
[VER-10](#dimension-versioning-and-compatibility-ver).
*Enforcement:* `forge tool release` validates pre-release tag shape and refuses to
mark a `-rc` tag Released/Promoted; a CI gate scans every released module's go.mod
and fails the Tagged transition if any `require` on a pleme-io module is a
pseudo-version or a pre-release; ADDITIONALLY, a non-blocking CI WARNING fires on
EVERY PR (not only at release) for any pleme-io pseudo-version `require`, escalating
to blocking only at the Tagged boundary — so a long multi-lib upgrade surfaces the
transient pin continuously instead of only at the release wall; `go mod verify`
runs in the Nix sandbox.
*Demonstrated by:* the example cuts `v1.5.0-rc.1`, exercises it in staging, then
`nix run .#bump -- minor` + release to `v1.5.0`; every PR carrying a pseudo-version
pin on `errors-go` (while adopting an unreleased `/v2`) shows a yellow warning, and
CI rejects the eventual release until the pin is repointed to a tagged version.

**VER-10** — go.mod compatibility MUST be explicit and minimal: (1) the `go`
directive states the minimum supported toolchain and is uniform across a coherent
set of repos (currently `go 1.25` for all mandated runtime libs); raising it is a
MINOR change (toolchain floor lift) and lowering it is forbidden within a major
line. (2) Every `require` on a pleme-io runtime lib MUST pin a real released
`vX.Y.Z` tag at the correct /vN module path. (3) go.sum MUST be committed and
complete; `go mod tidy` MUST leave the tree clean. (4) No `replace` directive may
point at a local path or fork in a released module. (5) A `go.work`/`go.work.sum`
MUST NOT be committed to a released module — local cross-module dev uses an
UNCOMMITTED `go.work` (gitignored); a committed workspace file is a
reproducibility hazard identical to a local `replace`. (6) A `toolchain` directive
(distinct from the `go` directive) MUST be absent or `GOTOOLCHAIN=local` — a
`toolchain go1.X.Y` line would pin a PATCH and trigger auto-download, contradicting
[LAYOUT-02](#dimension-repo-layout-and-module-layout)'s "never a patch".
*Why:* the `go` directive is part of the compatibility contract (it tells the proxy
and downstream builds the language/stdlib floor) and a uniform floor prevents a
consumer being forced into incompatible toolchains by transitive pins; a dirty
go.sum, a local `replace`, a committed `go.work`, or a patch-pinning `toolchain`
line each makes a release non-reproducible or breaks the eval-time toolchain assert;
pinning all shared libs through one mechanism is the anti-duplication law at the
dependency layer. Composes with [LAYOUT-02](#dimension-repo-layout-and-module-layout)/
[LAYOUT-10](#dimension-repo-layout-and-module-layout)/
[LAYOUT-12](#dimension-repo-layout-and-module-layout)/[SEC-10](#dimension-security-and-supply-chain-sec).
*Enforcement:* `mkGoLibraryCheck`/the build flakes run `go build ./...` and the
release path runs `go mod verify`; a CI gate runs `go mod tidy` and fails on a
non-empty diff, fails on any relative-path `replace` in a release, fails on a
committed `go.work`/`go.work.sum`, and asserts every pleme-io `require` resolves to
a tagged version at a suffix matching its major; the `go` directive value is
asserted against the fleet floor and the `tool.nix` eval-time assert ALSO rejects a
`toolchain` line ahead of `pkgs.go.version`.
*Demonstrated by:* all eight runtime libs declare `go 1.25` with committed go.sum,
no `go.work`, and no `toolchain` line; the example requires the runtime libs at
`vX.Y.Z`, has a clean `go mod tidy`, gitignores `go.work`, and CI fails a release
that left a `replace github.com/pleme-io/errors-go => ../errors-go` line or a
committed `go.work` in place.

> **VER-11 is two distinct concepts — do not conflate them.** A "multi-binary
> monorepo" ([LAYOUT-08](#dimension-repo-layout-and-module-layout), VER-11a) has
> ONE `go.mod`, N binaries, ONE shared version, ONE repo-root tag. A
> "multi-module repo" (VER-11b) has N `go.mod` files in subdirectories, each
> tagged `<modRoot>/vX.Y.Z` with INDEPENDENT majors. The two use different
> builders and different ecosystems and MUST NOT be mixed.

**VER-11a** — A single-module multi-binary monorepo (`:ecosystem "go-monorepo"`,
[LAYOUT-08](#dimension-repo-layout-and-module-layout)) has exactly ONE `go.mod` at
the repo root, ONE shared version, and ONE repo-root `vX.Y.Z` tag; `mkGoMonorepoSource`
supplies one src+version+ldflags and feeds N `mkGoMonorepoBinary` calls. Every
binary in the monorepo shares the repo's single version — per-binary independent
versions are NOT possible under this ecosystem (use VER-11b for that). A
`go-monorepo` repo MUST contain exactly one `go.mod`.
*Why:* `mkGoMonorepoBinary` inherits a single `monoSrc.version` by construction —
"one src, one version, one ldflags per repo" ([LAYOUT-08](#dimension-repo-layout-and-module-layout));
attempting per-submodule versions from this builder is impossible, so the rule and
the builder must agree. Composes with [LAYOUT-08](#dimension-repo-layout-and-module-layout)/
[VER-04a](#dimension-versioning-and-compatibility-ver).
*Enforcement:* `caixa-validate` asserts `:ecosystem "go-monorepo"` ⇒ exactly one
`go.mod` (a second `go.mod` under that ecosystem is rejected — use VER-11b); the
single repo-root tag is composed by `forge tool release`; CI rejects a path-prefixed
tag under `go-monorepo`.
*Demonstrated by:* `build/go/monorepo.nix` (the kubernetes/kubernetes pattern: one
`mkGoMonorepoSource` → kubelet/kubeadm/… all at the one repo version); `widgetkit`
tags one repo-root `v1.2.0` for all its binaries.

**VER-11b** — A true multi-module repo (`:ecosystem "go-multi-module"`, a repo with
`go.mod` files in subdirectories) MUST tag each contained module independently
using the path-prefixed form `<modRoot>/vX.Y.Z` (e.g. `worker/v1.3.0`), each
module built via `workspace-release-flake.nix` with its `modRoot`, and each
module's major line + stability promise INDEPENDENT. A single repo-root `vX.Y.Z`
tag is permitted only when the repo is single-module at the root. The build, the
/vN suffix check, and the tag prefix all derive from `modRoot`.
*Why:* Go resolves a submodule version from the path-prefixed tag, not the
repo-root tag; a bare `vX.Y.Z` on a submodule makes `go get repo/worker@vX.Y.Z`
unresolvable; the org runs Go multi-module repos so the standard must close the gap
explicitly and separately from the multi-binary case. Composes with
[VER-02](#dimension-versioning-and-compatibility-ver)/[VER-11a](#dimension-versioning-and-compatibility-ver).
*Enforcement:* `workspace-release-flake.nix` accepts `modRoot`; `forge tool release`
composes `<modRoot>/vX.Y.Z` and evaluates the [VER-02](#dimension-versioning-and-compatibility-ver)
suffix gate per module; CI rejects a path-prefix-less submodule tag and a repo-root
`vX.Y.Z` tag when >1 `go.mod` exists; `caixa-validate` asserts `:ecosystem
"go-multi-module"` ⇒ ≥2 `go.mod`.
*Demonstrated by:* the `workspace-release-flake.nix` path (the Go sibling of the
Rust workspace flake) tags `worker/v0.4.0` and `api/v1.1.0` from one repo, each
with its own /vN suffix and stability tier.

**VER-14** — A bad PUBLISHED library version MUST be repudiated by RETRACTION, never
by moving or deleting a tag ([VER-03](#dimension-versioning-and-compatibility-ver)
immutability). To withdraw a broken `vX.Y.Z`: publish a follow-up patch
`vX.Y.(Z+1)` whose `go.mod` carries a `retract vX.Y.Z // <reason>` directive (and,
for a whole bad minor line, `retract [vX.Y.0, vX.Y.Z]`). `forge tool release` emits
the `retract` block; FSM-MODULE's `Rollback` from `Tagged`/`Proxied`/`ProxyTimedOut`
means "publish a retracting patch" when the proxy has already cached, NOT a no-op
([ModuleRollbackGate](#module-delivery-fsm-module)). Additionally, an intra-repo
diamond — two submodules in one VER-11b repo requiring different majors of a third
sibling submodule — is flagged (warn) unless annotated `//gsds:multi-major-intentional`.
*Why:* [VER-03](#dimension-versioning-and-compatibility-ver) immutability with NO
escape hatch strands consumers on a broken version forever (the proxy caches it
permanently); `retract` is Go's sanctioned, tooling-visible repudiation —
`go get -u` skips a retracted version and `go list -m -retracted` surfaces it. The
intra-repo coherence check prevents one repo silently holding two majors of a
sibling. Composes with [VER-03](#dimension-versioning-and-compatibility-ver)/
[VER-09](#dimension-versioning-and-compatibility-ver)/[VER-11b](#dimension-versioning-and-compatibility-ver)/
[FSM-MODULE](#module-delivery-fsm-module).
*Enforcement:* `forge tool release` injects the `retract` directive and a CI gate
asserts a withdrawn version (recorded in a `retractions.yaml`) carries a `retract`
in a published successor; FSM-MODULE's `ModuleRollbackGate` requires either
"proxy-not-yet-cached ⇒ delete-safe" OR "publish retracting patch"; `caixa-validate`
runs INTRA-REPO-MAJOR-COHERENCE over VER-11b modules.
*Demonstrated by:* the example ships a broken `errors-go v1.4.3`, then `v1.4.4`
whose go.mod carries `retract v1.4.3 // panics on empty input`; `go get -u` skips
v1.4.3 and `go list -m -retracted` shows it withdrawn.

**VER-12** — Version identity and the delivery FSM are coupled by one inviolable
invariant: the FSM `Tagged` state is reached IF AND ONLY IF a `vX.Y.Z` git tag (or
`<modRoot>/vX.Y.Z` for submodules) pointing at the exact commit that passed
`Checked`/`Built` has been created and pushed by `forge tool release`. The version
source of truth (the tag, [VER-04](#dimension-versioning-and-compatibility-ver)) and
the FSM state are the same fact viewed two ways — there is no Tagged-without-tag and
no released tag that did not transit Checked → Built → Tagged. Because Go release is
pull-model and tag-only (no registry upload), `Tagged` is also the publish event:
the module becomes consumable the instant the proxy fetches the tag.
*Why:* Go has no separate upload step (the way Rust's `cargo publish` does) — a Go
module is published by pushing a semver git tag and the proxy fetches lazily; so
conflating any other artifact with "published" would create a phantom state;
anchoring the FSM `Tagged` state to tag existence makes the delivery machine's state
machine-derivable from `git` + the proxy. This is the code-level statement of the
[`FSM-MODULE`](#module-delivery-fsm-module) machine. Composes with
[LAYOUT-05](#dimension-repo-layout-and-module-layout)/all VER gates.
*Enforcement:* `forge tool release` performs the Checked → Built → Tagged
transition atomically and is the only mutator of the Tagged state; the
[VER-01](#dimension-versioning-and-compatibility-ver)/[VER-02](#dimension-versioning-and-compatibility-ver)/
[VER-03](#dimension-versioning-and-compatibility-ver)/[VER-05](#dimension-versioning-and-compatibility-ver)/
[VER-06](#dimension-versioning-and-compatibility-ver)/[VER-08](#dimension-versioning-and-compatibility-ver)/
[VER-09](#dimension-versioning-and-compatibility-ver)/[VER-10](#dimension-versioning-and-compatibility-ver)/
[VER-11](#dimension-versioning-and-compatibility-ver) gates ALL evaluate at the
Tagged boundary, so a malformed version, wrong /vN suffix, classification/bump
mismatch, dirty go.sum, or local replace blocks entry to Tagged; tag immutability
([VER-03](#dimension-versioning-and-compatibility-ver)) makes the state monotonic;
the proxy's permanent cache makes Tagged observable fleet-wide.
*Demonstrated by:* the example's only release surface is `nix run .#release`, which
drives the FSM through `release-helpers.nix mkReleaseApp` → `forge tool release
--language go`; `library-flake.nix`'s header documents the tag-only pull-model;
`go get <module>@vX.Y.Z` succeeds the moment the tag is pushed.

**VER-13** — Consuming a breaking upgrade of a pleme-io lib is a TYPED OPERATION,
not a hand-edit. `forge tool upgrade --dep github.com/pleme-io/<lib> --to vN`
rewrites every import to the `/vN` path, bumps the `go.mod` `require`, runs `go mod
tidy`, and re-pins; a manual import rewrite is forbidden (it is the repeatable,
error-prone op the org bans). A CI gate asserts no consumer pins TWO majors of the
same pleme-io lib (cross-module diamond) and no consumer pins a lib below the fleet
floor.
*Why:* the standard governs how YOU cut a release but, until now, never how a repo
CONSUMES one — the literal "maintaining a repo across breaking changes" scenario was
ungoverned; when `errors-go` ships `/v2`, every consumer must rewrite imports, bump
go.mod, re-tidy, and re-pin, and leaving that manual is exactly the boundary leak
the standard exists to close. Composes with [VER-02](#dimension-versioning-and-compatibility-ver)/
[VER-06](#dimension-versioning-and-compatibility-ver)/[VER-15](#dimension-versioning-and-compatibility-ver).
*Enforcement:* `forge tool upgrade` performs the rewrite+bump+tidy+repin
atomically; a CI gate scans the import graph and fails a consumer pinning two
majors of one pleme-io module or pinning below the fleet floor; `go build ./...` in
the sandbox proves the rewrite is complete.
*Demonstrated by:* the example runs `forge tool upgrade --dep
github.com/pleme-io/errors-go --to v2`, which rewrites
`errors-go` → `errors-go/v2` imports, bumps the require, and re-tidies; CI rejects
a state where `api` pins `errors-go/v2` while `worker` still pins `errors-go`
(diamond).

**VER-15** — A breaking-major upgrade of an inter-lib dependency MUST propagate in
TOPOLOGICAL ORDER over the [inter-library composition graph](#inter-library-composition-graph):
root→leaf. When `errors-go` v1→v2, every lib that imports it (logging-go,
shikumi-go, todoku-go, lifecycle-go, shigoto-go, cli-go) MUST adopt `/v2` and
RE-RELEASE before any leaf consumer finishes its upgrade. The upgrade DAG is a
`shigoto-go` DAG (the org idiom); a leaf MUST NOT adopt a new major of a lib whose
intermediate dependencies have not yet adopted it.
*Why:* the mandated libs depend on each other; adopting a leaf to `errors-go/v2`
while `logging-go` still pins v1 produces a two-major diamond on `errors-go` across
the import graph — a runtime-incoherence trap. A topological order is the only
gap-free fleet-coordination story. Composes with [VER-13](#dimension-versioning-and-compatibility-ver)/
[DOC-16](#dimension-documentation-and-discoverability-doc)/[FSM-MODULE](#module-delivery-fsm-module).
*Enforcement:* the fleet upgrade is authored as a `shigoto-go` DAG whose edges are
the composition graph; `forge tool upgrade --fleet` drives it root→leaf; a CI gate
fails a consumer release whose import graph pulls two majors of any single pleme-io
module; `caixa-validate` cross-checks adoption order against
[DOC-16](#dimension-documentation-and-discoverability-doc).
*Demonstrated by:* an `errors-go` v2 fleet upgrade is a shigoto DAG: `errors-go`
releases v2 → `logging-go`/`shikumi-go`/`todoku-go` adopt+release → `lifecycle-go`/
`shigoto-go` → `cli-go`/`pleme-actions-shared-go` → leaf services last; the gate
blocks any leaf jumping ahead.

**VER-16** — The proxy-confirmation deadline and retry budget (FSM-MODULE) are
TYPED, not implicit. `shikumi-go` types `delivery.proxy_poll_deadline` (Duration,
default `600s`, lower-bounded) and `delivery.proxy_poll_retries` (default `30`);
the `ConfirmProxy` self-loop consumes a `poll_budget_exhausted` fact, so the
`Proxied → ProxyTimedOut` transition is an IN-FSM, audited transition driven by an
enumerated signal — never an out-of-band state mutation (which the gapless table
forbids, [FSM-MODULE](#module-delivery-fsm-module)).
*Why:* the prior FSM said the scheduler drives `Proxied → ProxyTimedOut`
out-of-FSM, but the gapless-table invariant forbids reaching a state no enumerated
signal produces; an unbounded `ConfirmProxy` self-loop polls forever and the FSM
state never reflects the timeout. Typing the deadline + making the timeout an
in-table transition closes both. Composes with [FSM-MODULE](#module-delivery-fsm-module)/
[LIFE-04](#dimension-lifecycle-and-health-life).
*Enforcement:* `nix flake check` asserts both fields are present and lower-bounded;
FSM-MODULE's `(Proxied, ConfirmProxy)` cell yields `Proxied` while
`!poll_budget_exhausted` else `ProxyTimedOut`; the transition emits an audit record
([FSM-AUDIT](#delivery-fsm-type-system)).
*Demonstrated by:* the example sets `delivery.proxy_poll_deadline = "600s"`; a
proxy outage drives 30 `ConfirmProxy` self-loops then one audited `Proxied →
ProxyTimedOut` transition surfaced by `forge tool status`.

**VER-17** — A major crossover ([VER-06](#dimension-versioning-and-compatibility-ver))
is an FSM-MODULE STATE, not a prose obligation: when `major(version) >
major(lastTag)`, FSM-MODULE inserts a `MajorCrossover` pre-gate that asserts the
go.mod `/vN` suffix rewrite AND all intra-module import rewrites AND the
prior-major-reachability check all hold IN THE SINGLE VALIDATED SNAPSHOT — making
VER-06's atomicity machine-enforced. Landing the suffix in one commit and the
import rewrite in another (each passing its own gate) is rejected because the
crossover gate evaluates them together.
*Why:* VER-06 says "cherry-picking only (a) or only (b) is forbidden," but the
prior FSM only checked suffix-coherence at `TagGate(d)`, not the atomicity of the
whole crossover, so a maintainer could split it across commits and pass each gate
individually. A dedicated crossover state makes the atomicity unreachable-to-violate.
Composes with [VER-02](#dimension-versioning-and-compatibility-ver)/
[VER-06](#dimension-versioning-and-compatibility-ver)/[FSM-MODULE](#module-delivery-fsm-module).
*Enforcement:* FSM-MODULE's `MajorCrossoverGate` (active only when the major
increments) conjoins `major_suffix_ok ∧ all_intramodule_imports_rewritten ∧
prior_major_resolvable` over one snapshot; `go build ./...` proves the import
rewrite; a CI invariant asserts prior-major tags still resolve via the proxy.
*Demonstrated by:* akeyless-go's `/v5` crossover is shown landing suffix + import
rewrite in one validated snapshot; a split attempt is blocked at the
`MajorCrossover` gate.

---

## Dimension: Testing and Quality (TEST)

**TEST-01** — Every exported function, method, and FSM transition is exercised by a
TABLE-DRIVEN test: a `tests := []struct{ name string; ... }` slice iterated with
`for _, tt := range tests { t.Run(tt.name, func(t *testing.T){ ... }) }`. One
ad-hoc assertion sequence per behavior is forbidden; new cases are added as table
rows, never as copy-pasted test functions. Subtests MUST be named so failures are
addressable as `TestFoo/case_name`.
*Why:* the table is the typed boundary of communication — a reader sees the full
input/output contract of a unit as data in one place and adds a case by adding a row
(the testing-layer expression of the PRIME DIRECTIVE: the row is the macro instance,
the loop is the macro); named subtests make `go test -run TestFoo/case` a precise
navigation primitive. Composes with [DOC-04](#dimension-documentation-and-discoverability-doc)/
[TEST-10](#dimension-testing-and-quality-test).
*Enforcement:* `forge tool check --language go` (invoked by `nix run .#check-all`,
`release-helpers.nix:mkCheckAllApp`) runs the suite; a CI lint stage rejects any
`*_test.go` declaring >1 top-level `Test*`/`Benchmark*` over the same exported
symbol without a `[]struct` table; `t.Run` presence is required for any test with
>1 case.
*Demonstrated by:* `errors-go/errors_test.go` `TestSeverity_String` and `TestNew`
are both `tests := []struct{...}` slices iterated under `t.Run(tt.name, ...)`; the
example replicates this for every exported symbol.

**TEST-02** — CI runs `go test -race ./...` on EVERY package, not a curated subset.
The race detector is mandatory and non-optional in CI; a data race detected by
`-race` is a hard failure regardless of whether the test otherwise passed.
*Why:* all mandated runtime libs ship concurrent surfaces — lifecycle-go
(runloop/shutdown), shigoto-go (scheduler/budget over a DAG), shikumi-go (watch) —
where a race is a latent production defect invisible to a non-race run; making
`-race` the only CI test invocation closes the gap where green tests hide
concurrency bugs. Composes with [JOB-08](#dimension-concurrency-and-jobs-job)/
[JOB-09](#dimension-concurrency-and-jobs-job)/[TEST-10](#dimension-testing-and-quality-test).
*Enforcement:* `forge tool check --language go` always passes `-race` (the forge
Rust binary owns the flag set per the NO-shell law — no hand-rolled `go test` shell
wrapper); the GitHub Actions job (a `pleme-actions-shared-go`-built action, never an
inline `run: go test`) calls `nix run .#check-all`; CGO is enabled in the substrate
`goToolchain` (`toolchain.nix` `CGO_ENABLED=1`) which `-race` requires.
*Demonstrated by:* the example's `flake.nix` wires `build/go/library-flake.nix` (or
`workspace-release-flake.nix`), whose `check-all` app delegates to `forge tool
check --language go`; the CI workflow invokes only that app.

**TEST-03** — A coverage FLOOR of 80% statement coverage per module is enforced;
the build fails below it. Coverage is measured with
`go test -coverprofile -covermode=atomic ./...` (atomic mode is mandatory because it
composes with `-race`). The floor is a single number declared in the repo's
`caixa.lisp`/build spec, never hand-coded into a shell threshold.
*Why:* a floor turns "we should test more" into a typed gate that cannot be silently
eroded; `covermode=atomic` is the only mode whose counters are correct under the
mandatory `-race` ([TEST-02](#dimension-testing-and-quality-test)); 80% is the fleet
baseline — packages may raise their own floor, never lower it. Composes with
[TEST-08](#dimension-testing-and-quality-test).
*Enforcement:* `forge tool check --language go` computes the coverage percentage
from the profile and exits non-zero below the declared floor (typed Rust comparison,
not `awk`/`bc`); CI publishes the profile; the gate shares one profile build with
[TEST-02](#dimension-testing-and-quality-test).
*Demonstrated by:* the example declares `coverage_floor = 80` and the `check-all`
run reports e.g. `coverage: 91.3% (floor 80%) OK`; dropping a tested branch makes CI
go red.

**TEST-04** — Any package that EMITS deterministic serialized output — a code
generator, a config renderer (shikumi-go round-trips), a job-plan/DAG dump
(shigoto-go), a GitHub Actions summary (pleme-actions-shared-go), a log-line format
(logging-go) — MUST be covered by GOLDEN-FILE tests: the emitted bytes are compared
against a committed fixture under `testdata/*.golden`, regenerated only via an
explicit `-update` flag (`var update = flag.Bool("update", false, ...)`).
*Why:* generators are the highest-leverage correctness surface (one bug fans out to
every consumer); a golden file makes the EXACT output the typed contract and any
drift a reviewable diff in the PR — the literal boundary of communication; the
`-update` flag keeps regeneration deliberate. Composes with
[CFG-13](#dimension-configuration-cfg)/[JOB-13](#dimension-concurrency-and-jobs-job).
*Enforcement:* `forge tool check --language go` runs golden tests WITHOUT `-update`
(a stale golden fails); a lint asserts `testdata/*.golden` is committed (not
gitignored); golden tests run under the same `-race` invocation; drift surfaces as a
unified diff.
*Demonstrated by:* the generator package has `testdata/render.golden` and a
`TestRender_Golden` doing
`if *update { os.WriteFile(golden, got, 0o644) }; want, _ := os.ReadFile(golden); if !bytes.Equal(got, want){ t.Errorf(...) }`.

**TEST-05** — Every parser, decoder, or untrusted-input boundary ships a Go FUZZ
target (`func FuzzX(f *testing.F)` with `f.Add(seed)` corpus +
`f.Fuzz(func(t *testing.T, in []byte){...})`). The fuzz target MUST assert an
invariant (no panic, round-trip equality, or idempotence), not merely "does not
crash". The seed corpus lives in `testdata/fuzz/FuzzX/` and is committed.
*Why:* shikumi-go (config parsing), todoku-go (HTTP response decoding), errors-go
(error (de)serialization) all consume bytes whose shape they do not control;
fuzzing is the only way to discover the input that violates a typed invariant;
asserting an invariant (not just absence of panic) makes the fuzzer a property
checker.
*Enforcement:* CI runs `go test -run=^$ -fuzz=FuzzX -fuzztime=30s ./...` per fuzz
target in a dedicated failure-blocking stage driven by `forge tool check --language
go`; any new crasher is written to `testdata/fuzz/` and fails the build; a lint
requires a `Fuzz*` target for packages importing `encoding/*` or defining
`Parse*`/`Decode*`.
*Demonstrated by:* the config package has `FuzzParse` with
`f.Add([]byte("key: val\n"))` and asserts `parse(in)` never panics AND
`marshal(parse(in)) == canonical(in)` for valid inputs; the committed
`testdata/fuzz/FuzzParse/` corpus is shown.

**TEST-06** — `go vet ./...` and `staticcheck ./...` MUST pass with ZERO findings.
No `//nolint`-style blanket suppression; a genuinely-justified single-line
suppression uses `//lint:ignore <check> <reason>` with a reason string, and a PR
introducing one requires reviewer sign-off.
*Why:* `vet` + `staticcheck` catch the defect classes that compile but mislead
readers (printf mismatches, lost errors, impossible type assertions) — exactly the
gaps that make a repo un-navigable; requiring a reason on every suppression keeps
the gate gapless.
*Enforcement:* `forge tool check --language go` runs `go vet` then `staticcheck` as
ordered sub-checks (either non-empty output fails the gate); staticcheck is pinned
via the substrate Go devShell/toolchain (`devenv.nix mkGoDevShell`) so the version
is fleet-uniform; a custom analyzer rejects bare `//nolint` and any `//lint:ignore`
lacking a reason.
*Demonstrated by:* the example passes `go vet ./...` and `staticcheck ./...` cleanly
and contains exactly zero suppressions.

**TEST-07** — All Go source MUST be `gofumpt`-formatted (the stricter superset of
`gofmt`). CI runs `gofumpt -l .` and fails if the list is non-empty. `gofmt` alone
is insufficient — `gofumpt` is the fleet formatter of record.
*Why:* a single deterministic formatter removes all whitespace/style review noise
and makes diffs semantic-only (the cheapest standardization win); `gofumpt` over
`gofmt` because it additionally normalizes the constructs `gofmt` leaves ambiguous.
*Enforcement:* `forge tool check --language go` runs `gofumpt -l .` and fails on any
listed file; `gofumpt` ships in the substrate Go devShell
(`build/go/devenv.nix mkGoDevShell`, whose toolchain is `[ go gopls gotools delve
gofumpt staticcheck govulncheck forge caixa-validate ]` — `nix develop` gives you
the EXACT pinned toolchain CI uses, the navigator's entry point per the
[Day-one setup](#day-one-setup)) so local pre-commit and CI use the identical
binary; the format check runs before vet/staticcheck so contributors fix mechanical
issues first.
*Demonstrated by:* the example's `devShells.default` inherits `mkGoDevShell`,
`nix develop` puts `delve`/`gopls`/`forge`/`caixa-validate` on `PATH`, and its
`check-all` output shows an empty `gofumpt -l .` result.

**TEST-08** — TESTS GREEN IS AN FSM GATE. The release/promotion pipeline models the
testing checks as a `shigoto-go` Gate: the artifact's `JobPhase` cannot advance
Ready→Running→Succeeded (publish/tag) until a Gate backed by the full `check-all`
result (`-race` test pass AND coverage floor AND vet/staticcheck/gofumpt
zero-findings AND golden/fuzz pass) returns Pass. A failing or absent check yields
Wait (re-evaluated) or Skip (hard refusal) — never an automatic advance.
*Why:* this is the keystone that makes the dimension gapless — testing is not
advisory, it is a typed precondition encoded in the same FSM (shigoto-go phase.go/
gate.go) that governs every other pipeline step; there is no path to a published
artifact that bypasses green tests because the only transition into the publish
phase is guarded by the Gate. This Gate is the per-repo `Checked` predecessor of the
[four Delivery FSMs](#delivery-fsm-type-system). Composes with
[JOB-11](#dimension-concurrency-and-jobs-job)/[JOB-12](#dimension-concurrency-and-jobs-job).
*Enforcement:* the release flake's `release`/`bump` apps
(`workspace-release-flake.nix`, `library-flake.nix`) wire `forge tool release` to
evaluate a `shigoto.Gate` (via `CheckAll`) whose `Check` returns `(true,nil)` only
when `forge tool check --language go` exited 0; a non-zero check makes
`AllUpstreamsTerminal`-style gating hold the publish Job in `Gated`; the Gate is
PURE (reads the recorded check receipt, not live IO).
*Demonstrated by:* the release wiring constructs
`shigoto.GateFunc(func(ctx)(bool,error){ return checkReceipt.AllGreen(), nil })`
fed to `shigoto.CheckAll`; attempting `nix run .#release` with a red `check-all`
leaves the publish Job in `Gated`/`Skipped` and tags nothing.

**TEST-09** — NO NETWORK in unit tests. A unit test MUST NOT open a socket to any
host other than loopback. External HTTP/gRPC/DB dependencies are exercised against
an in-process `net/http/httptest.Server`, a fake injected via an interface (an
`http.Client`/`RoundTripper` seam), or a local listener — never a real endpoint.
Any test that genuinely needs the network is build-tagged `//go:build integration`
and excluded from the default `go test`.
*Why:* network in unit tests makes them flaky, slow, and non-hermetic — they fail in
the Nix sandbox (no network) and in offline CI, breaking the FSM gate
([TEST-08](#dimension-testing-and-quality-test)) for unrelated reasons; hermetic
tests are a precondition for reproducible builds, the substrate's core promise.
Composes with [NET-01](#dimension-networking-net)/[SEC-01](#dimension-security-and-supply-chain-sec).
*Enforcement:* tests run inside the Nix build sandbox (`buildGoModule`) which has NO
network by construction (a dialing unit test simply fails); a custom analyzer in
`forge tool check --language go` flags `http.Get`/`net.Dial` with a non-loopback
literal in `_test.go` outside the `integration` tag; `integration`-tagged tests run
in a separate, network-permitted CI stage NOT part of the publish Gate.
*Demonstrated by:* `todoku-go/client_test.go` is the reference — every HTTP test
stands up `httptest.NewServer(http.HandlerFunc(...))` and points the client at
`srv.URL`, injecting a custom `&http.Client{Timeout: 7*time.Second}` rather than
reaching the real API; the example mirrors this httptest seam.

**TEST-10** — Tests MUST use `t.Parallel()` for any case with no shared mutable
state, and MUST capture loop variables correctly (Go 1.22+ per-iteration semantics
are assumed since the fleet toolchain is pinned ≥1.25). Time, randomness, and IDs
are injected (a `clock`/`now func() time.Time`, a seeded `*rand.Rand`, an ID
factory) — never read from the ambient `time.Now()`/global rand inside the unit
under test's test path.
*Why:* parallel tests surface latent races (compounding
[TEST-02](#dimension-testing-and-quality-test)'s `-race`) and keep the suite fast so
the FSM gate ([TEST-08](#dimension-testing-and-quality-test)) stays cheap; injecting
time/rand/IDs makes assertions deterministic — the precondition for golden files
([TEST-04](#dimension-testing-and-quality-test)) and a stable coverage number
([TEST-03](#dimension-testing-and-quality-test)). Composes with
[TEST-01](#dimension-testing-and-quality-test).
*Enforcement:* `forge tool check --language go` runs with `-race`
([TEST-02](#dimension-testing-and-quality-test)) so a non-parallel-safe test marked
`t.Parallel()` fails loudly; a `staticcheck`/custom-analyzer rule flags direct
`time.Now()`/`rand.` calls reachable from code under test lacking an injection seam;
the pinned `go 1.25.x` toolchain (`toolchain.nix`) guarantees per-iteration loop-var
semantics fleet-wide.
*Demonstrated by:* the example's table-driven tests call `t.Parallel()` inside each
`t.Run` for pure cases, and the production types accept a `Clock`/`now
func() time.Time` (mirroring lifecycle-go/shigoto-go) so the tests pass a fixed
clock and assert exact timestamps.

**TEST-11** — The mandated runtime libraries are consumed in tests, never
re-implemented. Assertions about errors use `errors-go` constructors/severity
(`errs.New`, `WithSeverity`, `errors.Is`/`As`) — not string-matching on
`err.Error()`. Tests needing a logger inject a `logging-go` test logger (captured,
level-filterable). Config-loading tests round-trip through `shikumi-go`. CLI tests
drive `cli-go`'s `App`/validators. This is a hard reuse rule: a test helper that
duplicates a runtime-lib capability is rejected.
*Why:* re-implementing error/log/config/CLI plumbing in test code is the duplication
the PRIME DIRECTIVE forbids, and string-matching on error text is brittle (it breaks
on message rewording while the typed contract is unchanged); consuming the libs in
tests also continuously validates the libs' own surfaces — the libraries dogfood
themselves. Composes with [ERR-09](#dimension-errors-err)/[OBS-01](#dimension-observability-obs)/
[CFG-02](#dimension-configuration-cfg).
*Enforcement:* a custom analyzer in `forge tool check --language go` flags
`strings.Contains(err.Error(), ...)` in `_test.go` (must use `errors.Is`/`As`
against an errors-go sentinel) and ad-hoc `log`/`fmt.Fprintf(os.Stderr,...)` capture
helpers (must use logging-go's test logger); code review rejects bespoke config/CLI
parsers in test helpers.
*Demonstrated by:* the example's error tests assert `errs.Is(got, ErrNotFound)` and
`var e *errs.Error; errs.As(got, &e); want e.Severity == SeverityWarning` (the shape
in `errors-go/errors_test.go`), inject logging-go's capturing logger, and load
fixtures through shikumi-go rather than a hand-rolled YAML reader.

**TEST-12** — Every test file declares the EXTERNAL test package (`package foo_test`,
not `package foo`), exercising the unit through its exported API only. White-box
tests (internal `package foo`) are permitted ONLY for genuinely unexported
invariants and MUST live in a separate `*_internal_test.go` file with a top-of-file
comment justifying the white-box access.
*Why:* black-box `_test` packages prove the EXPORTED contract — the only surface a
downstream consumer can use, the literal definition of a boundary of communication —
and prevent tests from depending on internals free to change; segregating the rare
white-box test makes the exception visible and auditable. Composes with
[DOC-02](#dimension-documentation-and-discoverability-doc)/[TEST-01](#dimension-testing-and-quality-test).
*Enforcement:* a custom analyzer in `forge tool check --language go` requires
`*_test.go` files (other than `*_internal_test.go`) to declare `package <pkg>_test`;
an internal-package test file not named `*_internal_test.go` fails the gate, and an
`*_internal_test.go` lacking the justification comment fails; runs in the same
`check-all` pass as vet/staticcheck.
*Demonstrated by:* `errors-go/errors_test.go` opens with `package errors_test` and
imports the lib as `errs "github.com/pleme-io/errors-go"`, testing only exported
symbols; the example follows this for all standard tests, with a single
`parse_internal_test.go` (`package config`) carrying a justification comment.

---

## Dimension: Security and Supply Chain (SEC)

**SEC-01** — Every Go binary the standard releases MUST be built statically with
`CGO_ENABLED=0` (no glibc/musl linkage) UNLESS the FIPS profile is active
([SEC-02](#dimension-security-and-supply-chain-sec)). The build MUST go through a
substrate Go builder — `mkGoTool` (`lib/build/go/tool.nix`), the service binary
builder in `lib/build/go/service-flake.nix`, or `mkGoServiceImage` in
`lib/build/go/docker.nix`. Hand-rolled `go build` outside a substrate-emitted flake
is forbidden. ldflags MUST include `-s -w` (strip) plus `-X` version injection via
`versionLdflags` so the binary self-reports its version + commit (consumed by
`pleme-actions-shared-go` summary output and `cli-go` version subcommand).

> **Note on `-race` vs `CGO_ENABLED=0` (resolving an overlap).**
> [TEST-02](#dimension-testing-and-quality-test) requires `CGO_ENABLED=1` (the race
> detector needs cgo) while SEC-01 requires `CGO_ENABLED=0` for release artifacts.
> These apply to **different build stages**: the *test/check* derivation runs with
> cgo enabled so `-race` works; the *release/image* derivation builds the static
> artifact with cgo disabled. The substrate `check-all` app and the
> `tool.nix`/`service-flake.nix` release path set the flag independently — there is
> no single build that must satisfy both.

*Why:* a static, hermetic, reproducible binary is the only artifact that can be
content-addressed by Nix, scanned deterministically
([SEC-05](#dimension-security-and-supply-chain-sec)), and attested without scanner
heuristics ([SEC-04](#dimension-security-and-supply-chain-sec)); CGO drags in a
dynamic libc that breaks distroless ([SEC-07](#dimension-security-and-supply-chain-sec)),
defeats reproducibility, and widens the CVE surface; version self-reporting closes
the "what is actually deployed" gap. Composes with [LAYOUT-06](#dimension-repo-layout-and-module-layout)/
[CLI-04](#dimension-cli-ux-cli)/[VER-04](#dimension-versioning-and-compatibility-ver).
*Enforcement:* `service-flake.nix` sets `env.CGO_ENABLED="0"` for the release build
and `docker.nix mkGoServiceImage` sets `CGO_ENABLED = 0`; `mkGoTool` asserts
`versionLdflags`/`ldflags` types via `lib/types/assertions.nix` at Nix eval; a
`nix build .#default` producing a dynamically-linked binary fails the
library-check-style gate; a non-substrate `go build` in any workflow YAML is
rejected by the NO-shell lint (only `tatara-script`-backed actions are permitted).
*Demonstrated by:* the canonical service flake imports `service-flake.nix` and sets
`subPackages`, `vendorHash`, and
`versionLdflags = { "main.version" = version; "main.commit" = self.rev; }`;
`nix build .#default` yields a stripped static ELF whose `--version` (via cli-go)
prints the injected commit.

**SEC-02** — A FIPS-compliant variant MUST be available behind a single typed flag
`fipsBuild = true` on the substrate Go service/image flake. When set, the builder
MUST inject `GOEXPERIMENT = "boringcrypto"` AND `GOFIPS = "1"` (defense-in-depth:
toolchain boringcrypto + runtime FIPS-mode ldflag). FIPS builds MUST NOT silently
fall back to standard crypto — a FIPS image that boots without boringcrypto linked
is a release-blocking error. Crypto in application code MUST use the Go stdlib
`crypto/*` packages (which boringcrypto intercepts); rolling a non-stdlib crypto
primitive in a FIPS-targeted binary is forbidden.
*Why:* FedRAMP-High and FIPS-140 mandate validated crypto modules; boringcrypto at
the toolchain level + `GOFIPS=1` at runtime is the only Go-native path; a single
typed knob keeps it gapless and prevents a fips/non-fips build diverging in ldflags;
forcing stdlib crypto guarantees boringcrypto actually intercepts the calls.
Composes with [SEC-07](#dimension-security-and-supply-chain-sec)/[SEC-08](#dimension-security-and-supply-chain-sec).
*Enforcement:* `service-flake.nix` exposes `fipsBuild ? false` and conditionally
merges `{ GOEXPERIMENT = "boringcrypto"; GOFIPS = "1"; }` into the `buildGoModule`
`env`; a post-build assertion runs `go tool nm <binary> | grep
_Cfunc__goboringcrypto_` (or `go version -m`) and fails if boringcrypto symbols are
absent when `fipsBuild=true`; a FIPS image carries the OCI label
`org.pleme.fips=true` ([SEC-08](#dimension-security-and-supply-chain-sec)) which
`image-scan` verifies.
*Demonstrated by:* the example ships a standard image
(`packages.<sys>.dockerImage:amd64`) and a FIPS profile built with
`fipsBuild = true`; the FIPS image's `go version -m /app/<bin>` reports
`GOEXPERIMENT=boringcrypto` and the symbol probe passes in CI.

**SEC-03** — Container images MUST run as a non-root numeric UID (default
`65534:65534`, or an operator-chosen `numericUid > 10000`) with `User` set in the
OCI config, a non-root `WorkingDir`, and `USER`/`HOME` env defaults so Go's
`os/user.Current()` does not panic on a UID absent from /etc/passwd. Root (`0`) or
unset `User` is a release-blocking error. The image MUST set a
read-only-root-filesystem-compatible layout (no writes outside an explicit writable
volume).
*Why:* NIST AC-6 / CIS Docker Benchmark 4.1 require containers not run as root; a
numeric UID > 10000 avoids host UID collisions and needs no /etc/passwd entry (the
distroless case, [SEC-07](#dimension-security-and-supply-chain-sec)); the USER/HOME
defaults close a known Go startup-panic gap in numeric-UID distroless images.
Composes with [SEC-07](#dimension-security-and-supply-chain-sec).
*Enforcement:* `docker.nix mkGoDockerImage` defaults `user = "65534:65534"`, asserts
`check.str "user" user`, and injects `USER=app`/`HOME=${workDir}` into Env; the
`image-scan` action (`lib/release/patterns.nix security.image-scan`, trivy-backed)
fails on a `config.User` of `""`/`"0"`/`"root"`; the chart's PodSecurityStandard
`restricted` baseline rejects root at deploy time.
*Demonstrated by:* the image's `docker inspect` shows `"User": "65534:65534"`,
`"WorkingDir": "/app"`, and Env containing `USER=app`+`HOME=/app`; the runtime pod
runs under PodSecurityStandard `restricted` with `runAsNonRoot: true` and
`readOnlyRootFilesystem: true`.

**SEC-04** — Every released OCI image MUST have an SBOM in `spdx-json` format
generated and attached as a cosign attestation co-located in the same registry as
the image (NOT merely an artifact). SBOM generation MUST be reproducible — prefer
the Nix dep-graph walk in `lib/security/sbom-emit.nix`, falling back to
`syft docker-archive:<tarball>` only for upstream-fetched bytes outside a
derivation. The attestation predicate type MUST be `spdx`. A pushed image with no
attached SBOM attestation is a release-blocking error.
*Why:* SR-3 (supply-chain protection), CM-8 (component inventory), SI-7 (software
integrity); spdx-json is the org-mandated lingua franca; a registry-co-located
cosign attestation (verifiable via the same Fulcio/Rekor path as the signature)
means anyone pulling the image can mechanically enumerate its components. Composes
with [SEC-05](#dimension-security-and-supply-chain-sec)/[SEC-06](#dimension-security-and-supply-chain-sec)/
[FSM-IMAGE](#image-delivery-fsm-image).
*Enforcement:* `service-flake.nix` exposes `sbom ? false` + `sbomFormat ?
"spdx-json"`; setting `sbom = true` wires `sbom-emit.nix mkSbomAttestApp` into the
release app; the `sbom-generate` action (`security.sbom-generate`, syft-backed,
tatara-lisp) runs in CI; in a shigoto-go release DAG the `push-image` Job is
downstream of an `sbom-attest` Job and `AllUpstreamsTerminal` blocks the push until
the attest Job reaches `Succeeded`.
*Demonstrated by:* the example sets `sbom = true; sbomFormat = "spdx-json";`; after
`nix run .#release`,
`cosign verify-attestation --type spdx ghcr.io/pleme-io/<svc>@<digest>` returns a
valid SPDX 2.3 predicate enumerating every store-path component.

**SEC-05** — Every release MUST pass a CVE gate (trivy default, grype permitted) run
against the built image TARBALL BEFORE the push to the registry, with a typed
`failOn` severity threshold defaulting to `["CRITICAL","HIGH"]` (the floor is
`HIGH` fleet-wide — it MUST NOT be loosened below `HIGH`; this is the single
authoritative default, matching the FSM-IMAGE `G_cve_under_threshold` gate
`failOn=HIGH`). The gate MUST run `--ignore-unfixed` and
accept only a checked-in `.trivyignore` allowlist — inline severity downgrades are
forbidden, and every allowlisted CVE MUST carry an expiry comment. A finding at or
above the threshold is a release-blocking error; the image never lands in GHCR.
*Why:* RA-5 (vulnerability scanning), SI-7; gating pre-push (not post-push) means a
vulnerable image is never published, so there is no window where a bad digest is
signable/deployable; a checked-in, expiring allowlist makes every accepted risk
auditable and time-boxed. Composes with [SEC-04](#dimension-security-and-supply-chain-sec)/
[SEC-09](#dimension-security-and-supply-chain-sec)/[FSM-IMAGE](#image-delivery-fsm-image).
*Enforcement:* `lib/security/cve-gate.nix mkCveGateApp` runs
`trivy image --input <tarball> --severity <failOn> --exit-code 1 --no-progress
--ignore-unfixed`; `service-flake.nix` `cveGate ? null` wires it as a release-app
precondition; the `image-scan` action double-covers in CI; the shigoto-go release
DAG places `cve-scan` upstream of `push-image` (a non-zero exit moves the Job to
`Failed`→`Deadlettered` and `AllUpstreamsTerminal` keeps `push-image` `Gated`).
*Demonstrated by:* the flake sets
`cveGate = { scanner = "trivy"; failOn = ["CRITICAL" "HIGH"]; ignoreFile = ./.trivyignore; };`;
CI shows `trivy image --input result --severity CRITICAL,HIGH --exit-code 1`
returning 0, and an injected CRITICAL CVE flips the release Job to Deadlettered and
blocks the push.

**SEC-06** — Every released OCI image MUST be cosign keyless-signed (Sigstore Fulcio
short-lived cert from the CI OIDC identity + Rekor transparency log) AFTER push,
addressed BY DIGEST (`<ref>@sha256:...`), never by a floating tag. Long-lived
signing keys are forbidden. Consumers/admission MUST verify with a pinned
`--certificate-identity-regexp` AND `--certificate-oidc-issuer` (the GitHub Actions
OIDC issuer); an unverifiable or tag-addressed signature is a deploy-blocking error.
*Why:* SR-11 (component authenticity), SI-7; keyless signing removes the key-
rotation/key-leak failure mode entirely and Rekor gives a public tamper-evident
proof of who signed what when; digest-addressing prevents a signed-tag/pushed-
different-image substitution; pinned identity+issuer on verify prevents a
valid-but-attacker signature from passing. Composes with
[SEC-04](#dimension-security-and-supply-chain-sec)/[SEC-12](#dimension-security-and-supply-chain-sec)/
[FSM-IMAGE](#image-delivery-fsm-image).
*Enforcement:* `lib/security/cosign-sign.nix mkCosignSignApp` (keyless default,
ambient GitHub OIDC) signs; `mkCosignVerifyApp` enforces
`--certificate-identity-regexp`+`--certificate-oidc-issuer`; `service-flake.nix`
`sign ? false`/`signKeyless ? true` wires signing into the release app; the
`provenance-attest` action runs in CI; the chart-level Kyverno `verifyImages` policy
and the sekiban admission webhook gate K8s deploys.
*Demonstrated by:* the service sets `sign = true; signKeyless = true;`; post-release
`cosign verify --certificate-identity-regexp 'https://github.com/pleme-io/<svc>/.github/workflows/.*' --certificate-oidc-issuer https://token.actions.githubusercontent.com ghcr.io/pleme-io/<svc>@<digest>`
succeeds, and the same digest+identity appear in the chart's Kyverno rule.

**SEC-07** — FedRAMP-High / least-functionality (CM-7 / SR-3) image profiles MUST
use the distroless base: `cacert` + `tini` (PID 1) only — NO busybox, NO shell, NO
coreutils. The runtime image MUST contain exactly the static Go binary, the CA
bundle, and tini. A shell, package manager, curl/wget, or any interpreter in a
production image is a release-blocking error. The distroless knob MUST be a single
typed boolean.
*Why:* CM-7 least functionality / SR-3 — an attacker who achieves RCE in a
distroless container has no `sh`, no `curl`, no coreutils to pivot with, so the blast
radius collapses to whatever the single Go binary can do; tini reaps zombies cheaply
and cacert is the only thing needed for outbound TLS. Composes with
[SEC-01](#dimension-security-and-supply-chain-sec)/[SEC-03](#dimension-security-and-supply-chain-sec)/
[SEC-11](#dimension-security-and-supply-chain-sec).
*Enforcement:* `lib/build/go/distroless.nix mkDistrolessBase` returns
`[cacert] ++ [tini]` (no busybox); `docker.nix mkGoDockerImage` `distroless ? false`
swaps `baseContents` from `[cacert busybox]` to the distroless set when true;
`service-flake.nix`/`tool-image-flake.nix` forward the `distroless`+`tini` knobs;
the `image-scan` action enumerates the image filesystem and fails if `/bin/sh`,
`/bin/busybox`, or a package-manager binary is present in a distroless-flagged
profile.
*Demonstrated by:* the FedRAMP profile sets `distroless = true; tini = true;`;
`docker run --rm --entrypoint /bin/sh <image>` fails with "no such file", and the
manifest layers contain only the binary, ca-bundle.crt, and tini.

**SEC-08** — Every released image MUST carry the full standard OCI annotation set:
`org.opencontainers.image.source`, `.url`, `.documentation` (all pointing at the
GitHub repo), `.created` (deterministic ISO timestamp, default
`1970-01-01T00:00:01Z` for reproducibility — overridden to the build timestamp only
in attested provenance), `.revision` (git SHA), `.version`, and
`.title`/`.description`. Images MUST be layered (`buildLayeredImage`) for
cache-efficient, deduplicated distribution. Missing source/revision annotations is a
release-blocking error.
*Why:* CM-8 / supply-chain transparency — the OCI annotations are the machine-
readable backlink from a pulled image to its exact source commit and docs (the
boundary of communication for anyone who finds the image in a registry without
context); reproducible `created` keeps the digest stable across rebuilds of the same
inputs. Composes with [SEC-04](#dimension-security-and-supply-chain-sec)/[SEC-12](#dimension-security-and-supply-chain-sec).
*Enforcement:* `docker.nix mkGoDockerImage` builds `standardLabels` via
`lib/util/docker-helpers.nix mkStandardLabels` (auto-injects
`org.opencontainers.image.{source,url,documentation}` from `fleetSourceUrl` defaulted
to `https://github.com/pleme-io/<name>` and `.created`, merging operator `labels`),
emitting via `dockerTools.buildLayeredImage`; `image-scan`/`skopeo inspect` asserts
the required annotation keys are non-empty.
*Demonstrated by:* the image's `skopeo inspect docker-archive:result` shows
`org.opencontainers.image.source = https://github.com/pleme-io/<svc>`, a populated
`.revision`, and `.created` matching the reproducible default; rebuilding from the
same inputs yields the identical digest.

**SEC-09** — Every Go repo MUST run `govulncheck` (the official Go vuln database,
call-graph-aware) against the module on every PR and on a nightly schedule, in
ADDITION to the polymorphic `security-audit` action. The gate MUST fail on any
vulnerability whose vulnerable symbol is reachable from the binary's call graph (not
merely present in go.sum). Findings MUST be remediated by dependency bump
([SEC-10](#dimension-security-and-supply-chain-sec)), not suppressed, unless an
expiring, justified entry is added to the checked-in vuln-allowlist.
*Why:* RA-5 / SI-2 — trivy/grype ([SEC-05](#dimension-security-and-supply-chain-sec))
scan the built image's OS+lang packages but are not Go-call-graph-aware; govulncheck
is the only tool that distinguishes a vulnerable dependency that is actually CALLED
from one merely linked, eliminating false-positive churn while catching real
reachable CVEs. Composes with [SEC-05](#dimension-security-and-supply-chain-sec)/
[SEC-10](#dimension-security-and-supply-chain-sec)/[FSM-IMAGE](#image-delivery-fsm-image).
*Enforcement:* a `govulncheck ./...` step runs via a `tatara-script`-backed action
(NO raw shell) on PR + nightly cron; the org `security-audit` action
(`security.security-audit`, configurable fail-on-severity + ignore-list) provides
the polymorphic dep-vuln layer; the govulncheck binary is provisioned by the
substrate Go devShell so the version is pinned fleet-wide; in the release DAG the
`govulncheck` Job is upstream of `build-image` (a reachable-vuln finding deadletters
it and `AllUpstreamsTerminal` blocks the build).
*Demonstrated by:* the repo's CI shows a passing `govulncheck ./...`; a fixture
importing a known-vulnerable `golang.org/x/...` symbol flips the Job to Deadlettered
and blocks the build, while an unreachable vulnerable import passes cleanly.

**SEC-10** — Dependency hygiene MUST be automated: a checked-in `go.mod`+`go.sum`
with the dependency closure pinned and content-addressed via the substrate
`vendorHash`; a scheduled `dependency-update` action that refreshes the lockfile and
opens an auto-PR; and a `go.mod` `go` directive pinned to the MINOR version only
(e.g. `go 1.25`), NEVER a patch ahead of the substrate goToolchain. Floating/
unpinned dependency refs, an uncommitted/stale `go.sum`, or a go.mod ahead of the
toolchain are build-blocking errors.

> See the [vendoring note under LAYOUT-12](#dimension-repo-layout-and-module-layout)
> for why the GSDS uses proxy + `go.sum` + `vendorHash` rather than a committed
> `vendor/` tree — the hermetic/reproducible property this rule requires is
> delivered by that triple plus the network-less Nix sandbox.

*Why:* SR-3 / CM-2 — a content-addressed pinned closure + a minor-pinned go
directive makes every build hermetic and reproducible (no network at build time, no
toolchain auto-download surprise); automated lockfile-refresh PRs keep deps current
so the CVE/govulncheck gates ([SEC-05](#dimension-security-and-supply-chain-sec)/
[SEC-09](#dimension-security-and-supply-chain-sec)) act on a moving-but-controlled
baseline. Composes with [LAYOUT-02](#dimension-repo-layout-and-module-layout)/
[LAYOUT-10](#dimension-repo-layout-and-module-layout)/[LAYOUT-12](#dimension-repo-layout-and-module-layout)/
[VER-10](#dimension-versioning-and-compatibility-ver).
*Enforcement:* `lib/build/go/tool.nix goVersionAssert` reads the consuming `go.mod`
at Nix eval and `throw`s if `compareVersions req tool > 0` (go.mod ahead of
`pkgs.go.version`); `buildGoModule`'s `vendorHash` pins the dependency closure
content-addressed; the `dependency-update` action (`sdlc.dependency-update`,
polymorphic) runs on cron opening an auto-PR; a stale-`go.sum`/closure check fails if
the resolved closure diverges from the pin.
*Demonstrated by:* the repo declares `go 1.25` in go.mod, commits `go.sum`, sets
`vendorHash` in its flake, and has a nightly `dependency-update` workflow; bumping
go.mod to a patch ahead of the toolchain makes `nix build` fail at eval with the
substrate goVersionAssert message.

**SEC-11** — Secret scanning MUST run on every PR and pre-release via the
gitleaks-backed `secrets-scan` action with a fail-on-found gate. No plaintext secret
may ever enter git, the Nix store (`/nix/store` is world-readable), build-time env
vars, or an OCI image layer. Runtime secrets MUST be delivered via mounted files or
the Akeyless SDK fetched through `todoku-go` — never baked into the binary, the
image, or `versionLdflags`. A detected secret is a merge-blocking AND
release-blocking error.
*Why:* IA-5 / SI-7 — a secret committed to git or embedded in a world-readable Nix
store / pullable image layer is permanently leaked; gitleaks on every PR catches it
before merge; routing all runtime secret access through todoku-go centralizes auth +
retry + audit and guarantees the secret lives only in process memory, never on disk
in the artifact. Composes with [CFG-07](#dimension-configuration-cfg)/[CFG-08](#dimension-configuration-cfg)/
[CFG-09](#dimension-configuration-cfg)/[NET-06](#dimension-networking-net).
*Enforcement:* the `secrets-scan` action (`quality.secrets-scan`, gitleaks-driven,
tatara-lisp) runs on PR + pre-release with fail-on-found; secret fetches go through
`todoku-go` (`auth.go`/`client.go`/`retry.go`) — a direct `os.Getenv` of a credential
or an inline literal credential is flagged by lint; the distroless posture
([SEC-07](#dimension-security-and-supply-chain-sec)) + reproducible build
([SEC-01](#dimension-security-and-supply-chain-sec)) ensure no secret can hide in a
shell-readable layer.
*Demonstrated by:* the repo's CI runs `secrets-scan` green; the service fetches its
Akeyless token via todoku-go's authenticated client at runtime, and a planted fake
AWS key in a test commit flips the scan Job to Skipped/Failed and blocks the merge.

**SEC-12** — Every released artifact (image, binary, chart, SBOM) MUST be wired into
the tameshi provenance/attestation chain: a BLAKE3 Merkle tree over the deployment
chain, with the sekiban admission webhook gating K8s deploys on a valid signature
and inshou gating Nix rebuilds on a valid attestation chain. The release pipeline
MUST emit a provenance attestation (SLSA-style: builder identity, source digest,
materials) via the `provenance-attest` action. Any `--skip-verification` bypass MUST
be logged and audited; there is NO silent bypass.
*Why:* SR-11 / SI-7 / CM-2 — cosign ([SEC-06](#dimension-security-and-supply-chain-sec))
proves WHO signed; tameshi+provenance prove HOW the artifact was built and from WHAT
inputs, giving an unforgeable build-integrity chain from source commit to running
pod; sekiban/inshou make that chain enforcing (deploy/rebuild fail-closed on a
broken chain), and the audited-bypass rule means even emergencies leave a trail.
Composes with [SEC-04](#dimension-security-and-supply-chain-sec)/[SEC-06](#dimension-security-and-supply-chain-sec)/
[FSM-IMAGE](#image-delivery-fsm-image).
*Enforcement:* the `provenance-attest` action (`security.provenance-attest`) emits
the attestation alongside the cosign signature; tameshi computes the BLAKE3 Merkle
tree; sekiban rejects unsigned/unattested images at K8s admission and inshou blocks
a Nix rebuild lacking a valid attestation chain; a shigoto-go release DAG sequences
`sign`→`attest`→`provenance`→`publish`, each gated by `AllUpstreamsTerminal` so
publish only fires when the full chain reaches `Succeeded`; the bypass flag is logged
via `logging-go` and surfaced via `pleme-actions-shared-go` summary output.
*Demonstrated by:* the service's release emits a cosign-verifiable provenance
attestation referencing the source digest + builder; deploying the chart to a
sekiban-gated cluster succeeds for the attested digest and is rejected for an
unattested one, and any `--skip-verification` invocation writes an audited
`logging-go` warn record visible in the action summary.

**SEC-13** — The image security pipeline ([SEC-04](#dimension-security-and-supply-chain-sec)
SBOM, [SEC-05](#dimension-security-and-supply-chain-sec) CVE,
[SEC-06](#dimension-security-and-supply-chain-sec) sign,
[SEC-12](#dimension-security-and-supply-chain-sec) provenance) MUST be WIRED INTO
the release app as a typed `shigoto-go` DAG, not merely accepted as flake args.
When `sign`/`sbom`/`cveGate`/provenance knobs are set, the generated
`releaseApp.program` MUST contain the corresponding cosign/syft/trivy/provenance
steps in DAG order (`build → cve-scan → push → sign → sbom-attest → provenance`,
see [SEC-13c](#dimension-security-and-supply-chain-sec) for the corrected ordering);
a substrate-level invariant test asserts they are present, so a repo that sets
`sign = true` can never produce an unsigned push. The `readinessTimeout`
(FSM-IMAGE) is a typed, lower-bounded `shikumi-go` Duration (default `300s`).
*Why:* `service-flake.nix` accepted `sign`/`sbom`/`cveGate`/`fipsBuild` args but
never threaded them into the release app (which only ran `forge image-release`'s
push) — so a repo declaring the security knobs got a green build and an unsigned,
un-SBOM'd, unscanned push. FSM-IMAGE was a type sketch, not a gate on any real
release. Wiring the DAG and a presence invariant makes "by construction, not by
convention" true. Composes with [SEC-04](#dimension-security-and-supply-chain-sec)/
[SEC-05](#dimension-security-and-supply-chain-sec)/[SEC-06](#dimension-security-and-supply-chain-sec)/
[SEC-12](#dimension-security-and-supply-chain-sec)/[FSM-IMAGE](#image-delivery-fsm-image).
*Enforcement:* `mkGoServiceReleaseCheck` asserts the generated `releaseApp.program`
contains the cosign/syft/trivy/provenance steps in DAG order whenever the knob is
set; the release app IS the literal shigoto DAG (not a bare push); `nix flake check`
asserts `readinessTimeout` present and ≥ its lower bound.
*Demonstrated by:* the example sets `sign = true; sbom = true; cveGate = {...};` and
`mkGoServiceReleaseCheck` shows the release app's DAG ordering; removing the sign
step from the rendered app fails the invariant test.

**SEC-13a** — Full SAST runs fleet-wide, not just the two timeout checks. `gosec
./...` (or the `golangci-lint gosec` linter) runs as a check derivation covering
its full ruleset — G101 (hardcoded credentials, complementing
[SEC-11](#dimension-security-and-supply-chain-sec)'s regex secret-scan with AST),
G401/G501-G505 (weak/blocklisted crypto MD5/SHA1/DES/RC4), G402
(`tls.Config{InsecureSkipVerify:true}`), G404 (`math/rand` for security), G302/G306
(file perms), G204 (command injection), and integer-overflow checks. The
TLS-floor + weak-crypto bans of [NET-14](#dimension-networking-net) are enforced
here too.
*Why:* `gosec` was invoked only for G112/G114 (server timeouts) — a FIPS-labeled
binary could call `crypto/md5` or set `InsecureSkipVerify` and nothing flagged it
([SEC-02](#dimension-security-and-supply-chain-sec) only checks boringcrypto symbol
PRESENCE, not weak-primitive USAGE). Zero SAST beyond two checks is a FedRAMP hole.
Composes with [SEC-02](#dimension-security-and-supply-chain-sec)/
[NET-11](#dimension-networking-net)/[NET-14](#dimension-networking-net).
*Enforcement:* `forge tool check --language go` runs full `gosec ./...` (pinned in
the devShell); the GSDS `gsds-net-tls` analyzer ([NET-14](#dimension-networking-net))
bans `InsecureSkipVerify`/weak crypto/`math/rand` in non-test crypto paths; the
FSM-IMAGE `ValidationGate`/`G_manifest_valid` requires a clean SAST record.
*Demonstrated by:* the example passes `gosec ./...` clean; a fixture with
`md5.New()` for an HMAC key or `InsecureSkipVerify: true` fails the gate.

**SEC-13b** — The substrate's OWN security/build/service library code obeys the
NO-shell prime directive. The signing/scan/SBOM/provenance/push steps MUST be
Rust binaries (extend `forge` with `forge image-{sign,scan,sbom,provenance,rescan}`
alongside `forge image-release`); a `pkgs.writeShellScript`/bash/zsh implementation
in `lib/security/**`, `lib/build/go/**`, or `lib/service/**` is forbidden and a
meta-lint over those trees fails the build.
*Why:* the security wrappers (`cosign-sign.nix`, `cve-gate.nix`, `sbom-emit.nix`,
`image-release.nix`) were multi-line bash — the least-typed, least-tested code in
the system, the opposite of what FedRAMP SR-11/SI-7 wants, and a direct violation
of the NO-shell rule the standard enforces on consumers ([SEC-01](#dimension-security-and-supply-chain-sec)/
[DOC-10](#dimension-documentation-and-discoverability-doc)). The enforcement layer
must not be the very shell glue the org bans. Composes with [SEC-01](#dimension-security-and-supply-chain-sec)/
[DOC-10](#dimension-documentation-and-discoverability-doc).
*Enforcement:* the [DOC-10](#dimension-documentation-and-discoverability-doc)
meta-lint is extended to scan `lib/security/**`/`lib/build/go/**`/`lib/service/**`
and fail on any `writeShellScript`/bash step; `forge image-*` subcommands replace
the shell wrappers.
*Demonstrated by:* `forge image-sign`/`image-scan`/`image-sbom`/`image-provenance`
are Rust; the meta-lint over `lib/security/**` is green with zero shell.

**SEC-13c** — FSM-IMAGE step ordering is CRYPTOGRAPHICALLY CORRECT: scan the local
tarball BEFORE push, then push, then sign and attest BY DIGEST. The order is
`Validated → ImageBuilt → CVEGated → Pushed → Signed → SBOMAttached →
ProvenanceAttested → Deployed → Verified`. Signing or SBOM-attesting BEFORE push is
forbidden (cosign attaches a `.sig`/`.att` to a PUSHED registry reference — you
cannot sign a not-yet-pushed image), and scanning AFTER sign is forbidden (a CVE
fail must not leave a valid Fulcio/Rekor signature for a known-bad digest in the
transparency log).
*Why:* the prior FSM-IMAGE ordered `Sign → SBOM → ScanCVE → Push`, which (1) signs
before push — impossible per `cosign-sign.nix`'s own "use after the image is
pushed", and (2) scans an already-signed image — so the CVE-fail path discards a
signature minted over a vulnerable digest. SEC-06 mandates signing AFTER push and
SEC-05 mandates scanning BEFORE push; the corrected order satisfies both. Composes
with [SEC-05](#dimension-security-and-supply-chain-sec)/[SEC-06](#dimension-security-and-supply-chain-sec)/
[FSM-IMAGE](#image-delivery-fsm-image).
*Enforcement:* FSM-IMAGE's transition table (rewritten below) enforces the order; a
property test asserts `Push` precedes `Sign`/`AttachSBOM` and `ScanCVE` precedes
`Push`; the substrate release-app DAG follows the same order.
*Demonstrated by:* the example's release scans the tarball, pushes, then cosign-signs
the pushed digest and attaches the SBOM/provenance to that digest; a CVE finding
stops the flow at `CVEGated` BEFORE any signature exists.

**SEC-14** — The runtime image is distroless BY DEFAULT and carries a restricted
Pod SecurityContext. `distroless` defaults to `true` for `kind ∈ {service, daemon}`
(an explicit `distroless = false` for those kinds is a release-blocking error — no
busybox/shell in a production image, [SEC-07](#dimension-security-and-supply-chain-sec)).
The chart MUST emit a Pod SecurityContext: `runAsNonRoot: true`,
`readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`,
`capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`, no
`privileged`/`hostPath`/`hostNetwork`/`hostPID`/added capabilities, and no
setuid/setgid bits on the binary.
*Why:* the default service image shipped busybox (a shell) unless a repo remembered
`distroless = true`, and no substrate code set a Pod SecurityContext — the
"PodSecurityStandard restricted rejects root" claim had no in-repo gate. CIS Docker
/ PodSecurity "restricted" is the FedRAMP AC-6/CM-7 baseline; making it the default
+ admission-gated closes the runtime-privilege hole. Composes with
[SEC-03](#dimension-security-and-supply-chain-sec)/[SEC-07](#dimension-security-and-supply-chain-sec)/
[FSM-IMAGE](#image-delivery-fsm-image).
*Enforcement:* `docker.nix`/`service-flake.nix` default `distroless = true` for
service/daemon kinds and make `distroless = false` a release-blocking error there;
`caixa-helm` emits the restricted SecurityContext; a Kyverno/sekiban admission
policy enforces it and FSM-IMAGE's `G_apply_accepted` evaluates that the admitted
object carries the restricted conjunct set (non-root, RO-root, dropped caps,
seccomp, no host namespaces); `image-scan` fails on setuid bits.
*Demonstrated by:* the example service image is distroless with no `/bin/sh`; its
chart sets the full restricted SecurityContext and a fixture removing
`readOnlyRootFilesystem` is rejected at admission and by `G_apply_accepted`.

**SEC-15** — The FIPS boringcrypto post-build probe is REAL and the CGO interaction
is resolved. When `fipsBuild = true`, an `installCheckPhase` runs
`go tool nm <binary> | grep _Cfunc__goboringcrypto_` (or `go version -m`) and FAILS
the build if boringcrypto symbols are absent — a FIPS-labeled binary that silently
linked standard crypto is impossible. The CGO collision is resolved explicitly:
boringcrypto requires `CGO_ENABLED=1` with the matching toolchain `-tags`, so the
FIPS profile overrides [SEC-01](#dimension-security-and-supply-chain-sec)'s
`CGO_ENABLED=0` for the FIPS build only (distroless then bundles the required libc
or uses the static-boringcrypto toolchain mode), and the standard build keeps
`CGO_ENABLED=0`.
*Why:* `fipsBuild` only flipped env vars; `doCheck = false` and there was no nm
probe, so a cross-compile that silently dropped boringcrypto produced a
`org.pleme.fips=true` binary using standard crypto — the exact silent fallback
SEC-02 forbids. And `CGO_ENABLED=0` (SEC-01) collides head-on with boringcrypto's
CGO requirement; the standard must resolve it the way it resolved `-race`. Composes
with [SEC-01](#dimension-security-and-supply-chain-sec)/[SEC-02](#dimension-security-and-supply-chain-sec).
*Enforcement:* the FIPS build's `installCheckPhase` runs the nm/`go version -m`
probe and fails on absent boringcrypto symbols; the FIPS profile sets
`CGO_ENABLED=1` + the boringcrypto `-tags` (overriding SEC-01 for that build only,
a documented overlap like `-race`); FSM-IMAGE's `G_image_hardened` includes a
`fips_verified` conjunct when `fipsBuild`.
*Demonstrated by:* the FIPS image's `go version -m /app/<bin>` reports
`GOEXPERIMENT=boringcrypto` and the nm probe passes; a cross-arch FIPS build that
fails to link boringcrypto fails the install check.

**SEC-16** — Released CLI/binary artifacts (FSM-RELEASE) get an SBOM, a CVE scan,
and a provenance attestation too — the SEC supply-chain rules are scoped to "every
released artifact (image OR binary)", not images only. A syft SBOM over each
cross-built binary + a govulncheck/trivy scan + an SLSA provenance attestation MUST
be attached to the GitHub Release; FSM-RELEASE gains `SBOMAttached`/`Scanned`/
`ProvenanceAttested` states ([FSM-RELEASE](#release-delivery-fsm-release)).
*Why:* the `cli`/`binary` kinds publish binaries to a GitHub Release + Homebrew and
those gates covered checksums + signature but never SBOM/CVE/provenance — a FedRAMP
consumer installing `widgetctl` via brew got a signed-but-uninventoried, unscanned
binary (CM-8/RA-5/SLSA hole). Composes with [SEC-04](#dimension-security-and-supply-chain-sec)/
[SEC-05](#dimension-security-and-supply-chain-sec)/[SEC-12](#dimension-security-and-supply-chain-sec)/
[FSM-RELEASE](#release-delivery-fsm-release).
*Enforcement:* the release app DAG for `cli`/`binary` runs `forge image-sbom`
(syft over the artifact) + a scan + `forge image-provenance` and attaches them to
the Release; FSM-RELEASE's `ChecksumGate`/`SignatureGate` are joined by
`SBOMGate`/`ScanGate`/`ProvenanceGate`; CI fails a Release lacking the SBOM/scan/
provenance assets.
*Demonstrated by:* `widgetctl`'s GitHub Release carries a `widgetctl.spdx.json`
SBOM, a clean scan record, and a cosign-verifiable SLSA provenance per artifact.

**SEC-17** — Base images and the build toolchain are DIGEST-PINNED and recorded.
`flake.lock` MUST pin every build input (the distroless/cacert/tini layers, the
`pkgs.go` toolchain) and `mkStandardLabels` MUST record the base-layer digest in an
OCI annotation (`org.pleme.base.digest`). The base image is pinned by digest, not a
floating tag.
*Why:* SR-3/CM-2 require the base layer + toolchain pinned by digest and
reproducible; SEC-10 pinned Go MODULE deps via `vendorHash` but the OCI base layer
and toolchain provenance were uncovered. Composes with [SEC-08](#dimension-security-and-supply-chain-sec)/
[SEC-10](#dimension-security-and-supply-chain-sec).
*Enforcement:* a `nix flake check` assertion fails if any build input is unpinned in
`flake.lock`; `mkStandardLabels` records `org.pleme.base.digest` and `image-scan`
asserts it non-empty; the FSM-IMAGE `G_image_hardened` reads the recorded digest.
*Demonstrated by:* the example's `skopeo inspect` shows `org.pleme.base.digest =
sha256:...` and rebuilding from the same `flake.lock` yields the identical image
digest.

**SEC-18** — Source-side supply-chain governance is a rule, not a convention.
The default branch MUST require: CODEOWNERS-enforced review + two-person approval
(SR-3/SA-11/AC-5 separation of duties), required SIGNED commits (not just a signed
tag — [FSM-RELEASE](#release-delivery-fsm-release)'s `TagOnDefaultBranch` is only
trustworthy if the branch requires review + signed commits), and branch protection.
CI tokens MUST be least-privilege: every emitted workflow declares an explicit
minimal `permissions:` block (`id-token: write` only where signing happens,
`contents: read` elsewhere); a broad default `GITHUB_TOKEN` is forbidden. The build
environment MUST forbid checksum-DB-bypassing Go env (`GOFLAGS=-mod=mod`,
`GONOSUMCHECK`, `GONOSUMDB=*`, an insecure/private `GOPROXY`/`GOINSECURE`).
*Why:* keyless signing's identity-binding premise ([SEC-06](#dimension-security-and-supply-chain-sec))
is defeated by an over-privileged workflow token; "build from a protected branch"
([FSM-RELEASE](#release-delivery-fsm-release)) is trustworthy only with required
review + signed commits; and a `GONOSUMCHECK`/insecure-`GOPROXY` build bypasses the
checksum DB ([VER-10](#dimension-versioning-and-compatibility-ver)/SR-4/SI-7).
Composes with [SEC-06](#dimension-security-and-supply-chain-sec)/[SEC-10](#dimension-security-and-supply-chain-sec)/
[VER-10](#dimension-versioning-and-compatibility-ver)/[FSM-RELEASE](#release-delivery-fsm-release).
*Enforcement:* the GitHub-posture IaC sets CODEOWNERS + required-review + required
signed-commits + branch protection and `caixa-validate` asserts the posture; a
`caixa-validate` check asserts every emitted workflow declares a minimal
`permissions:` block ([LAYOUT-07](#dimension-repo-layout-and-module-layout) is
extended to check it); a build-env analyzer forbids the checksum-DB-bypassing Go
env vars.
*Demonstrated by:* the example repo requires signed commits + 2 reviews on the
default branch; its `auto-release.yml` declares `permissions: { contents: read,
id-token: write }` scoped to the signing job; CI fails if `GONOSUMCHECK` is set.

**SEC-19** — Vulnerability risk is TIME-BOXED and CONTINUOUSLY MONITORED.
(1) Every `.trivyignore` / vuln-allowlist entry MUST carry an expiry date, and a
Rust analyzer PARSES the expiry and FAILS CI on any expired or undated suppression
(RA-5 time-boxed risk acceptance) — a comment convention is not a gate.
(2) A scheduled `forge image-rescan` rescans DEPLOYED digests, feeds the audit
sink, and an FSM-IMAGE `Verified → Degraded` re-evaluation edge flags a running
image that crosses the threshold post-deployment (RA-5 continuous monitoring /
FedRAMP ConMon). (3) A trivy/gitleaks FILESYSTEM scan of the built image tarball +
the Nix store path catches a secret baked at build time from an env var (not in
git), which the diff-based [SEC-11](#dimension-security-and-supply-chain-sec)
gitleaks scan misses.
*Why:* SEC-05/SEC-09 covered build/release-time CVEs but an allowlisted CRITICAL
stayed suppressed forever (no expiry gate) and a deployed image accrued new CVEs
with no rescan/alert and no FSM state to represent newly-vulnerable; and a
build-time-baked secret evaded the diff scan. Composes with [SEC-05](#dimension-security-and-supply-chain-sec)/
[SEC-09](#dimension-security-and-supply-chain-sec)/[SEC-11](#dimension-security-and-supply-chain-sec)/
[FSM-IMAGE](#image-delivery-fsm-image).
*Enforcement:* the allowlist analyzer parses expiry and fails on expired/undated
entries; `forge image-rescan` runs on cron over deployed digests, emits to the
audit sink, and drives the FSM-IMAGE `Verified → Degraded` edge; the artifact
filesystem secret scan runs on the image tarball + store path in the CVE step.
*Demonstrated by:* the example's `.trivyignore` carries
`CVE-2025-1234 # expires 2026-09-01 — upstream fix pending`; CI fails when that date
passes; a nightly rescan flips a deployed digest to `Degraded` when a new CRITICAL
lands; a build-baked test secret is caught by the tarball scan.

---

## Dimension: UI/UX Look-and-Feel (UI)

This dimension governs how a Go binary LOOKS and how a human navigates it — the
terminal-UI counterpart of the [Observability](#dimension-observability-obs) and
[CLI UX](#dimension-cli-ux-cli) dimensions. As with logging (`logging-go`),
errors (`errors-go`), and config (`shikumi-go`), there is exactly ONE owning
library — [`borealis`](https://github.com/pleme-io/borealis), THE pleme-io
terminal design system (BOREALIS theory §2.9 / §3.5) — and every user-facing
character a tool emits to a human is produced through it. The principle behind
every rule below is the borealis principle: *tokens are the source of truth;
every framework's theme struct is a render target of those tokens; NEVER
hand-author colour or spacing — derive it from one `borealis.Theme`.* The
dimension applies to any binary with a human surface (a `Binario` CLI, a
`Servico`'s operator-facing diagnostics, a `Supervisor`'s status board); a pure
machine-to-machine service with no human output is exempt, and a library
([`Biblioteca`](#glossary)) MUST NOT import borealis at all (it renders nothing —
[UI-11](#dimension-uiux-look-and-feel-ui)).

**UI-01** — Every Go binary that emits human-facing terminal output MUST render
it through `borealis` — the single fleet-wide terminal design system. The
resolved token bundle MUST be the one canonical type `borealis.Theme` (an alias
of `theme.Theme`), resolved exactly ONCE at startup via `borealis.FromConfig(cfg)`
and threaded as a value; the single render verb `borealis.Render(t, x)` is the
only sanctioned emitter of styled text. Direct `lipgloss`/`fmt`-with-ANSI/
hand-rolled escape-sequence rendering, a second design-system import, or a
per-tool `Styles`/`Theme` struct are FORBIDDEN. A binary with no human surface
(a headless `Servico`) is exempt until it grows its first human-facing line.
*Why:* a single render verb fed by a single token bundle is the borealis
uniformity contract — it is the visual analogue of "one `logging-go` logger"
([OBS-01](#dimension-observability-obs)) and "one `cli-go` App"
([CLI-01](#dimension-cli-ux-cli)): so two fleet tools cannot drift in how their
output looks. `borealis.Render` dispatches over a `Renderable`, a `fmt.Stringer`,
a `comp.Tabler`, `[]comp.Item`, `[]comp.Pair`, and a plain string, with a total
muted fallback, so a tool never reaches for a bespoke formatter. Composes with
[CLI-07](#dimension-cli-ux-cli)/[CLI-08](#dimension-cli-ux-cli) and
[OBS-01](#dimension-observability-obs).
*Enforcement:* forbidigo + depguard ban `charm.land/lipgloss`, `charmbracelet/*`,
and any non-`borealis` TUI/styling import outside the borealis leaves and
`_test.go`; a grep gate asserts a binary with a human surface imports `borealis`;
a `gsds-ui-lint` analyzer flags a `theme.Theme`/`*Styles` literal authored outside
`borealis.FromConfig`/`borealis.Nord` and any raw ANSI escape literal in `Run`/
handler bodies.
*Demonstrated by:* `main` resolves `t, _ := borealis.FromConfig(cfg.Borealis)`
once and every status line is `borealis.Render(t, result)`; no `lipgloss` import
appears outside the borealis dependency.

**UI-02** — Colour and visual semantics MUST be expressed through the typed
`borealis` token + role vocabulary, NEVER as a hand-authored hex/ANSI literal. A
tool maps its domain states onto the six semantic `borealis.Role`s
(`Neutral`, `Active`, `Info`, `Success`, `Warning`, `Danger`); the `Theme`
decides the actual `Color` via `Theme.RoleColor(role)`. Surfaces, text, and
borders MUST come from the named token fields (`Bg`/`Panel`/`Surface`,
`Fg`/`Muted`/`Subtle`, `Border`/`BorderSubtle`, `Primary`/`Secondary`/`Accent`).
A raw hex string, a bare `lipgloss.Color("#...")`, or an ANSI SGR integer in tool
code is FORBIDDEN — the only place a literal Nord hex value lives is the
`borealis/theme` palette constants (`theme.Nord0`…`Nord15`).
*Why:* colour decisions in one place is the borealis instinct (BOREALIS §2.9) —
roles are the stable contract, the palette is the render target, and a tool that
hard-codes `#BF616A` for "error" both breaks theming and silently diverges from
every other tool's red. Routing through `Role` also makes [accessibility
downsampling](#dimension-uiux-look-and-feel-ui) ([UI-08](#dimension-uiux-look-and-feel-ui))
a one-place transform. Composes with
[OBS-08](#dimension-observability-obs)/[ERR-04](#dimension-errors-err).
*Enforcement:* `gsds-ui-lint` rejects a hex-shaped string literal
(`^#[0-9A-Fa-f]{3,8}$`), an ANSI escape literal, and a `lipgloss.Color(...)` call
in any package other than `borealis/theme`; staticcheck flags a `theme.Color`
assigned from a non-token constant; a unit test asserts every domain state maps
to a `borealis.Role`.
*Demonstrated by:* a build step renders its status with
`comp.Glyph(t, borealis.Success)` / `comp.Badge(t, "FAILED", borealis.Danger)`;
grepping the tree for `#` hex literals returns only `borealis/theme/theme.go`.

**UI-03** — Layout, spacing, and alignment MUST be composed from the `borealis`
component + token surface, NOT hand-built with raw padding strings, manual
`strings.Repeat`, or magic-number column widths. Multi-row and tabular output
goes through the `comp` set: `comp.Table` (driven by a typed
`comp.Tabler { Columns() []comp.Column; Rows() [][]string }`) for tables,
`comp.StatusList` for glyph+label+detail rows, `comp.KV` for aligned key/value
pairs, `comp.Header` for a branded banner, and `comp.Rule` for dividers. Spacing,
borders, and panel/card framing come from `style.New(t)` styles
(`Title`/`Section`/`Panel`/`Card`) — derived from the `Theme` — never from
hand-tuned `Padding`/`Margin` integers scattered through tool code. Column widths
auto-size to the widest cell unless pinned via `comp.Column.Width`.
*Why:* a shared component grid is what makes `-o table` buildable across the
fleet's many SDK response shapes with zero per-tool column code (BOREALIS §2.9 /
the `comp.Tabler` seam): a domain type declares its `Columns`/`Rows` once and
borealis aligns, rules, and frames it identically everywhere. Hand-built spacing
is the visual equivalent of an inline `fmt.Sprintf` log — it drifts and cannot be
re-themed. Composes with [CLI-07](#dimension-cli-ux-cli) (`-o table`) and
[UI-01](#dimension-uiux-look-and-feel-ui).
*Enforcement:* `gsds-ui-lint` flags `strings.Repeat(" ", …)`/manual
padding-string construction and integer `Padding`/`Margin`/`Width` literals in
tool code (route them to `style`/`comp`); a `-o table` command MUST resolve a
`comp.Tabler` (the analyzer asserts the result type implements it or is rendered
via `comp.Table`); golden tests pin the aligned output.
*Demonstrated by:* `secret list -o table` returns a `[]Secret` whose element type
implements `comp.Tabler`, rendered via `borealis.Render(t, secrets)`; a section
header is `style.New(t).Section.Render("Targets")`; no manual column math exists.

**UI-04** — Status and result rendering MUST be DERIVED from the typed
`errors-go` Severity (and, for non-error state, an explicit `borealis.Role`),
NEVER hand-classified at the render site. The fixed mapping is total:
`SeverityNotice` → `Success`/`Info` role, `SeverityWarning` → `Warning` role,
`SeverityError` → `Danger` role; a non-error in-progress/pending state is the
`Active` role, an inactive/unknown state is `Neutral`. The rendered glyph,
badge, and colour all follow from that one role — a tool MUST NOT pick a red ✗ or
a green ✓ by branching on a string. The same severity that drives the exit code
([CLI-09](#dimension-cli-ux-cli)/[ERR-07](#dimension-errors-err)) and the log
level ([OBS-08](#dimension-observability-obs)) drives the glyph, so the three
surfaces (exit, log, screen) agree by construction.
*Why:* errors-go already classifies every failure by Severity; the on-screen
status is a pure function of that metadata, exactly as the log level
([OBS-08](#dimension-observability-obs) `logging.LogError` → `LevelForSeverity`)
and the exit code ([ERR-07](#dimension-errors-err) `errs.ExitCode`) are. Three
independent hand-classifications is three ways to disagree about whether
something failed. Composes with
[ERR-04](#dimension-errors-err)/[ERR-07](#dimension-errors-err)/[OBS-08](#dimension-observability-obs).
*Enforcement:* a shared `borealis`/`logging-go` helper turns a `SeverityOf(err)`
into a `borealis.Role` (the single mapper, exhaustive-linted like
`LevelForSeverity`); `gsds-ui-lint` flags a `comp.Glyph`/`comp.Badge` whose `Role`
is selected by `strings.Contains`/`err.Error()` matching rather than
`errs.SeverityOf`; a golden table test asserts the three-rung severity→role map.
*Demonstrated by:* a failed step renders
`comp.StatusList(t, []comp.Item{{Role: roleOf(errs.SeverityOf(err)), Label: name, Detail: errs.CodeOf(err)}})`
where `roleOf` is the shared exhaustive mapper; the same `err` exits 70 and logs
at ERROR.

**UI-05** — Errors shown to a human MUST be rendered through `borealis` from the
`errors-go` value, surfacing its severity, message, and machine `Code` — NEVER
printed with `fmt.Fprintln(os.Stderr, err)` or a bespoke red-text helper. For a
CLI, the styled help/usage/error surface MUST be the `fangx` (fang) decorator
wired to the borealis `ColorScheme(t)`, so `--help`, usage-on-error, version, and
completions are themed from the same Nord tokens as everything else
(`borealis.Execute(ctx, root)` / `fangx.Execute(ctx, root, t)`). The error body a
human reads MUST be the human message ([CLI-10](#dimension-cli-ux-cli) lowercase,
no Go-internal noise); the machine `Code` is shown as a stable, greppable affix,
and the internal wrap chain MUST NOT leak into a user-facing or RPC-body
rendering ([ERR-12](#dimension-errors-err)).
*Why:* the CLI help/errors surface is one of the exactly-three charm-stack
themeable surfaces (BOREALIS §2.9); routing it through `fangx`'s `ColorScheme`
closes the "headline auto-help gap" and means a tool gets styled, consistent
error/usage rendering for free. Rendering from the typed error (not a string)
keeps the severity → colour decision a pure function ([UI-04](#dimension-uiux-look-and-feel-ui)).
Composes with [CLI-08](#dimension-cli-ux-cli)/[CLI-10](#dimension-cli-ux-cli)/
[ERR-12](#dimension-errors-err)/[OBS-08](#dimension-observability-obs).
*Enforcement:* forbidigo bans `fmt.Fprint*(os.Stderr, …)` carrying an `error` and
bespoke "print in red" helpers in `cmd/`/command packages; a grep gate asserts a
`cli-go` CLI's entrypoint is `borealis.Execute`/`fangx.Execute` (the fang
decorator), not a bare `cobra`/`app.Run` without the borealis `ColorScheme`; the
conformance harness asserts a failing command's stderr carries the human message
+ a `Code`-shaped affix and no Go-internal `*fmt.wrapError` noise.
*Demonstrated by:* `main` is
`cli.Exit(borealis.Execute(ctx, root))`; a validator failure prints a Nord-themed,
lowercase `ttl: must be in [1, 3600] (E_USAGE)` to stderr; the wrap chain is never
shown.

**UI-06** — Output MUST be TTY-AWARE: a binary detects whether stdout/stderr is an
interactive terminal and renders accordingly. When a stream is a TTY and colour is
permitted, output is styled (borealis colour, glyphs, alignment, optionally live
widgets); when a stream is NOT a TTY (a pipe, a file, a CI log) the DATA stream
([CLI-07](#dimension-cli-ux-cli) stdout) MUST be plain and machine-parseable — and
when the requested `--output` is `json`/`yaml`, stdout MUST be EXACTLY one valid
document with NO styling, spinners, colour, or borealis decoration interleaved
([CLI-07](#dimension-cli-ux-cli)/[CLI-08](#dimension-cli-ux-cli)). Human
diagnostics (progress, status) remain on stderr and MAY stay styled when stderr is
a TTY. Detection MUST go through the borealis/charm colour-profile seam, never a
hand-rolled `isatty`.
*Why:* a CLI is simultaneously a human surface and a machine boundary; the
`-o json | jq` contract ([CLI-07](#dimension-cli-ux-cli)) breaks the instant a
colour code or spinner frame lands on stdout. lipgloss v2's explicit colour
profile + the borealis `Color`/`Mode` knobs are the no-hidden-global seam that
makes "styled for a human, plain for a pipe" automatic. Composes with
[CLI-07](#dimension-cli-ux-cli)/[CLI-08](#dimension-cli-ux-cli)/[UI-08](#dimension-uiux-look-and-feel-ui).
*Enforcement:* `gsds-ui-lint` bans a hand-rolled `isatty`/`term.IsTerminal` call
in tool code (route through the borealis seam) and flags borealis styling applied
to the `-o json`/`-o yaml` stdout path; the conformance harness captures
stdout/stderr separately and asserts piped/`-o json` stdout is byte-clean (no SGR
escapes) while a forced-TTY run is styled.
*Demonstrated by:* `tool secret list -o json | jq` is pure JSON; `tool secret
list` in an interactive terminal is a Nord-styled `comp.Table`; the same command
redirected to a file emits a plain aligned table with no escape codes.

**UI-07** — Colour output MUST honour the `NO_COLOR` convention and the typed
`borealis.Config.Color` knob, and a tool MUST be fully usable with colour
disabled. Setting `NO_COLOR` in the environment (the cross-tool standard) OR
`color: never` in config (`ColorNever`) MUST suppress ALL colour — borealis
records this via `Config.NoColor()`, which the gated leaves consult when building
their framework theme structs. `color: always` (`ColorAlways`) forces colour even
when not a TTY; `color: auto` (`ColorAuto`, the default) downsamples to the
detected terminal profile. Information MUST NEVER be conveyed by colour ALONE: a
status distinguished by colour MUST also carry a glyph/label
(`comp.Glyph`/`comp.Badge` already pair a role-coloured glyph with text), so a
no-colour or colour-blind reader loses nothing.
*Why:* `NO_COLOR` is a widely-honoured user-agency convention and a hard
accessibility floor; colour-as-sole-signal fails colour-blind users and every
no-colour pipe. borealis already encodes the knob (`ColorMode` +
`Config.NoColor()`) and pairs glyph-with-label by construction in `comp` — the
rule is to consume it, never to re-decide colour per tool. Composes with
[UI-02](#dimension-uiux-look-and-feel-ui)/[UI-06](#dimension-uiux-look-and-feel-ui)/[UI-08](#dimension-uiux-look-and-feel-ui)
and the [`--no-color`](#dimension-cli-ux-cli) global ([CLI-05](#dimension-cli-ux-cli)).
*Enforcement:* `gsds-ui-lint` asserts the colour decision flows from
`borealis.Config.NoColor()`/`ColorMode` (flags a direct `os.LookupEnv("NO_COLOR")`
outside borealis and a colour decision keyed off anything else); the
`--no-color` global ([CLI-05](#dimension-cli-ux-cli)) maps to `ColorNever`; a
conformance test runs every command with `NO_COLOR=1` asserting zero SGR escapes
AND that each status row still carries its glyph/label.
*Demonstrated by:* `NO_COLOR=1 tool status` emits the same `comp.StatusList` rows
with glyphs (`✓`/`▲`/`✗`) and labels but no colour; `--no-color` and `color:
never` produce byte-identical plain output; `color: always` keeps colour through a
pipe.

**UI-08** — Rendering MUST be ACCESSIBLE by construction: it MUST downsample to
the detected terminal colour profile (truecolor → 256 → 16 → no-colour) without
loss of meaning, and a typed `borealis.Config.Accessible` mode MUST bias every
surface toward high-contrast, no-colour-dependent, screen-reader-friendly output.
Downsampling MUST go through the borealis/lipgloss colour-profile seam (Nord
tokens degrade to the nearest profile colour) — never a hand-rolled palette
switch. When `Accessible` is set, interactive forms MUST pass `huh`'s accessible
mode through ([UI-09](#dimension-uiux-look-and-feel-ui)), live/animated widgets
MUST degrade to static, plain output ([UI-10](#dimension-uiux-look-and-feel-ui)),
and components bias toward high-contrast token pairings. The `Mode`
(`auto`/`light`/`dark`) knob governs background adaptation through the same seam.
*Why:* a design system that only looks right on a truecolor dark terminal is not a
fleet standard; Nord is a role-grouped palette precisely so it degrades
predictably, and lipgloss v2's explicit profile + `LightDark` seam is the correct
no-hidden-global mechanism. An explicit `Accessible` mode is the difference
between "usually readable" and "guaranteed usable with a screen reader / 16-colour
TTY / high-contrast need". Composes with
[UI-07](#dimension-uiux-look-and-feel-ui)/[UI-09](#dimension-uiux-look-and-feel-ui)/[UI-10](#dimension-uiux-look-and-feel-ui).
*Enforcement:* `gsds-ui-lint` flags a hand-rolled colour-profile/palette switch
and a colour emitted outside the borealis profile seam; the conformance harness
renders a fixture under truecolor/256/16/no-colour profiles asserting the role set
is distinguishable in each; an `Accessible=true` run asserts forms are in huh
accessible mode and no animated widget is constructed.
*Demonstrated by:* the canonical tool's golden tests pin its `comp.StatusList`
output under all four profiles; `BOREALIS_ACCESSIBLE=1 tool init` (an
`Accessible` config) runs the setup form in huh's accessible mode with a static
status board.

**UI-09** — Interactive prompts and forms MUST be built with `huh` THROUGH the
borealis `huhx` leaf — a tool MUST NOT hand-roll a prompt loop, read raw
keypresses for a yes/no, or import `huh` and author its own `huh.Theme`. A form is
constructed with `huh.NewForm(...).WithTheme(huhx.HuhTheme(t))` so prompts,
selects, multi-selects, text inputs, and validation styling inherit the same Nord
tokens (focused/blurred field colours, error indicators, selected-option accent)
as help text and widgets. When `borealis.Config.Accessible` is set, the form MUST
ALSO be put into huh's accessible mode at the form level
([UI-08](#dimension-uiux-look-and-feel-ui)). Interactivity MUST degrade: a
non-TTY/piped invocation or a missing required input MUST NOT block on a prompt —
it MUST fail with an actionable `errors-go` error
([CLI-10](#dimension-cli-ux-cli)) telling the operator which flag/env to supply.
*Why:* interactive forms are one of the exactly-three charm-stack themeable
surfaces (BOREALIS §2.9); `huhx.HuhTheme(t)` eliminates per-tool form styling so
every wizard looks the same. A prompt that blocks in a pipeline or CI is a
hang-the-build hazard, so interactivity must always have a non-interactive escape.
Composes with [CLI-06](#dimension-cli-ux-cli)/[CLI-10](#dimension-cli-ux-cli)/
[UI-06](#dimension-uiux-look-and-feel-ui)/[UI-08](#dimension-uiux-look-and-feel-ui).
*Enforcement:* forbidigo + depguard ban a direct `charm.land/huh` import outside
`huhx`/`_test.go` and a hand-rolled `huh.Theme`; `gsds-ui-lint` asserts every
`huh.NewForm` is `.WithTheme(huhx.HuhTheme(t))` and is guarded by a TTY check
([UI-06](#dimension-uiux-look-and-feel-ui)) with a non-interactive
`errors-go`-error fallback; a conformance test pipes empty stdin and asserts a
required-input prompt fails with exit 64 rather than hanging.
*Demonstrated by:* `tool init` (interactive) builds
`huh.NewForm(...).WithTheme(huhx.HuhTheme(t))`; `tool init < /dev/null` does not
hang — it exits 64 with `endpoint: required (set --endpoint or TOOL_ENDPOINT)`.

**UI-10** — Live/animated terminal widgets (spinners, progress bars, tables,
status boards, anything redrawing) MUST use the borealis `bubblesx` (stock
bubbles widgets) and `tui` (live `tea.Model` components) leaves, themed from one
`borealis.Theme` — a tool MUST NOT import `bubbletea`/`bubbles` directly and style
widgets by hand. Per-component styles come from `bubblesx.New(t)` (e.g.
`b.Spinner()` / `b.Progress()` / `b.TableStyles`); a live board is a borealis
`tui` component carrying an injected `Theme` (`tui.NewStatusBoard(t, title,
items…)`), whose `View` delegates to the static `comp` renderers so the live and
golden surfaces stay byte-identical. Live widgets MUST render only to a TTY
stderr/alt-screen ([UI-06](#dimension-uiux-look-and-feel-ui)) and MUST degrade to
static `comp` output when not a TTY or when
`Accessible`/`color: never`/`NO_COLOR` is in effect — they MUST NEVER touch the
`-o json`/`-o yaml` data stream.
*Why:* stock widgets are the third charm-stack themeable surface (BOREALIS §2.9);
`bubblesx.New(t)` makes every spinner/progress/table inherit the Nord tokens, and
having `tui` `View`s delegate to the static `comp` renderers means the animated
surface and the golden-tested static surface can never diverge. A spinner frame on
a non-TTY pipe is animation garbage in a log; it must degrade. Composes with
[UI-03](#dimension-uiux-look-and-feel-ui)/[UI-06](#dimension-uiux-look-and-feel-ui)/[UI-08](#dimension-uiux-look-and-feel-ui)/[JOB-01](#dimension-concurrency-and-jobs-job).
*Enforcement:* forbidigo + depguard ban direct `charm.land/bubbletea` and
`charm.land/bubbles` imports outside `bubblesx`/`tui`/`_test.go`; `gsds-ui-lint`
asserts a `spinner`/`progress`/`table` model is constructed from `bubblesx.New(t)`
and a live program is gated by a TTY check with a static-`comp` fallback; a golden
test asserts a `tui` component's `View` equals the corresponding `comp` render.
*Demonstrated by:* a long reconcile shows `bubblesx.New(t).Spinner()` on a TTY and
falls back to `comp.StatusList` lines when piped; `tui.NewStatusBoard(t, "Targets",
items…)`'s `View` is byte-identical to `borealis.Render(t, items)` in its golden
file.

**UI-11** — The borealis dependency MUST be scoped to the human surface, and the
weight of the charm-stack v2 leaves MUST stay import-gated. A `Biblioteca`
([library](#glossary)) MUST NOT import `borealis` — a library renders nothing and
returns typed values/`errors-go` errors for its consumer to render. The borealis
CORE (`borealis` + `theme` + `comp` + `style`) carries NO heavy charm-stack
dependency; the three v2 leaves (`fangx`/`huhx`/`bubblesx`) and the live `tui`
leaf are imported ONLY by the `cmd/<bin>` / command packages that actually draw
that surface, never pulled transitively into core logic. A domain type that wants
to be renderable exposes the typed seam (`comp.Tabler`, or a
`borealis.Renderable`'s `RenderBorealis(t) string`) WITHOUT importing a v2 leaf.
*Why:* this is the borealis Law 6 (weight is import-gated) / Law 8 (no core↔core
cycle) discipline: a fleet library must stay offline-buildable and dependency-light
([LAYOUT-10](#dimension-repo-layout-and-module-layout)), and forcing fang/cobra/
bubbletea into business logic both bloats the closure and couples pure code to a
UI framework. The render-to-string `comp` set is the seam that lets even
`shikumi-go/diag` and `logging-go/console` produce themed output without the heavy
deps. Composes with
[LAYOUT-03](#dimension-repo-layout-and-module-layout)/[LAYOUT-10](#dimension-repo-layout-and-module-layout)/[ERR-05](#dimension-errors-err).
*Enforcement:* `caixa-validate` rejects a `borealis` import in a `Biblioteca`
(`:kind` from `caixa.lisp`); depguard scopes `fangx`/`huhx`/`bubblesx`/`tui`
imports to `cmd/**` + command packages (a leaf import in `internal/<domain>`
business logic fails); `go build ./...` + the closure-size check enforce the
core-vs-leaf boundary; a domain type implements `comp.Tabler`/`borealis.Renderable`
without importing a leaf.
*Demonstrated by:* the example's `internal/secret` package returns a `[]Secret`
implementing `comp.Tabler` and imports no borealis leaf; only `cmd/tool` imports
`fangx`/`huhx`/`bubblesx`; `nix build .#default` of a `Biblioteca` shows no
charm-stack dep in its closure.

**UI-12** — Theming and the visual surface are a typed, single-sourced
configuration: the design system is configured ONCE via `borealis.Config`
(`{Theme, Mode, Color, Accessible}`, yaml-tagged), loaded through `shikumi-go`
like all other config ([CFG-01](#dimension-configuration-cfg)) and resolved to the
canonical `Theme` exactly once via `borealis.FromConfig(cfg.Borealis)` — which is
PURE and MUST NOT call `shikumi.Load` itself. A tool MUST NOT hand-author a theme:
leaving `Config.Theme` zero selects the Nord brand default
(`borealis.Nord()`/`Default()`); a YAML file MAY override individual tokens (pure
data), which is the consume-an-upstream-generated-theme seam (BOREALIS Law 4 — the
committed direction is ishou-generated tokens via `ishou render --target lipgloss`,
replacing the hardcoded palette byte-for-byte when it lands). The resolved
`borealis.Theme` is threaded as a value from `main`/`bootstrap.Config`; capturing
it in a package-level global is FORBIDDEN.
*Why:* one typed config surface for the look-and-feel mirrors the whole
[Configuration](#dimension-configuration-cfg) dimension — the theme is just more
config, loaded by the one loader, resolved by a pure consumer, threaded as a value
([CFG-01](#dimension-configuration-cfg)..[CFG-04](#dimension-configuration-cfg)).
Keeping `FromConfig` pure (no `shikumi.Load` inside) preserves the
load-once/resolve-pure boundary; never hand-authoring a theme is the borealis
*consume, don't author* law and the on-ramp to ishou generation. Composes with
[CFG-01](#dimension-configuration-cfg)/[CFG-14](#dimension-configuration-cfg)/[UI-01](#dimension-uiux-look-and-feel-ui)/[UI-02](#dimension-uiux-look-and-feel-ui).
*Enforcement:* `gsds-ui-lint` asserts the `borealis.Config` is loaded via the
shikumi `cfg.Load`/`bootstrap.Config` path and `FromConfig` is the only resolver
(flags a `borealis.Theme` literal authored in tool code and a `shikumi.Load`
inside a theme path); a no-`shikumi.Load`-in-`FromConfig` check mirrors
[CFG-01](#dimension-configuration-cfg); a `Theme` captured in a package var is
flagged (mirrors [CFG-11](#dimension-configuration-cfg)).
*Demonstrated by:* `main` does
`t, _ := borealis.FromConfig(cfg.Borealis)` once (where `cfg` came from
`shikumi`), passes `t` down by value, and a `config.yaml` with `borealis: { mode:
dark, color: never }` round-trips; no `theme.Theme{...}` literal appears in tool
code.

---

## Delivery FSM Type System

Delivery itself is modeled as a typed, pure, table-driven **finite state machine**
(FSM) — one machine per artifact class. All four share the
[`shigoto-go`](https://github.com/pleme-io/shigoto-go) idiom (and its Rust
`shigoto` sibling): a comparable `State`/`Signal` enum with stable kebab-case
`String()`/`kind()`, a pure total `advance(from, signal, …)` driver that returns
`ErrIllegalTransition` for every cell not enumerated, and PURE `Gate`s that read a
captured snapshot of typed facts and perform **no IO** (all IO — `git`, `go
build`/`test`, proxy probes, cosign, syft, trivy, `kubectl` — lives in the
Job/Execute layer that *populates* the snapshot, never inside a gate; this is
[JOB-11](#dimension-concurrency-and-jobs-job)/[JOB-12](#dimension-concurrency-and-jobs-job)
applied to delivery).

Shared properties enforced by **every** machine below (a property absent in any one
machine is a gap; all four now carry the full set):

- **Gapless table.** Every `(State, Signal)` pair is either an enumerated legal
  transition or returns `ErrIllegalTransition` with the input state unchanged — the
  FSM never silently advances and never panics. NO state is ever reached by an
  out-of-FSM mutation: any timeout/deadline is consumed as an enumerated signal
  (e.g. `ConfirmProxy` consuming `poll_budget_exhausted`, [VER-16](#dimension-versioning-and-compatibility-ver)).
- **Pure gates, tri-state verdict.** A gate is a predicate over a captured snapshot;
  `advance` re-checks the relevant gate so the FSM and the gate verdict can never
  disagree. A gate verdict is `Pass | Fail | Indeterminate`: **Indeterminate** (the
  Job that should populate a fact errored or timed out — "couldn't measure") routes
  to a RETRYABLE state, NEVER to a hard terminal. A genuine `Fail` (measured-bad)
  and an `Indeterminate` (infra flake) are distinct outcomes — a trivy crash must
  not become a hard CVE terminal ([FSM-TRISTATE](#delivery-fsm-type-system)).
- **Terminal-absorbing.** Terminal states accept no further signal; re-delivery is a
  new FSM run with a FRESH snapshot (a revival path that re-enters a start state
  MUST reset captured facts — [FSM-RESET](#delivery-fsm-type-system)).
- **Deterministic `advance`.** Same `(from, signal, snapshot)` always yields the same
  result.
- **Universal fail escape.** Every non-terminal state has a `Fail(reason)` edge
  (via `AlwaysGate`) so runner-death/OOM/network-partition mid-step is a DEFINED
  transition to a fail state, never a stranded non-terminal limbo
  ([FSM-FAIL](#delivery-fsm-type-system)). FailReason enumerates `RunnerDied`,
  `TokenExpired`, `NetworkPartition`, plus the step-specific causes.
- **Every transition is audited.** Each `advance` success emits one append-only
  Transition record (from, signal, gate-aggregate, to, artifact-id, severity) to the
  logging-go/errors-go sink (shigoto's `TransitionEmitter`, [JOB-13](#dimension-concurrency-and-jobs-job));
  terminal-fail carries severity=error, terminal-ok severity=notice. This is a
  SHARED property of all four machines ([FSM-AUDIT](#delivery-fsm-type-system)).
- **Idempotent steps.** Re-issuing any delivery `Signal` after a partial prior side
  effect is idempotent against that step's own partial output (DELIVERY-IDEMPOTENT,
  [FSM-IDEMPOTENT](#delivery-fsm-type-system)); re-running `Push`/`Sign`/`Release`/
  `UpdateFormula` is a no-op on already-completed work and a resume on incomplete
  work.
- **Single-writer / CAS publish.** The publishing mutator (`forge tool release` /
  `forge image-release`) is the SINGLE writer, serialized by an advisory lock; the
  publish side effect (tag push / registry push) is itself the compare-and-swap and
  its failure (non-fast-forward / tag-exists / digest-exists) is a first-class signal
  ([FSM-CAS](#delivery-fsm-type-system)), never a lost race silently dropped.

The four machines correspond to the four Go artifact kinds. Their identities are
`FSM-MODULE-*`, `FSM-RELEASE-*`, `FSM-IMAGE-*`, `FSM-ACTION-*` (states are referred to
by name within each machine). The full typed spec (per-case transition table incl.
illegal-by-omission notes, gates with predicates, invariants, Rust + shigoto-go
mirrors) lives in the standalone [`go-delivery-fsms.md`](./go-delivery-fsms.md);
this section is the in-standard summary.

### FSM status / observability

The navigator-readable FSM state surface. `forge tool status` prints the artifact's
current FSM state, the last gate verdict, and (on a refusal) the owning rule and the
fix — so "what state is this in and why" and "is `vX.Y.Z` out?" are answerable
without reading Rust/Go source. The state is PERSISTED as: (a) a `check-all` receipt
artifact, (b) a GitHub commit-status per FSM state (`gsds/fsm:<state>`), and (c) the
`forge tool status` readout. Every transition is audited ([FSM-AUDIT](#delivery-fsm-type-system))
so an SRE can reconstruct a stuck/rolled-back delivery from the append-only log.

Gate-verdict → owning-rule → fix mapping (the FSM half of [DOC-17](#dimension-documentation-and-discoverability-doc)):

| Gate refusal | Owning rule | Fix |
|---|---|---|
| `ValidationGate` (dirty tree / red tests) | [TEST-08](#dimension-testing-and-quality-test) | `nix run .#check-all`; commit/push |
| `TagGate` (tag exists / not greater) | [VER-01](#dimension-versioning-and-compatibility-ver)/[VER-03](#dimension-versioning-and-compatibility-ver) | bump to a strictly-greater version |
| `MajorCrossoverGate` | [VER-17](#dimension-versioning-and-compatibility-ver) | land suffix + import rewrite in one snapshot |
| `ModuleRollbackGate` (proxy cached) | [VER-14](#dimension-versioning-and-compatibility-ver) | publish a retracting patch, do not delete the tag |
| `TagPushRaceLost` | [FSM-CAS](#delivery-fsm-type-system) | re-validate against the new tip; the other writer won |
| `ChecksumGate` (irreproducible) | [SEC-01](#dimension-security-and-supply-chain-sec) | restore reproducibility (`-trimpath`, `SOURCE_DATE_EPOCH`, pinned deps) |
| `G_cve_under_threshold` (Fail) | [SEC-05](#dimension-security-and-supply-chain-sec) | bump deps; never sign-around |
| `G_cve_under_threshold` (Indeterminate) | [FSM-TRISTATE](#delivery-fsm-type-system) | retry the scan (infra flake), not a CVE |
| `TapReachableGate` (assets incomplete) | [SEC-16](#dimension-security-and-supply-chain-sec) | resume upload; do not re-cut |
| `G_apply_accepted` (admission reject) | [SEC-14](#dimension-security-and-supply-chain-sec) | fix the SecurityContext to restricted |
| `G_readiness_green` (timeout) | [SEC-13](#dimension-security-and-supply-chain-sec) | retry deploy (transient) or roll back |

| FSM | ID prefix | Kinds | Publish event |
|---|---|---|---|
| Module delivery | `FSM-MODULE` | library (single Go module) | tag push (pull-model, no upload) |
| Release delivery | `FSM-RELEASE` | cli, binary | GitHub Release + Homebrew formula |
| Image delivery | `FSM-IMAGE` | daemon, service | registry push (signed + attested + scanned) |
| Action delivery | `FSM-ACTION` | github-action | tag push + rendered `action.yml` |

---

### Module Delivery (FSM-MODULE)

**Kinds:** library. **Publish model:** Go's pull-model, tag-only — the only publish
side effect is `git push origin <tag>`; `proxy.golang.org` fetches lazily on first
`go get` (there is no upload step, contrast `cargo publish`). This is the FSM
statement of [LAYOUT-05](#dimension-repo-layout-and-module-layout) and
[VER-12](#dimension-versioning-and-compatibility-ver).

#### Transition table

| From | Signal | Gate | To |
|---|---|---|---|
| Drafted *(start)* | Validate | `ValidationGate` | Validated |
| Drafted | Reject | `AlwaysGate` | ValidationFailed *(fail)* |
| Validated | Tag | `TagGate` | Tagged |
| Validated | MajorCrossover | `MajorCrossoverGate` | Validated *(re-validated, crossover-coherent)* |
| Validated | Reject | `AlwaysGate` | TagRejected *(fail)* |
| Tagged | PushTag | `PublishGate` (CAS) | Proxied |
| Tagged | PushTag | `PublishGate` lost-race | TagRejected *(fail; tag now exists remotely)* |
| Tagged | Rollback | `ModuleRollbackGate` | RolledBack *(fail)* |
| Proxied | ConfirmProxy | `ProxyAvailableGate` (`!poll_budget_exhausted`) | Proxied *(poll self-loop)* |
| Proxied | ConfirmProxy | `poll_budget_exhausted` | ProxyTimedOut *(in-FSM timeout)* |
| Proxied | Verify | `VerifyGate` | Verified *(ok)* |
| Proxied | Verify | `VerifyGate` Indeterminate | Proxied *(retryable — measure failed)* |
| Proxied | Reject | `AlwaysGate` | VerificationFailed *(fail)* |
| Proxied | Rollback | `ModuleRollbackGate` | RolledBack *(fail)* |
| ProxyTimedOut | RetryProxy | `ProxyAvailableGate` | Proxied |
| ProxyTimedOut | Reject | `AlwaysGate` | VerificationFailed *(fail)* |
| ProxyTimedOut | Rollback | `ModuleRollbackGate` | RolledBack *(fail)* |
| *(any non-terminal)* | Fail(reason) | `AlwaysGate` | DeliveryFailed *(fail; RunnerDied/etc.)* |

States: `Drafted` (start), `Validated`, `Tagged`, `Proxied` (non-terminal poll),
`ProxyTimedOut` (non-terminal recovery), `Verified` (terminal-ok), and the
terminal-fail set `ValidationFailed`, `TagRejected`, `VerificationFailed`,
`RolledBack`, `DeliveryFailed`. The `Proxied → ProxyTimedOut` transition is now
IN-FSM: `ConfirmProxy` consumes a `poll_budget_exhausted` fact (the typed deadline/
retry budget of [VER-16](#dimension-versioning-and-compatibility-ver)), so the
timeout is an enumerated, audited transition — not an out-of-FSM mutation the
gapless table forbids. The universal `Fail(reason)` escape (RunnerDied,
TokenExpired, NetworkPartition) makes runner-death from any step a defined
transition. `PushTag` is a CAS: if the remote tag now exists (lost a concurrent
race), the gate yields `TagRejected`, never a silently-dropped push.

#### Gates

- **`ValidationGate`** (Drafted→Validated). Pass iff ALL: (a) clean working tree
  (`git status --porcelain` empty); (b) HEAD == remote tip
  (`git rev-list --count @{u}..HEAD == 0`); (c) for the intended version v≥2.0.0 the
  go.mod module path ends in the matching `/vN` suffix
  ([VER-02](#dimension-versioning-and-compatibility-ver)); (d) `go vet ./...` exit 0;
  (e) `go test ./...` exit 0; (f) `go build ./...` exit 0 (the substrate
  `mkGoLibraryCheck` derivation); (g) the intended version parses as strict semver and
  is strictly greater than the highest existing tag. Pure over a captured `Snapshot`.
- **`TagGate`** (Validated→Tagged). Pass iff ALL: (a) the tag name is canonical
  `vMAJOR.MINOR.PATCH` (or `sub/vMAJOR.MINOR.PATCH` for a submodule); (b) the tag does
  NOT already exist locally or on the remote (immutable, re-tagging forbidden —
  [VER-03](#dimension-versioning-and-compatibility-ver)); (c) version strictly greater
  than `lastTag` (re-asserted to defend a concurrent tag); (d) the /vN↔major suffix
  invariant still holds; (e) the API-compat verdict (`gorelease`/`apidiff` baseline =
  `lastTag`) implies any BREAKING change requires `major(version) > major(lastTag)`
  ([VER-05](#dimension-versioning-and-compatibility-ver)).
- **`PublishGate`** (Tagged→Proxied, CAS). Pass iff ALL: (a) the annotated tag
  points at the exact validated HEAD; (b) the push is fast-forward/additive only;
  (c) the /vN suffix still matches. The push is the COMPARE-AND-SWAP itself:
  `git push origin <tag>` is serialized (single-writer `forge tool release`,
  advisory lock) and, if the remote tag was created by a concurrent writer between
  snapshot and push (non-fast-forward / tag-exists), the gate yields `TagRejected`
  with a `TagPushRaceLost` reason — a first-class signal, never a lost race. NO
  ARTIFACT UPLOAD — PushTag's only side effect is `git push origin <tag>`.
- **`MajorCrossoverGate`** (Validated→Validated, active only when `major(version) >
  major(lastTag)`). Pass iff, over the SINGLE validated snapshot, ALL of:
  `major_suffix_ok ∧ all_intramodule_imports_rewritten ∧ prior_major_resolvable`
  ([VER-17](#dimension-versioning-and-compatibility-ver)). Makes VER-06 atomicity
  machine-enforced: a suffix-in-one-commit / imports-in-another split is rejected.
- **`ModuleRollbackGate`** (Tagged/Proxied/ProxyTimedOut→RolledBack). Replaces the
  old unconditional `AlwaysGate` on rollback. Pass iff EITHER (a) the proxy has NOT
  yet cached the version (`proxy_status != 200 ∧ !proxy_has_cached`) so deleting the
  unpushed/uncached tag is safe; OR (b) a retracting patch `vX.Y.(Z+1)` with a
  `retract` directive has been published ([VER-14](#dimension-versioning-and-compatibility-ver)).
  If the proxy already cached, deleting the tag violates IMMUTABLE-TAG and is
  refused — the only legal forward path is the retracting patch. Emits a typed
  `RollbackReceipt`.
- **`ProxyAvailableGate`** (Proxied self-loop / ProxyTimedOut→Proxied). Pass iff the
  proxy has indexed the version:
  `GET https://proxy.golang.org/<escaped-module>/@v/<version>.info` returns 200 AND
  the `.info` `Version` == the intended version. (The probe runs in the Job layer; the
  gate reads the captured fact.)
- **`VerifyGate`** (Proxied→Verified). Pass iff, against a hermetic scratch module
  (empty `GOMODCACHE`, `GOPROXY=https://proxy.golang.org`,
  `GOSUMDB=sum.golang.org`): (a) `go get <module>@<version>` succeeds; (b) the resolved
  version == intended exactly; (c) `go.sum` now carries BOTH the `h1:` module-zip hash
  AND the `/go.mod h1:` hash and both verify against the checksum database; (d) a
  consumer build importing the public package compiles.
- **`AlwaysGate`** — unconditional, guards the operator/terminal escape edges
  (`Reject`, `Rollback`) so the table is gap-free.

#### Invariants

- **MONOTONIC-VERSION** — every successful delivery ends with a tag strictly greater
  (semver) than every prior; enforced at TWO gates
  (`ValidationGate`(g) AND `TagGate`(c)) to defend a concurrent tag. (Restates
  [VER-01](#dimension-versioning-and-compatibility-ver).)
- **MAJOR-SUFFIX-COHERENCE** — major N≥2 ⇒ go.mod path ends in `/vN` with N ==
  major(tag); re-asserted in `ValidationGate`(c), `TagGate`(d), `PublishGate`(c).
  (Restates [VER-02](#dimension-versioning-and-compatibility-ver).)
- **NO-BREAKING-WITHOUT-MAJOR** — a breaking public-API change requires
  major(version) > major(lastTag); `TagGate`(e). (Restates
  [VER-05](#dimension-versioning-and-compatibility-ver).)
- **IMMUTABLE-TAG** — a published version tag is never re-pointed or force-pushed;
  `TagGate`(b) + `PublishGate`(b). (Restates
  [VER-03](#dimension-versioning-and-compatibility-ver).)
- **PULL-MODEL / NO-UPLOAD** — the ONLY publish side effect is `git push origin
  <tag>`; the FSM has NO Upload signal/state by construction. (Restates
  [LAYOUT-05](#dimension-repo-layout-and-module-layout)/[VER-12](#dimension-versioning-and-compatibility-ver).)
- **CHECKSUM-DB-VERIFIED** — Verified is reached only after sum.golang.org has both
  the `h1:` and `/go.mod h1:` hashes and they verify; `VerifyGate`(c).
- **CLEAN-TREE-AT-VALIDATE** — Validate is impossible with a dirty tree or un-pushed
  commits; `ValidationGate`(a/b). A revival that re-enters `Drafted` re-reads the
  working tree (re-Validate), never bypassing this on stale facts (FSM-RESET).
- **TAG-PUSH-IS-CAS** — `PushTag` is the compare-and-swap; a lost concurrent race
  (remote tag now exists) yields `TagRejected`, not a silently-dropped push;
  `forge tool release` is the serialized single writer ([FSM-CAS](#delivery-fsm-type-system)).
- **PROXY-TIMEOUT-IN-FSM** — `Proxied → ProxyTimedOut` is reached only by
  `ConfirmProxy` consuming `poll_budget_exhausted` (typed deadline,
  [VER-16](#dimension-versioning-and-compatibility-ver)); no out-of-FSM mutation.
- **ROLLBACK-RESPECTS-IMMUTABILITY** — `ModuleRollbackGate` refuses to delete a
  proxy-cached tag (would violate IMMUTABLE-TAG); the only post-cache repudiation is
  a retracting patch ([VER-14](#dimension-versioning-and-compatibility-ver)).
- **MAJOR-CROSSOVER-ATOMIC** — when the major increments, `MajorCrossoverGate`
  asserts suffix + all imports + prior-major-reachability over ONE snapshot
  ([VER-17](#dimension-versioning-and-compatibility-ver)).
- **UNIVERSAL-FAIL** — every non-terminal state has a `Fail(reason)` edge to
  `DeliveryFailed` (RunnerDied/TokenExpired/NetworkPartition), so runner death mid-step
  is defined ([FSM-FAIL](#delivery-fsm-type-system)).
- **AUDITED** — every `advance` success emits an append-only Transition record
  ([FSM-AUDIT](#delivery-fsm-type-system)).
- **GAPLESS-TABLE** — every (State, Signal) pair is enumerated or returns
  `ErrIllegalTransition` (the property test drives every cell of the
  States × Signals matrix, including the universal-Fail and timeout cells).
- **TERMINAL-ABSORBING** — `Verified` + the five fail states accept no signal; only
  `Proxied` and `ProxyTimedOut` are non-terminal waiting states.

#### Rust type sketch

```rust
// crate: module-delivery (mirrors shigoto-gate's pure-FSM idiom).
// Pull-model Go MODULE delivery — proxy.golang.org, NO upload step.
use std::fmt;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum State {
    Drafted, Validated, Tagged,
    Proxied,            // non-terminal: poll-loop on ConfirmProxy
    Verified,           // terminal-ok
    ValidationFailed, TagRejected,
    ProxyTimedOut,      // non-terminal recovery
    VerificationFailed, RolledBack,
}

impl State {
    pub fn is_terminal(self) -> bool {
        matches!(self,
            State::Verified | State::ValidationFailed | State::TagRejected
          | State::VerificationFailed | State::RolledBack)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Signal {
    Validate, Tag, PushTag, ConfirmProxy, Verify, RetryProxy, Reject, Rollback,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct IllegalTransition { pub from: State, pub signal: Signal }

/// A Gate is PURE — it evaluates a captured Snapshot of facts, never doing IO.
pub trait Gate { fn check(&self, snap: &Snapshot) -> bool; fn name(&self) -> &'static str; }

#[derive(Clone, Debug)]
pub struct Snapshot {
    pub working_tree_clean: bool,
    pub head_equals_remote: bool,
    pub module_path: String,
    pub intended_version: semver::Version,
    pub last_tag: Option<semver::Version>,
    pub vet_green: bool, pub test_green: bool, pub build_green: bool,
    pub tag_exists_local: bool, pub tag_exists_remote: bool,
    pub api_breaking: bool,                 // gorelease/apidiff verdict vs last_tag
    pub proxy_status: u16,
    pub proxy_reported_version: Option<semver::Version>,
    pub go_get_ok: bool,
    pub resolved_version: Option<semver::Version>,
    pub sum_zip_present: bool, pub sum_mod_present: bool, pub sumdb_verified: bool,
    pub consumer_build_green: bool,
}

impl Snapshot {
    fn major_suffix_ok(&self) -> bool {
        let n = self.intended_version.major;
        if n < 2 { true } else { self.module_path.ends_with(&format!("/v{n}")) }
    }
    fn strictly_greater(&self) -> bool {
        match &self.last_tag { None => true, Some(p) => self.intended_version > *p }
    }
    fn no_break_without_major(&self) -> bool {
        if !self.api_breaking { return true; }
        match &self.last_tag { None => true, Some(p) => self.intended_version.major > p.major }
    }
}

/// Pure, total, table-driven driver. Every legal cell is enumerated; every other
/// (State, Signal) pair is IllegalTransition (GAPLESS-TABLE invariant).
pub fn advance(from: State, sig: Signal, s: &Snapshot)
    -> Result<State, IllegalTransition>
{
    use {State::*, Signal::*};
    let gated = |ok: bool, to: State, fail: State| Ok(if ok { to } else { fail });
    let val = || s.working_tree_clean && s.head_equals_remote && s.major_suffix_ok()
                 && s.vet_green && s.test_green && s.build_green && s.strictly_greater();
    let tag = || !s.tag_exists_local && !s.tag_exists_remote
                 && s.strictly_greater() && s.major_suffix_ok() && s.no_break_without_major();
    let pubg = || !s.tag_exists_remote && s.major_suffix_ok();
    let proxy = || s.proxy_status == 200
                   && s.proxy_reported_version.as_ref() == Some(&s.intended_version);
    let verify = || s.go_get_ok && s.resolved_version.as_ref() == Some(&s.intended_version)
                    && s.sum_zip_present && s.sum_mod_present && s.sumdb_verified
                    && s.consumer_build_green;
    match (from, sig) {
        (Drafted,       Validate) => gated(val(),   Validated, ValidationFailed),
        (Drafted,       Reject)   => Ok(ValidationFailed),
        (Validated,     Tag)      => gated(tag(),   Tagged, TagRejected),
        (Validated,     Reject)   => Ok(TagRejected),
        (Tagged,        PushTag)  => Ok(if pubg() { Proxied } else { RolledBack }),
        (Tagged,        Rollback) => Ok(RolledBack),
        (Proxied,       ConfirmProxy) => Ok(Proxied), // poll self-loop
        (Proxied,       Verify)   => gated(verify(), Verified, VerificationFailed),
        (Proxied,       Reject)   => Ok(VerificationFailed),
        (Proxied,       Rollback) => Ok(RolledBack),
        (ProxyTimedOut, RetryProxy) => gated(proxy(), Proxied, ProxyTimedOut),
        (ProxyTimedOut, Reject)   => Ok(VerificationFailed),
        (ProxyTimedOut, Rollback) => Ok(RolledBack),
        _ => Err(IllegalTransition { from, signal: sig }), // GAPLESS
    }
}
```

#### Go mirror sketch

```go
// Package moduledelivery is the Go MODULE pull-model delivery FSM, authored in
// the shigoto-go idiom (pure Advance + ErrIllegalTransition, kebab String(),
// IsTerminal(), pure Gate). Pull-model: the only publish side effect is
// `git push origin <tag>` — NO registry upload.
package moduledelivery

import (
	"errors"
	"fmt"
	"strings"

	"golang.org/x/mod/semver" // canonical semver ordering ("v1.5.0")
)

var ErrIllegalTransition = errors.New("module-delivery: illegal FSM transition")

type State int

const (
	Drafted State = iota
	Validated
	Tagged
	Proxied
	Verified           // terminal-ok
	ValidationFailed   // terminal-fail
	TagRejected        // terminal-fail
	ProxyTimedOut      // non-terminal recovery
	VerificationFailed // terminal-fail
	RolledBack         // terminal-fail
)

func (s State) String() string {
	switch s {
	case Drafted:
		return "drafted"
	case Validated:
		return "validated"
	case Tagged:
		return "tagged"
	case Proxied:
		return "proxied"
	case Verified:
		return "verified"
	case ValidationFailed:
		return "validation-failed"
	case TagRejected:
		return "tag-rejected"
	case ProxyTimedOut:
		return "proxy-timed-out"
	case VerificationFailed:
		return "verification-failed"
	case RolledBack:
		return "rolled-back"
	default:
		return fmt.Sprintf("unknown(%d)", int(s))
	}
}

func (s State) IsTerminal() bool {
	switch s {
	case Verified, ValidationFailed, TagRejected, VerificationFailed, RolledBack:
		return true
	default:
		return false
	}
}

type SignalKind int

const (
	SigValidate SignalKind = iota
	SigTag
	SigPushTag
	SigConfirmProxy
	SigVerify
	SigRetryProxy
	SigReject
	SigRollback
)

type Signal struct{ Kind SignalKind }

func Validate() Signal     { return Signal{SigValidate} }
func Tag() Signal          { return Signal{SigTag} }
func PushTag() Signal      { return Signal{SigPushTag} }
func ConfirmProxy() Signal { return Signal{SigConfirmProxy} }
func Verify() Signal       { return Signal{SigVerify} }
func RetryProxy() Signal   { return Signal{SigRetryProxy} }
func Reject() Signal       { return Signal{SigReject} }
func Rollback() Signal     { return Signal{SigRollback} }

// Snapshot is the captured set of typed facts the gates evaluate. It is built by
// the Job/Execute layer (git, go vet/test/build, proxy GET, go get) per the
// shigoto law "a gate that needs IO is an antipattern"; the gates stay pure.
type Snapshot struct {
	WorkingTreeClean                bool
	HeadEqualsRemote                bool
	ModulePath                      string
	IntendedVersion                 string // "v1.5.0"
	LastTag                         string // "" when none
	VetGreen, TestGreen, BuildGreen bool
	TagExistsLocal, TagExistsRemote bool
	APIBreaking                     bool // gorelease/apidiff verdict vs LastTag
	ProxyStatus                     int  // proxy.golang.org .info HTTP status
	ProxyReportedVersion            string
	GoGetOK                         bool
	ResolvedVersion                 string
	SumZipPresent, SumModPresent    bool
	SumDBVerified                   bool
	ConsumerBuildGreen              bool
}

func (s Snapshot) strictlyGreater() bool {
	if s.LastTag == "" {
		return true
	}
	return semver.Compare(s.IntendedVersion, s.LastTag) > 0
}

func (s Snapshot) majorSuffixOK() bool {
	maj := semver.Major(s.IntendedVersion) // "v2"
	if maj == "v0" || maj == "v1" {
		return true
	}
	return strings.HasSuffix(s.ModulePath, "/"+maj)
}

func (s Snapshot) noBreakWithoutMajor() bool {
	if !s.APIBreaking || s.LastTag == "" {
		return true
	}
	return semver.Major(s.IntendedVersion) != semver.Major(s.LastTag)
}

func (s Snapshot) validationGate() bool {
	return s.WorkingTreeClean && s.HeadEqualsRemote && s.majorSuffixOK() &&
		s.VetGreen && s.TestGreen && s.BuildGreen && s.strictlyGreater()
}

func (s Snapshot) tagGate() bool {
	return !s.TagExistsLocal && !s.TagExistsRemote && s.strictlyGreater() &&
		s.majorSuffixOK() && s.noBreakWithoutMajor()
}

func (s Snapshot) publishGate() bool { return !s.TagExistsRemote && s.majorSuffixOK() }

func (s Snapshot) proxyGate() bool {
	return s.ProxyStatus == 200 && s.ProxyReportedVersion == s.IntendedVersion
}

func (s Snapshot) verifyGate() bool {
	return s.GoGetOK && s.ResolvedVersion == s.IntendedVersion &&
		s.SumZipPresent && s.SumModPresent && s.SumDBVerified && s.ConsumerBuildGreen
}

// Advance is the pure, table-driven FSM driver — the exact shigoto-go shape.
// Every legal cell is enumerated; every other (State, Signal) pair returns
// ErrIllegalTransition with the input state unchanged (GAPLESS-TABLE invariant).
func Advance(from State, sig Signal, snap Snapshot) (State, error) {
	gated := func(ok bool, pass, fail State) (State, error) {
		if ok {
			return pass, nil
		}
		return fail, nil
	}
	switch from {
	case Drafted:
		switch sig.Kind {
		case SigValidate:
			return gated(snap.validationGate(), Validated, ValidationFailed)
		case SigReject:
			return ValidationFailed, nil
		}
	case Validated:
		switch sig.Kind {
		case SigTag:
			return gated(snap.tagGate(), Tagged, TagRejected)
		case SigReject:
			return TagRejected, nil
		}
	case Tagged:
		switch sig.Kind {
		case SigPushTag:
			return gated(snap.publishGate(), Proxied, RolledBack)
		case SigRollback:
			return RolledBack, nil
		}
	case Proxied:
		switch sig.Kind {
		case SigConfirmProxy:
			return Proxied, nil // poll self-loop
		case SigVerify:
			return gated(snap.verifyGate(), Verified, VerificationFailed)
		case SigReject:
			return VerificationFailed, nil
		case SigRollback:
			return RolledBack, nil
		}
	case ProxyTimedOut:
		switch sig.Kind {
		case SigRetryProxy:
			return gated(snap.proxyGate(), Proxied, ProxyTimedOut)
		case SigReject:
			return VerificationFailed, nil
		case SigRollback:
			return RolledBack, nil
		}
	}
	// All other cells — including every signal into a terminal state — illegal.
	return from, fmt.Errorf("%w: %s cannot consume kind=%d", ErrIllegalTransition, from, int(sig.Kind))
}
```

---

### Release Delivery (FSM-RELEASE)

**Kinds:** cli, binary. **Publish model:** cross-compiled, checksummed, signed
artifacts attached to a GitHub Release, then a Homebrew formula update —
`Verified` is reached only when the externally-installed binary (via the published
formula) reports `--version` == the release tag (the boundary-of-communication
closed: an outside consumer can install and observe the promised version).

#### Transition table

| From | Signal | Gate | To |
|---|---|---|---|
| Drafted *(start)* | Validate | `TagSemverGate` | Validated |
| Validated | CrossBuild | `CrossMatrixGate` | CrossBuilt |
| CrossBuilt | Scan | `ScanGate` (Pass/Indeterminate) | Scanned / CrossBuilt *(retry)* |
| Scanned | AttachSBOM | `SBOMGate` | SBOMAttached |
| SBOMAttached | Sign | `ChecksumGate` | Signed |
| Signed | AttachProvenance | `ProvenanceGate` | ProvenanceAttested |
| ProvenanceAttested | Release | `SignatureGate` | Released |
| Released | UpdateFormula | `TapReachableGate` | FormulaUpdated |
| Released | ResumeUpload | `AssetsIncompleteGate` | Released *(resume; 1–5 assets)* |
| Released | Rollback | `ReleaseExistsGate` (+RollbackReceipt) | RolledBack *(fail)* |
| FormulaUpdated | Verify | `VersionMatchGate` | Verified *(ok)* |
| FormulaUpdated | Rollback | `FormulaRevertGate` (+RollbackReceipt) | RolledBack *(fail)* |
| *(any non-terminal)* | Fail(reason) | `AlwaysGate` | DeliveryFailed *(fail)* |

States: `Drafted` (start), `Validated`, `CrossBuilt`, `Scanned`, `SBOMAttached`,
`Signed`, `ProvenanceAttested`, `Released`, `FormulaUpdated`, `Verified`
(terminal-ok), `DeliveryFailed`/`RolledBack` (terminal-fail). The `Scan`/
`AttachSBOM`/`AttachProvenance` states realize [SEC-16](#dimension-security-and-supply-chain-sec)
(binary artifacts get an SBOM + scan + provenance, not just a checksum+signature).
`ResumeUpload` repairs a partial Release (1–5 of the ≥6 required assets) instead of
leaving an undefined partial; `Scan` returns to `CrossBuilt` on an Indeterminate
verdict (infra flake, [FSM-TRISTATE](#delivery-fsm-type-system)) rather than a hard
fail. The universal `Fail(reason)` escape is unchanged.

#### Gates

- **`TagSemverGate`** — the tag matches strict SemVer with mandatory `v` prefix and
  no pre-release/build metadata, is annotated + GPG-signed, points at a commit on the
  protected default branch, and does not already exist on the remote. (Restates
  [VER-01](#dimension-versioning-and-compatibility-ver)/[VER-03](#dimension-versioning-and-compatibility-ver).)
- **`CrossMatrixGate`** — every cell of {linux,darwin} × {amd64,arm64} produced
  exactly one non-empty artifact, each built with `CGO_ENABLED=0` (static,
  reproducible). Exactly 4 artifacts, no rogue goos/goarch. (Restates
  [SEC-01](#dimension-security-and-supply-chain-sec).)
- **`ScanGate`** (CrossBuilt→Scanned, [SEC-16](#dimension-security-and-supply-chain-sec)).
  Tri-state: Pass iff a govulncheck/trivy scan over every cross-built binary is
  clean; Indeterminate (scanner crashed/timed out) returns to `CrossBuilt` for retry;
  a genuine finding fails to `DeliveryFailed(BuildError)`.
- **`SBOMGate`** (Scanned→SBOMAttached, [SEC-16](#dimension-security-and-supply-chain-sec)).
  Pass iff a syft SBOM (spdx-json) per artifact is attached to the Release.
- **`ChecksumGate`** (SBOMAttached→Signed) — a `checksums.txt` (SHA-256) covers every
  matrix artifact, recomputed hashes match the manifest, and the build is
  byte-reproducible. The reproducible-digest comparison is precise: the SECOND build
  runs in a CLEAN substrate runner (not the original, not local), and the gate
  compares its digests against a recorded REFERENCE manifest; divergence fails to
  `DeliveryFailed(BuildError)` with a "diff the two build manifests" diagnostic
  (REPRODUCIBLE invariant).
- **`ProvenanceGate`** (Signed→ProvenanceAttested, [SEC-16](#dimension-security-and-supply-chain-sec)/
  [SEC-12](#dimension-security-and-supply-chain-sec)). Pass iff an SLSA provenance
  attestation (builder identity, source digest, materials) is attached to the Release.
- **`SignatureGate`** (ProvenanceAttested→Released) — the checksums manifest is
  cosign/GPG-signed and verifies against the org public key; for cli/binary kinds each
  artifact has a detached verifiable signature.
- **`TapReachableGate`** — the GitHub Release for the tag exists with all 4 artifacts
  + checksums + signature + SBOM + provenance attached (≥8 assets), the Homebrew tap
  repo (`org/homebrew-tap`) is reachable + writable with the release token, and the
  target formula path is resolvable.
- **`AssetsIncompleteGate`** (Released→Released, ResumeUpload) — Pass iff the Release
  exists but carries 1–5 (incomplete) assets; the gate's Job re-uploads the missing
  assets idempotently ([FSM-IDEMPOTENT](#delivery-fsm-type-system)). An incomplete
  Release is NEITHER a clean `Released` NOR a `Fail` — it is a defined resume.
- **`VersionMatchGate`** — the published binary, fetched via the updated formula,
  reports `--version` == the tag (stripped of `v`), and the formula's url/sha256 point
  at the released checksummed artifact.
- **`ReleaseExistsGate`** (Released→RolledBack) — Pass iff a GitHub Release exists and
  the rollback actor holds authority; its POST-CONDITION is precise: the Release is
  retracted/marked-draft and a typed `RollbackReceipt` (release retracted, prior
  moving references restored, reason, severity=error) is emitted.
- **`FormulaRevertGate`** (FormulaUpdated→RolledBack) — distinct from
  `ReleaseExistsGate`: in addition to retracting the Release, its post-condition
  reverts the tap formula's `url`/`sha256` to the prior version and restores moving
  references; emits a `RollbackReceipt` enumerating each undone effect (FSM-RELEASE
  rollback gates now carry receipts, matching FSM-IMAGE).
- **`AlwaysGate`** — unconditional escape hatch; any non-terminal state may transition
  to `DeliveryFailed` when an out-of-band fault is reported (the typed `FailReason`
  rides in the signal).

#### Invariants

- **REPRODUCIBLE** — every CrossBuild is byte-for-byte reproducible
  (`CGO_ENABLED=0`, pinned toolchain, `-trimpath`, fixed
  `-ldflags '-s -w -X main.version={tag}'`, `SOURCE_DATE_EPOCH` from the commit time);
  `ChecksumGate` runs the SECOND build in a clean substrate runner and compares
  against a recorded reference manifest, failing to `DeliveryFailed(BuildError)` with
  a build-manifest diff on divergence.
- **CHECKSUMMED + INVENTORIED** — no artifact leaves CrossBuilt without a SHA-256
  entry, none is Released without the manifest signed+verified AND an SBOM + scan +
  provenance attached ([SEC-16](#dimension-security-and-supply-chain-sec)); the
  Scan → SBOM → Checksum → Provenance → Signature chain is unbypassable.
- **MATRIX-COMPLETE** — the {linux,darwin} × {amd64,arm64} cross-product is total;
  `CrossMatrixGate` rejects any partial matrix.
- **MONOTONIC-FORWARD** — the happy path is strictly linear Drafted → Validated →
  CrossBuilt → Scanned → SBOMAttached → Signed → ProvenanceAttested → Released →
  FormulaUpdated → Verified; the only non-forward edges are ResumeUpload (resume),
  Scan-retry (Indeterminate), Rollback (post-publish only), and Fail.
- **ROLLBACK-AFTER-PUBLISH-ONLY, RECEIPTED** — Rollback is legal only from Released
  (`ReleaseExistsGate`) and FormulaUpdated (`FormulaRevertGate`); pre-publish states
  Fail instead; BOTH rollback gates emit a typed `RollbackReceipt` (Release retracted,
  formula reverted, moving refs restored).
- **PARTIAL-PUBLISH-DEFINED** — an incomplete Release (1–5 assets) is a defined
  `ResumeUpload` state, never an undefined partial; re-issuing `Release` is idempotent
  ([FSM-IDEMPOTENT](#delivery-fsm-type-system)).
- **TAG-IMMUTABLE** — the tag is validated once and is the immutable identity for the
  whole delivery; every later gate re-derives from it.
- **VERIFY-CLOSES-LOOP** — Verified requires the externally-installed binary to report
  `--version` == tag; self-reported build success is never sufficient.
- **AUDITED** — every transition emits an append-only record ([FSM-AUDIT](#delivery-fsm-type-system)).
- **UNIVERSAL-FAIL** — every non-terminal state has a `Fail(reason)` edge
  ([FSM-FAIL](#delivery-fsm-type-system)).
- **TERMINAL-ABSORBING** + **ILLEGAL-IS-NOOP** — terminals accept no signal; any
  unenumerated (state, signal) returns the input state unchanged plus an error.

#### Rust type sketch

```rust
// crate: release-delivery-fsm (mirrors shigoto's typed-FSM idiom)
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeliveryKind { Cli, Binary }

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Drafted, Validated, CrossBuilt, Signed, Released, FormulaUpdated,
    Verified,       // terminal-ok
    DeliveryFailed, // terminal-fail
    RolledBack,     // terminal-fail
}
impl State {
    pub fn is_terminal(self) -> bool {
        matches!(self, State::Verified | State::DeliveryFailed | State::RolledBack)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FailReason { RunnerDied, TokenExpired, NetworkPartition,
                      BuildError, SignError, PublishError, FormulaError, Other }

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Signal {
    Validate, CrossBuild, Sign, Release, UpdateFormula, Verify, Rollback,
    Fail(FailReason),
}

#[derive(Debug)]
pub enum DeliveryError {
    IllegalTransition { from: State, signal: &'static str },
    GateRefused { from: State, signal: &'static str, gate: &'static str },
}

/// PURE precondition over an immutable snapshot. All IO POPULATES the ctx first.
pub trait Gate { fn name(&self) -> &'static str; fn check(&self, c: &DeliveryCtx) -> bool; }

#[derive(Clone, Debug)]
pub struct DeliveryCtx {
    pub kind: DeliveryKind,
    pub tag: String,
    pub tag_is_annotated: bool, pub tag_is_signed: bool,
    pub tag_on_default_branch: bool, pub tag_already_remote: bool,
    pub built_targets: Vec<(&'static str, &'static str)>, // (goos, goarch)
    pub all_cgo_disabled: bool,
    pub reproducible_digest_stable: bool,
    pub checksums_present: bool, pub checksums_cover_all: bool, pub checksums_match: bool,
    pub checksums_signed_and_verified: bool, pub artifacts_sig_verified: bool,
    pub gh_release_published: bool, pub gh_release_asset_count: usize,
    pub tap_reachable: bool, pub tap_token_can_push: bool, pub formula_path_resolvable: bool,
    pub installed_version_matches_tag: bool, pub formula_url_sha_correct: bool,
    pub rollback_actor_authorized: bool,
}

/// Canonical PURE driver. Every legal cell enumerated; all else IllegalTransition.
/// On illegal/refused transition the input state is returned unchanged.
pub fn advance(from: State, sig: Signal, c: &DeliveryCtx) -> Result<State, DeliveryError> {
    use {State::*, Signal::*};
    let kebab = |s: Signal| -> &'static str { match s {
        Validate=>"validate", CrossBuild=>"cross-build", Sign=>"sign", Release=>"release",
        UpdateFormula=>"update-formula", Verify=>"verify", Rollback=>"rollback", Fail(_)=>"fail" } };
    macro_rules! gate { ($ok:expr, $name:literal, $to:expr) => {
        if $ok { Ok($to) } else {
            Err(DeliveryError::GateRefused { from, signal: kebab(sig), gate: $name }) } }; }
    let want4 = [("linux","amd64"),("linux","arm64"),("darwin","amd64"),("darwin","arm64")];
    let cross_ok = c.all_cgo_disabled && c.built_targets.len() == 4
        && want4.iter().all(|t| c.built_targets.contains(t));
    let semver_ok = c.tag_is_annotated && c.tag_is_signed
        && c.tag_on_default_branch && !c.tag_already_remote; // (regex check elided)
    let checksum_ok = c.checksums_present && c.checksums_cover_all
        && c.checksums_match && c.reproducible_digest_stable;
    let sig_ok = c.checksums_signed_and_verified
        && (c.kind == DeliveryKind::Binary || c.artifacts_sig_verified);
    let tap_ok = c.gh_release_published && c.gh_release_asset_count >= 6
        && c.tap_reachable && c.tap_token_can_push && c.formula_path_resolvable;
    let ver_ok = c.installed_version_matches_tag && c.formula_url_sha_correct;
    let rb_ok = c.gh_release_published && c.rollback_actor_authorized;
    match (from, sig) {
        (Drafted,        Validate)      => gate!(semver_ok,   "TagSemverGate",     Validated),
        (Validated,      CrossBuild)    => gate!(cross_ok,    "CrossMatrixGate",   CrossBuilt),
        (CrossBuilt,     Sign)          => gate!(checksum_ok, "ChecksumGate",      Signed),
        (Signed,         Release)       => gate!(sig_ok,      "SignatureGate",     Released),
        (Released,       UpdateFormula) => gate!(tap_ok,      "TapReachableGate",  FormulaUpdated),
        (FormulaUpdated, Verify)        => gate!(ver_ok,      "VersionMatchGate",  Verified),
        (Released,       Rollback)      => gate!(rb_ok,       "ReleaseExistsGate", RolledBack),
        (FormulaUpdated, Rollback)      => gate!(rb_ok,       "ReleaseExistsGate", RolledBack),
        (s, Fail(_)) if !s.is_terminal() => Ok(DeliveryFailed), // AlwaysGate
        (from, sig) => Err(DeliveryError::IllegalTransition { from, signal: kebab(sig) }),
    }
}
```

#### Go mirror sketch

```go
// Package releasedelivery mirrors the FSM-RELEASE machine in the shigoto-go idiom:
// SignalKind enum, Signal struct carrying payload, pure Gate, and one pure
// table-driven Advance(from, sig, ctx).
package releasedelivery

import (
	"errors"
	"fmt"
	"regexp"
)

var (
	ErrIllegalTransition = errors.New("releasedelivery: illegal FSM transition")
	ErrGateRefused       = errors.New("releasedelivery: gate refused transition")
)

type DeliveryKind int

const (
	KindCli DeliveryKind = iota
	KindBinary
)

type State int

const (
	Drafted State = iota
	Validated
	CrossBuilt
	Signed
	Released
	FormulaUpdated
	Verified       // terminal-ok
	DeliveryFailed // terminal-fail
	RolledBack     // terminal-fail
)

func (s State) String() string {
	switch s {
	case Drafted:
		return "drafted"
	case Validated:
		return "validated"
	case CrossBuilt:
		return "cross-built"
	case Signed:
		return "signed"
	case Released:
		return "released"
	case FormulaUpdated:
		return "formula-updated"
	case Verified:
		return "verified"
	case DeliveryFailed:
		return "delivery-failed"
	case RolledBack:
		return "rolled-back"
	default:
		return fmt.Sprintf("unknown(%d)", int(s))
	}
}

func (s State) IsTerminal() bool {
	switch s {
	case Verified, DeliveryFailed, RolledBack:
		return true
	default:
		return false
	}
}

type FailReason int

const (
	FailRunnerDied FailReason = iota
	FailTokenExpired
	FailNetworkPartition
	FailBuildError
	FailSignError
	FailPublishError
	FailFormulaError
	FailOther
)

type SignalKind int

const (
	SigValidate SignalKind = iota
	SigCrossBuild
	SigSign
	SigRelease
	SigUpdateFormula
	SigVerify
	SigRollback
	SigFail
)

type Signal struct {
	Kind   SignalKind
	Reason FailReason // valid when Kind == SigFail
}

func Validate() Signal         { return Signal{Kind: SigValidate} }
func CrossBuild() Signal       { return Signal{Kind: SigCrossBuild} }
func Sign() Signal             { return Signal{Kind: SigSign} }
func Release() Signal          { return Signal{Kind: SigRelease} }
func UpdateFormula() Signal    { return Signal{Kind: SigUpdateFormula} }
func Verify() Signal           { return Signal{Kind: SigVerify} }
func Rollback() Signal         { return Signal{Kind: SigRollback} }
func Fail(r FailReason) Signal { return Signal{Kind: SigFail, Reason: r} }

// DeliveryCtx is the immutable snapshot gates read. POPULATED by side-effecting
// steps BEFORE Advance; gates never do IO.
type DeliveryCtx struct {
	Kind                       DeliveryKind
	Tag                        string
	TagIsAnnotated             bool
	TagIsSigned                bool
	TagOnDefaultBranch         bool
	TagAlreadyRemote           bool
	BuiltTargets               [][2]string // {goos, goarch}
	AllCGODisabled             bool
	ReproducibleDigestStable   bool
	ChecksumsPresent           bool
	ChecksumsCoverAll          bool
	ChecksumsMatch             bool
	ChecksumsSignedAndVerified bool
	ArtifactsSigVerified       bool
	GHReleasePublished         bool
	GHReleaseAssetCount        int
	TapReachable               bool
	TapTokenCanPush            bool
	FormulaPathResolvable      bool
	InstalledVersionMatchesTag bool
	FormulaURLShaCorrect       bool
	RollbackActorAuthorized    bool
}

var semverV = regexp.MustCompile(`^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$`)

func (c DeliveryCtx) tagSemverGate() bool {
	return semverV.MatchString(c.Tag) && c.TagIsAnnotated && c.TagIsSigned &&
		c.TagOnDefaultBranch && !c.TagAlreadyRemote
}

func (c DeliveryCtx) crossMatrixGate() bool {
	want := map[[2]string]bool{
		{"linux", "amd64"}: false, {"linux", "arm64"}: false,
		{"darwin", "amd64"}: false, {"darwin", "arm64"}: false,
	}
	if !c.AllCGODisabled || len(c.BuiltTargets) != 4 {
		return false
	}
	for _, t := range c.BuiltTargets {
		if _, ok := want[t]; !ok {
			return false
		}
		want[t] = true
	}
	for _, seen := range want {
		if !seen {
			return false
		}
	}
	return true
}

func (c DeliveryCtx) checksumGate() bool {
	return c.ChecksumsPresent && c.ChecksumsCoverAll &&
		c.ChecksumsMatch && c.ReproducibleDigestStable
}

func (c DeliveryCtx) signatureGate() bool {
	return c.ChecksumsSignedAndVerified &&
		(c.Kind == KindBinary || c.ArtifactsSigVerified)
}

func (c DeliveryCtx) tapReachableGate() bool {
	return c.GHReleasePublished && c.GHReleaseAssetCount >= 6 &&
		c.TapReachable && c.TapTokenCanPush && c.FormulaPathResolvable
}

func (c DeliveryCtx) versionMatchGate() bool {
	return c.InstalledVersionMatchesTag && c.FormulaURLShaCorrect
}

func (c DeliveryCtx) releaseExistsGate() bool {
	return c.GHReleasePublished && c.RollbackActorAuthorized
}

// Advance is the canonical PURE driver. The universal Fail escape is handled
// first; on an illegal pair the input state is returned unchanged.
func Advance(from State, sig Signal, ctx DeliveryCtx) (State, error) {
	if sig.Kind == SigFail && !from.IsTerminal() {
		return DeliveryFailed, nil // AlwaysGate always passes
	}
	gated := func(ok bool, gate string, to State) (State, error) {
		if ok {
			return to, nil
		}
		return from, fmt.Errorf("%w: gate %s on %s", ErrGateRefused, gate, from)
	}
	switch from {
	case Drafted:
		if sig.Kind == SigValidate {
			return gated(ctx.tagSemverGate(), "TagSemverGate", Validated)
		}
	case Validated:
		if sig.Kind == SigCrossBuild {
			return gated(ctx.crossMatrixGate(), "CrossMatrixGate", CrossBuilt)
		}
	case CrossBuilt:
		if sig.Kind == SigSign {
			return gated(ctx.checksumGate(), "ChecksumGate", Signed)
		}
	case Signed:
		if sig.Kind == SigRelease {
			return gated(ctx.signatureGate(), "SignatureGate", Released)
		}
	case Released:
		switch sig.Kind {
		case SigUpdateFormula:
			return gated(ctx.tapReachableGate(), "TapReachableGate", FormulaUpdated)
		case SigRollback:
			return gated(ctx.releaseExistsGate(), "ReleaseExistsGate", RolledBack)
		}
	case FormulaUpdated:
		switch sig.Kind {
		case SigVerify:
			return gated(ctx.versionMatchGate(), "VersionMatchGate", Verified)
		case SigRollback:
			return gated(ctx.releaseExistsGate(), "ReleaseExistsGate", RolledBack)
		}
	}
	return from, fmt.Errorf("%w: %s cannot consume kind=%d", ErrIllegalTransition, from, int(sig.Kind))
}
```

---

### Image Delivery (FSM-IMAGE)

**Kinds:** daemon, service. **Publish model:** a hardened, signed, SBOM-attested,
CVE-scanned multi-arch OCI image pushed to GHCR by **immutable digest**, then
deployed and verified on a Kubernetes cluster. This machine is the FSM statement of
the whole [Security/Supply-Chain](#dimension-security-and-supply-chain-sec)
dimension: the supply-chain artifacts (signature, SBOM, clean scan) precede the
registry push by construction, not by convention.

#### Transition table

Each progress step has exactly ONE accepted signal whose complementary gate cells
partition the outcome (success-gate `G_x_ok` ⊕ fail-gate `G_x_fail` ⊕
Indeterminate). **The order is cryptographically correct
([SEC-13c](#dimension-security-and-supply-chain-sec)): scan the local tarball, push,
THEN sign/attest by the pushed digest** — signing requires a pushed reference and
scanning must precede push.

| From | Signal | Gate (ok / fail / indeterminate) | To |
|---|---|---|---|
| Drafted *(start)* | Validate | `G_manifest_valid` / `G_manifest_invalid` | Validated / ValidationFailed |
| Validated | BuildImage | `G_image_hardened` / `G_image_not_hardened` | ImageBuilt / ImageBuildFailed |
| ImageBuilt | ScanCVE | `G_cve_under_threshold` / `G_cve_over_threshold` / `G_scan_indeterminate` | CVEGated / CVEGateFailed / ImageBuilt *(retry)* |
| CVEGated | Push | `G_registry_push_ok` / `G_registry_push_fail` | Pushed / PushFailed |
| Pushed | Sign | `G_cosign_present` / `G_cosign_absent` | Signed / SignFailed |
| Signed | AttachSBOM | `G_sbom_attached` / `G_sbom_missing` | SBOMAttached / SBOMFailed |
| SBOMAttached | AttachProvenance | `G_provenance_attested` / `G_provenance_missing` | ProvenanceAttested / ProvenanceFailed |
| ProvenanceAttested | Deploy | `G_apply_accepted` / `G_apply_rejected` | Deployed / DeployFailed |
| Deployed | Verify | `G_readiness_green` / `G_readiness_red` | Verified *(ok)* / VerifyFailed |
| PushFailed | Cleanup | `G_registry_push_reverted` | PushReverted *(fail)* |
| DeployFailed | RetryDeploy | `G_transient_and_budget` | ProvenanceAttested *(retry)* |
| DeployFailed | Rollback | `G_rollback_complete` (ColdRollback if no prior) | RolledBack *(fail)* |
| VerifyFailed | RetryVerify | `G_transient_and_budget` | Deployed *(retry)* |
| VerifyFailed | Rollback | `G_rollback_complete` (ColdRollback if no prior) | RolledBack *(fail)* |
| Verified | Reevaluate | `G_rescan_clean` / `G_rescan_degraded` | Verified / Degraded *(ConMon)* |
| Degraded | Rollback | `G_rollback_complete` | RolledBack *(fail)* |
| *(any non-terminal)* | Fail(reason) | `AlwaysGate` | DeliveryFailed *(fail; RunnerDied/etc.)* |

Terminal-ok: `Verified` (re-evaluable to `Degraded` for ConMon). Terminal-fail:
`ValidationFailed`/`ImageBuildFailed`/`CVEGateFailed`/`PushFailed`(→`PushReverted`)/
`SignFailed`/`SBOMFailed`/`ProvenanceFailed`/`DeployFailed`/`VerifyFailed`/
`RolledBack`/`DeliveryFailed`. Notes on the gaps closed: `PushFailed → Cleanup →
PushReverted` removes orphaned per-arch tags/digests after a partial push (GAP);
`DeployFailed`/`VerifyFailed` gain BOUNDED operator-gated retry edges back to
`ProvenanceAttested`/`Deployed` so a transient cluster fault does not force a full
rebuild of an already-pushed-and-signed digest; `ScanCVE` Indeterminate (trivy
crashed/timed out) returns to `ImageBuilt` for retry instead of becoming a hard CVE
terminal ([FSM-TRISTATE](#delivery-fsm-type-system)); `Verified → Degraded` is the
ConMon re-evaluation edge ([SEC-19](#dimension-security-and-supply-chain-sec)); and a
FIRST deploy (no prior good revision) rolls back as `ColdRollback` (scale-to-zero /
delete workload, nullable to-digest).

#### Gates

- **`G_manifest_valid`** — the DeliveryManifest deserializes from caixa.lisp +
  shikumi YAML, `kind ∈ {daemon, service}`, `registry == "ghcr.io/pleme-io/<repo>"`,
  ≥1 architecture, and the tag scheme is `<arch>-<git-short-sha>` (immutable) +
  `<arch>-latest` (floating) per `service/image-release.nix`. `G_manifest_invalid`
  is its exact complement.
- **`G_image_hardened`** — ALL of: (a) non-root numeric uid > 10000 (default
  `65534:65534`), no setuid ([SEC-03](#dimension-security-and-supply-chain-sec)); (b)
  distroless base == `mkDistrolessBase {withCacert,withTini}`, zero busybox/sh/coreutils
  ([SEC-07](#dimension-security-and-supply-chain-sec)); (c) one OCI manifest per
  declared arch, `CGO_ENABLED=0` static
  ([SEC-01](#dimension-security-and-supply-chain-sec)); (d) entrypoint == `[binary]`
  only. Complement: `G_image_not_hardened`.
- **`G_cosign_present`** / **`G_cosign_absent`** — `cosign verify` resolves a
  signature for the image digest under the keyless Fulcio/Rekor identity and its
  payload digest == the built digest ([SEC-06](#dimension-security-and-supply-chain-sec)).
- **`G_sbom_attached`** / **`G_sbom_missing`** — a syft SBOM attestation
  (`spdx-json`/`cyclonedx-json`) is attached to the image digest as a cosign attest
  predicate with subject-digest == built digest, itself cosign-verifiable
  ([SEC-04](#dimension-security-and-supply-chain-sec)).
- **`G_cve_under_threshold`** / **`G_cve_over_threshold`** / **`G_scan_indeterminate`**
  — a trivy/grype scan over the local TARBALL (pre-push, [SEC-13c](#dimension-security-and-supply-chain-sec))
  yields `count(severity ≥ cveGate.failOn) ≤ cveGate.threshold` (default failOn=HIGH,
  threshold=0, [SEC-05](#dimension-security-and-supply-chain-sec)) after the allowlist
  is subtracted, reproducible against the pinned vuln DB. TRI-STATE: if the scanner
  itself crashed/timed out (the fact was not produced), the verdict is
  `Indeterminate` and routes back to `ImageBuilt` for retry — a trivy crash is NOT a
  CVE finding ([FSM-TRISTATE](#delivery-fsm-type-system)). `G_cve_over_threshold` (a
  genuine finding) is a hard stop.
- **`G_registry_push_ok`** / **`G_registry_push_fail`** — DECOMPOSED so a partial
  push is observable: `images_pushed ∧ manifest_list_created ∧ sha_tag_resolves ∧
  latest_tag_resolves`. Re-running `Push` at the same digest is idempotent (layers are
  digest-immutable, already-pushed layers are no-ops, [FSM-IDEMPOTENT](#delivery-fsm-type-system)).
- **`G_registry_push_reverted`** (PushFailed→PushReverted, Cleanup) — orphaned
  per-arch tags/digests from a partial push are deleted (or proven unreferenced and
  harmless); `PushFailed` is NO LONGER a dead terminal — it has this cleanup edge.
- **`G_cosign_present`** runs AFTER push, binding the signature to the PUSHED digest
  ([SEC-13c](#dimension-security-and-supply-chain-sec)).
- **`G_provenance_attested`** / **`G_provenance_missing`** (SBOMAttached→ProvenanceAttested)
  — an SLSA provenance attestation (builder identity, source digest, materials) is
  attached to the pushed digest, cosign-verifiable ([SEC-12](#dimension-security-and-supply-chain-sec)/
  [SEC-13](#dimension-security-and-supply-chain-sec)). This realizes the previously-missing
  provenance state.
- **`G_apply_accepted`** / **`G_apply_rejected`** — a K8s apply (FluxCD reconcile /
  `kubectl apply`) of the workload referencing the immutable `<arch>-<sha>` digest was
  admitted, AND the admitted object carries the restricted SecurityContext conjunct
  set ([SEC-14](#dimension-security-and-supply-chain-sec): runAsNonRoot, RO-root,
  dropped caps, seccomp, no host namespaces) evaluated by the sekiban/Kyverno
  admission policy; `observedGeneration == metadata.generation`.
- **`G_readiness_green`** / **`G_readiness_red`** — within the typed, lower-bounded
  `shikumi-go` `readinessTimeout` (default `300s`, [SEC-13](#dimension-security-and-supply-chain-sec));
  the timeout is INCLUSIVE → red (a rollout green at exactly-timeout+ε is `VerifyFailed`).
  For `service` all `readyReplicas == desiredReplicas` and every Pod readinessProbe
  green; for `daemon` `numberReady == desiredNumberScheduled`; no CrashLoopBackOff /
  ImagePullBackOff.
- **`G_transient_and_budget`** (DeployFailed→ProvenanceAttested / VerifyFailed→Deployed,
  RetryDeploy/RetryVerify) — Pass iff the fault is transient (API 503 / admission
  flap / transient ImagePullBackOff / slow node scale-up) AND the operator-gated retry
  budget is not exhausted; a bounded retry that abandons NEITHER the pushed-signed
  digest NOR forces a rebuild (mirrors FSM-ACTION's operator-revival pattern).
- **`G_rollback_complete`** — restore the LAST-KNOWN-GOOD immutable digest, replicas
  reconverged, typed `RollbackReceipt` (from-digest, to-digest, reason, severity=error)
  emitted. Precise on first-deploy: if `has_prior_good_revision` is false, rollback is
  a `ColdRollback` — scale-to-zero / delete the workload, `to-digest` is NULL — a
  distinct, defined outcome rather than an undefined "restore the prior digest".
- **`G_rescan_clean`** / **`G_rescan_degraded`** (Verified→Verified / Verified→Degraded,
  Reevaluate) — a scheduled `forge image-rescan` over the DEPLOYED digest re-scores it
  against the threshold; a newly-crossed threshold flags `Degraded` (ConMon,
  [SEC-19](#dimension-security-and-supply-chain-sec)), from which `Rollback` is legal.

#### Invariants

- **MONOTONIC PROGRESS** — the happy path is strictly linear Drafted → Validated →
  ImageBuilt → CVEGated → Pushed → Signed → SBOMAttached → ProvenanceAttested →
  Deployed → Verified ([SEC-13c](#dimension-security-and-supply-chain-sec) order:
  scan → push → sign/attest-by-digest); the only non-forward edges are the bounded
  RetryDeploy/RetryVerify, the ScanCVE Indeterminate retry, Cleanup, the ConMon
  Reevaluate, and Rollback.
- **SCAN-BEFORE-PUSH, SIGN-AFTER-PUSH** — `ScanCVE` is the sole predecessor of `Push`
  (no vulnerable image is ever pushed); `Sign`/`AttachSBOM`/`AttachProvenance` follow
  `Push` and bind to the PUSHED digest (cosign cannot attach to an unpushed ref). A
  property test asserts `Push` precedes `Sign`/`AttachSBOM` and `ScanCVE` precedes
  `Push` ([SEC-13c](#dimension-security-and-supply-chain-sec)).
- **DIGEST IMMUTABILITY** — once ImageBuilt, the sha256 digest is frozen; ScanCVE,
  Push, Sign, AttachSBOM, AttachProvenance, Deploy, Verify all bind to that exact
  digest; deployment ALWAYS references the immutable `<arch>-<git-short-sha>`, the
  floating `<arch>-latest` is convenience-only ([SEC-08](#dimension-security-and-supply-chain-sec)).
- **NO UNSCANNED PUSH, NO UNSIGNED SERVE** — `Push` is unreachable except from
  `CVEGated`; `Deployed` is unreachable except from `ProvenanceAttested` (so a served
  image is always scanned, pushed, signed, SBOM'd, AND provenance-attested). The push
  tool itself refuses a digest lacking a verifiable scan record at push time
  ([SEC-13](#dimension-security-and-supply-chain-sec)). (Restates
  [SEC-04](#dimension-security-and-supply-chain-sec)/[SEC-05](#dimension-security-and-supply-chain-sec)/
  [SEC-06](#dimension-security-and-supply-chain-sec)/[SEC-12](#dimension-security-and-supply-chain-sec).)
- **CVE GATE IS A HARD STOP, SCANNER-FLAKE IS NOT** — a genuine `G_cve_over_threshold`
  finding terminates at `CVEGateFailed`; a scanner crash (`G_scan_indeterminate`)
  retries from `ImageBuilt` and never collapses an infra flake into a CVE terminal
  ([FSM-TRISTATE](#delivery-fsm-type-system)).
- **PARTIAL-PUSH CLEANED UP** — `PushFailed → Cleanup → PushReverted` removes orphaned
  per-arch tags/digests; `PushFailed` is not a dead terminal.
- **TRANSIENT RUNTIME FAULTS RETRY, NOT REBUILD** — `DeployFailed`/`VerifyFailed`
  retry (bounded, operator-gated) to `ProvenanceAttested`/`Deployed`, reusing the
  already-pushed-signed digest, before resorting to Rollback.
- **ROLLBACK CONVERGES TO LAST-GOOD (OR COLD)** — Rollback lands in RolledBack with the
  prior immutable digest restored + RollbackReceipt; on a first deploy with no prior,
  it is a `ColdRollback` (scale-to-zero/delete, null to-digest).
- **CONTINUOUS MONITORING** — `Verified → Degraded` (Reevaluate) lets a deployed digest
  be flagged newly-vulnerable post-deploy ([SEC-19](#dimension-security-and-supply-chain-sec)).
- **PURE FSM, IMPURE EDGES** — `advance` is pure and total; all IO (build, trivy,
  regctl push, cosign, syft, provenance, kubectl apply, readiness poll, rescan) lives
  in the gate cohort and is reduced to a tri-state `GateAggregate` BEFORE `advance`
  ([JOB-11](#dimension-concurrency-and-jobs-job)).
- **PUSH IS A CAS** — `Push` is serialized (single-writer `forge image-release`); a
  digest-exists race is a first-class signal, not a dropped push ([FSM-CAS](#delivery-fsm-type-system)).
- **UNIVERSAL-FAIL** — every non-terminal state has a `Fail(reason)` edge to
  `DeliveryFailed` so runner death mid-step is defined ([FSM-FAIL](#delivery-fsm-type-system)).
- **EVERY TRANSITION IS AUDITED** — each `advance` success emits one append-only
  Transition record (from, signal, gate-aggregate, to, image-digest, severity) to the
  logging-go/errors-go sink; terminal-fail carries severity=error, terminal-ok
  severity=notice. (Now a SHARED property of all four machines, [FSM-AUDIT](#delivery-fsm-type-system).)

#### Rust type sketch

```rust
// crate: pleme-io image-delivery FSM (kinds: Daemon, Service)
// Pure, table-driven advance; all IO confined to the Gate trait + reduced to an aggregate.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind { Daemon, Service }

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum State {
    Drafted, Validated, ImageBuilt, Signed, SBOMAttached, CVEGated, Pushed, Deployed,
    Verified, // terminal-ok
    ValidationFailed, ImageBuildFailed, SignFailed, SBOMFailed, CVEGateFailed,
    PushFailed, DeployFailed, VerifyFailed, RolledBack, // terminal-fail
}
impl State {
    pub fn is_terminal(self) -> bool {
        use State::*;
        matches!(self, Verified | ValidationFailed | ImageBuildFailed | SignFailed
            | SBOMFailed | CVEGateFailed | PushFailed | DeployFailed | VerifyFailed | RolledBack)
    }
    pub fn is_ok(self) -> bool { matches!(self, State::Verified) }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Signal { Validate, BuildImage, Sign, AttachSBOM, ScanCVE, Push, Deploy, Verify, Rollback }

/// Rolled-up outcome of a step's gate cohort (worst wins), produced BEFORE advance.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum GateAggregate { Pass, Fail }

#[derive(thiserror::Error, Debug)]
pub enum FsmError {
    #[error("illegal transition: {0:?} cannot consume {1:?}")]
    IllegalTransition(State, Signal),
}

/// A typed precondition. PURE w.r.t. FSM state; may touch the world to compute its verdict.
pub trait Gate {
    fn check(&self, ctx: &DeliveryCtx) -> Result<bool, anyhow::Error>;
    fn name(&self) -> &'static str;
}

/// Reduce a cohort to one aggregate (any err or any false => Fail; else Pass).
pub fn reduce(results: &[Result<bool, anyhow::Error>]) -> GateAggregate {
    for r in results { match r { Ok(true) => continue, _ => return GateAggregate::Fail } }
    GateAggregate::Pass
}

/// THE table. Every legal (state, signal, aggregate) cell is enumerated;
/// every other pair is IllegalTransition. Pure & total.
pub fn advance(from: State, sig: Signal, g: GateAggregate) -> Result<State, FsmError> {
    use State::*; use Signal::*; use GateAggregate::*;
    let to = match (from, sig, g) {
        (Drafted,      Validate,   Pass) => Validated,
        (Drafted,      Validate,   Fail) => ValidationFailed,
        (Validated,    BuildImage, Pass) => ImageBuilt,
        (Validated,    BuildImage, Fail) => ImageBuildFailed,
        (ImageBuilt,   Sign,       Pass) => Signed,
        (ImageBuilt,   Sign,       Fail) => SignFailed,
        (Signed,       AttachSBOM, Pass) => SBOMAttached,
        (Signed,       AttachSBOM, Fail) => SBOMFailed,
        (SBOMAttached, ScanCVE,    Pass) => CVEGated,
        (SBOMAttached, ScanCVE,    Fail) => CVEGateFailed,
        (CVEGated,     Push,       Pass) => Pushed,
        (CVEGated,     Push,       Fail) => PushFailed,
        (Pushed,       Deploy,     Pass) => Deployed,
        (Pushed,       Deploy,     Fail) => DeployFailed,
        (Deployed,     Verify,     Pass) => Verified,
        (Deployed,     Verify,     Fail) => VerifyFailed,
        // Rollback legal ONLY from the two post-push runtime failures:
        (DeployFailed, Rollback,   _)    => RolledBack,
        (VerifyFailed, Rollback,   _)    => RolledBack,
        (f, s, _) => return Err(FsmError::IllegalTransition(f, s)),
    };
    Ok(to)
}
```

#### Go mirror sketch

```go
// Package imagedelivery is the shigoto-go-style mirror of FSM-IMAGE: int-enum
// States/Signals with String(), a pure table-driven Advance keyed on a pre-reduced
// GateAggregate, ErrIllegalTransition for undefined cells, and a Gate interface
// whose IO is reduced to an aggregate BEFORE Advance is called.
package imagedelivery

import (
	"context"
	"errors"
	"fmt"
)

var ErrIllegalTransition = errors.New("image-delivery: illegal FSM transition")

type Kind int

const (
	Daemon Kind = iota
	Service
)

type State int

const (
	Drafted State = iota
	Validated
	ImageBuilt
	Signed
	SBOMAttached
	CVEGated
	Pushed
	Deployed
	Verified // terminal-ok
	ValidationFailed
	ImageBuildFailed
	SignFailed
	SBOMFailed
	CVEGateFailed
	PushFailed
	DeployFailed
	VerifyFailed
	RolledBack
)

func (s State) String() string {
	switch s {
	case Drafted:
		return "drafted"
	case Validated:
		return "validated"
	case ImageBuilt:
		return "image-built"
	case Signed:
		return "signed"
	case SBOMAttached:
		return "sbom-attached"
	case CVEGated:
		return "cve-gated"
	case Pushed:
		return "pushed"
	case Deployed:
		return "deployed"
	case Verified:
		return "verified"
	case ValidationFailed:
		return "validation-failed"
	case ImageBuildFailed:
		return "image-build-failed"
	case SignFailed:
		return "sign-failed"
	case SBOMFailed:
		return "sbom-failed"
	case CVEGateFailed:
		return "cve-gate-failed"
	case PushFailed:
		return "push-failed"
	case DeployFailed:
		return "deploy-failed"
	case VerifyFailed:
		return "verify-failed"
	case RolledBack:
		return "rolled-back"
	default:
		return fmt.Sprintf("unknown(%d)", int(s))
	}
}

func (s State) IsTerminal() bool {
	switch s {
	case Verified, ValidationFailed, ImageBuildFailed, SignFailed,
		SBOMFailed, CVEGateFailed, PushFailed, DeployFailed,
		VerifyFailed, RolledBack:
		return true
	default:
		return false
	}
}

func (s State) IsOK() bool { return s == Verified }

// GateAggregate is the rolled-up cohort verdict for a step (Pass | Fail); worst wins.
type GateAggregate int

const (
	Pass GateAggregate = iota
	Fail
)

type SignalKind int

const (
	SigValidate SignalKind = iota
	SigBuildImage
	SigSign
	SigAttachSBOM
	SigScanCVE
	SigPush
	SigDeploy
	SigVerify
	SigRollback
)

// Signal carries the step discriminant plus its pre-reduced gate verdict, keeping
// Advance pure (no IO) — exactly shigoto's Signal.Gate split.
type Signal struct {
	Kind SignalKind
	Gate GateAggregate
}

func Validate(g GateAggregate) Signal   { return Signal{SigValidate, g} }
func BuildImage(g GateAggregate) Signal { return Signal{SigBuildImage, g} }
func Sign(g GateAggregate) Signal       { return Signal{SigSign, g} }
func AttachSBOM(g GateAggregate) Signal { return Signal{SigAttachSBOM, g} }
func ScanCVE(g GateAggregate) Signal    { return Signal{SigScanCVE, g} }
func Push(g GateAggregate) Signal       { return Signal{SigPush, g} }
func Deploy(g GateAggregate) Signal     { return Signal{SigDeploy, g} }
func Verify(g GateAggregate) Signal     { return Signal{SigVerify, g} }
func Rollback() Signal                  { return Signal{SigRollback, Pass} }

// Gate mirrors shigoto.Gate: a pure-w.r.t.-FSM precondition whose Check may touch
// the world (cosign/syft/trivy/regctl/kubectl).
type Gate interface {
	Check(ctx context.Context) (bool, error)
	Name() string
}

// Reduce rolls a cohort to Pass|Fail: any error or any false => Fail.
func Reduce(pass []bool, errs []error) GateAggregate {
	for i := range pass {
		if i < len(errs) && errs[i] != nil {
			return Fail
		}
		if !pass[i] {
			return Fail
		}
	}
	return Pass
}

// passFail selects the success or failure target from a gate aggregate.
func passFail(g GateAggregate, ok, bad State) State {
	if g == Pass {
		return ok
	}
	return bad
}

// Advance is the pure, total FSM driver. Every legal (State, SignalKind,
// GateAggregate) cell is enumerated; every other pair returns ErrIllegalTransition
// with the input state unchanged.
func Advance(from State, sig Signal) (State, error) {
	switch from {
	case Drafted:
		if sig.Kind == SigValidate {
			return passFail(sig.Gate, Validated, ValidationFailed), nil
		}
	case Validated:
		if sig.Kind == SigBuildImage {
			return passFail(sig.Gate, ImageBuilt, ImageBuildFailed), nil
		}
	case ImageBuilt:
		if sig.Kind == SigSign {
			return passFail(sig.Gate, Signed, SignFailed), nil
		}
	case Signed:
		if sig.Kind == SigAttachSBOM {
			return passFail(sig.Gate, SBOMAttached, SBOMFailed), nil
		}
	case SBOMAttached:
		if sig.Kind == SigScanCVE {
			return passFail(sig.Gate, CVEGated, CVEGateFailed), nil
		}
	case CVEGated:
		if sig.Kind == SigPush {
			return passFail(sig.Gate, Pushed, PushFailed), nil
		}
	case Pushed:
		if sig.Kind == SigDeploy {
			return passFail(sig.Gate, Deployed, DeployFailed), nil
		}
	case Deployed:
		if sig.Kind == SigVerify {
			return passFail(sig.Gate, Verified, VerifyFailed), nil
		}
	// Rollback legal ONLY from the two post-push runtime failures.
	case DeployFailed, VerifyFailed:
		if sig.Kind == SigRollback {
			return RolledBack, nil
		}
	}
	return from, fmt.Errorf("%w: %s cannot consume kind=%d", ErrIllegalTransition, from, int(sig.Kind))
}
```

---

### Action Delivery (FSM-ACTION)

**Kinds:** github-action. **Publish model:** a typed input/output contract → a
cross-built Go binary → a rendered `action.yml` → a tagged GitHub Release (binary
assets + `action.yml`) → a smoke-test against the immutable released ref. The
keystone is **single-source contract**: the `action.yml` input/output surface and
the Go binary's `INPUT_`/`OUTPUT` surface derive from ONE typed declaration
([NAME-12](#dimension-naming-name)). Adds an operator-revival path
(Failed → WaitingForOperator → Drafted), mirroring shigoto's Deadlettered→Pending
operator-only revival ([JOB-14](#dimension-concurrency-and-jobs-job)).

#### Transition table

| From | Signal | Gate | To |
|---|---|---|---|
| Drafted *(start)* | Validate | `G_ContractTyped` | Validated |
| Drafted | Fail | `G_FailureObserved` | Failed *(fail, revivable)* |
| Validated | BuildBinary | `G_BinaryCrossBuilt` | BinaryBuilt |
| Validated | Fail | `G_FailureObserved` | Failed |
| BinaryBuilt | RenderActionYml | `G_ActionYmlMatchesContract` | ActionYmlRendered |
| BinaryBuilt | Fail | `G_FailureObserved` | Failed |
| ActionYmlRendered | Release | `G_TagPresentAndAssetsUploaded` | Released |
| ActionYmlRendered | Fail | `G_FailureObserved` | Failed |
| Released | Verify | `G_PinnedRefResolvesAndRuns` | Verified |
| Released | Rollback | `G_RollbackComplete` | RolledBack *(fail)* |
| Released | Fail | `G_FailureObserved` | Failed |
| Verified | PromoteMajorTag | `G_MajorTagPromoted` | Promoted *(ok)* |
| Verified | Rollback | `G_RollbackComplete` | RolledBack *(fail)* |
| Failed | Rollback | `G_RollbackComplete` | RolledBack *(fail)* |
| Failed | OperatorRetry | `G_OperatorAuthorized` | WaitingForOperator |
| WaitingForOperator | OperatorRetry | `G_OperatorAuthorized` (+ResetFacts) | Drafted |
| WaitingForOperator | OperatorAbandon | `G_RollbackComplete` | RolledBack *(fail)* |

Terminal-ok: `Promoted`. Terminal-fail: `RolledBack`. `Failed` is revivable (the
Deadlettered analog); `WaitingForOperator` is an operator pause. KEY FIX
([SEC-13c](#dimension-security-and-supply-chain-sec)-analog for actions): the moving
major tag (e.g. `v1`) is force-updated to the new tag ONLY at `PromoteMajorTag`,
AFTER `Verify` — so consumers pinned to `@v1` never get an UNVERIFIED release. The
prior `v1` target SHA is captured at Release time so `G_RollbackComplete` can revert
the major tag to exactly that SHA. `Verified` is no longer the terminal-ok; it is a
verified-but-not-yet-promoted state, and `Promoted` is the terminal-ok.

#### Gates

- **`G_ContractTyped`** — the action's Inputs/Outputs are ONE
  `pleme-actions-shared-go`-typed struct: every exported field carries an
  `input:"<kebab-name>[,required]"` tag (parseable by `actions.ParseInputs`), every
  produced output is registered and eventually emitted via `actions.SetOutput`, the
  declared output set exactly equals the names passed to `SetOutput` (no orphan, no
  missing), and the InputStruct round-trips over synthetic `INPUT_*` env without
  error. (Realizes [NAME-12](#dimension-naming-name).)
- **`G_BinaryCrossBuilt`** — the Go binary built for every target in `systems`
  (default `[aarch64-darwin, x86_64-darwin, x86_64-linux, aarch64-linux]` per
  `action-release-flake.nix`) via `tool-release-flake.nix`, with `vendorHash` a
  concrete sha256 (not a placeholder) and version ldflags injected; each artifact's
  GOOS/GOARCH matches its target. PURE over the recorded BuildManifest.
- **`G_ActionYmlMatchesContract`** — the rendered `action.yml` is byte-equivalent to a
  re-render from the SAME typed contract, AND its env/outputs wiring is isomorphic to
  the binary's INPUT_/OUTPUT surface: each input maps to
  `INPUT_<UPPER_UNDERSCORE(name)>: ${{ inputs.<name> }}` (the
  `actions.inputEnvName` transform), the INPUT_* key set equals the tagged-field set,
  each output is wired `outputs.<o>.value == ${{ steps.run.outputs.<o> }}` with `o` in
  the declared set, NO `${{ inputs.* }}` appears inside any `run:` body (injection-
  safe — all inputs hoisted to env), and the committed `action.yml` equals the
  `nix build .#action-yml` output.
- **`G_TagPresentAndAssetsUploaded`** — a semver tag matching `^v\d+\.\d+\.\d+$`
  points at the validated commit, and a published GH Release is bound to it carrying
  one asset per cross-built target (checksum-matched) plus the `action.yml` asset.
  The moving major-version tag (e.g. `v1`) is NOT touched here — its prior target SHA
  is CAPTURED into the snapshot (`prior_major_tag_sha`) so promotion and rollback can
  reason about it. The major tag is promoted only at `PromoteMajorTag` (post-Verify),
  closing the gap where `@v1` consumers received an unverified release.
- **`G_PinnedRefResolvesAndRuns`** — a smoke-test workflow referencing the action by
  its IMMUTABLE released ref (full commit SHA or the just-published tag) resolves, the
  binary parses every `INPUT_*` without a missing-required error, each declared output
  appears with the expected value (written to `GITHUB_OUTPUT`), the step exits 0 with
  no `::error::` workflow-command, and the resolved `action.yml` at the tag equals the
  verified-contract `action.yml`.
- **`G_MajorTagPromoted`** (Verified→Promoted) — the moving major tag is force-updated
  to the VERIFIED tag (only now), and the snapshot records that the prior target was
  `prior_major_tag_sha` so a later rollback (from `Verified`) can revert it exactly.
- **`G_FailureObserved`** — PURE; passes once a typed FailureRecord exists with a Cause
  in `{ValidationFailed, CrossBuildFailed, RenderMismatch, ReleasePublishFailed,
  VerifyFailed}` whose `FromState` == the state emitting Fail (never fail silently).
- **`G_RollbackComplete`** — every side effect up to the failing state is provably
  undone (tag + Release deleted, working-tree `action.yml` restored) AND, if the major
  tag was promoted, it is reverted to EXACTLY the captured `prior_major_tag_sha` (the
  gate asserts the revert target, which the prior FSM could not because it recorded no
  prior SHA); a `RollbackReceipt` enumerates each undone effect; built-binary Nix store
  paths need not be GC'd (immutable, content-addressed, harmless).
- **`G_OperatorAuthorized`** (+ ResetFacts on the `WaitingForOperator → Drafted` edge)
  — an authenticated operator decision (recognized release-owner principal, `Intent ==
  Retry`, bound to the active FailureRecord) authorizes re-attempt; the revival edge
  into `Drafted` RESETS the captured Facts to a fresh snapshot (clears stale
  `Failure`/`TagAndAssets`/`RollbackComplete`) and forces a re-`Validate` against the
  current working tree — a revived delivery cannot pass `G_FailureObserved` on a stale
  `Failure` or skip re-validation. (Mirrors shigoto `SigOperatorTransition` gating.)

#### Invariants

- **I1 Single-source contract** — the `action.yml` input/output surface and the Go
  binary's INPUT_/OUTPUT surface derive from ONE typed declaration; no reachable
  state may hold a half-updated contract (`G_ContractTyped` +
  `G_ActionYmlMatchesContract` make divergence unreachable). (Realizes
  [NAME-12](#dimension-naming-name).)
- **I2 Monotonic forward progress** — Drafted → Validated → BinaryBuilt →
  ActionYmlRendered → Released → Verified → Promoted is the ONLY accepting path; you
  cannot Release without BinaryBuilt AND ActionYmlRendered behind you, and you cannot
  Promote the moving major tag without Verify behind you.
- **I3 No release before proof of build + contract** — `G_TagPresentAndAssetsUploaded`
  is satisfiable only when a BuildManifest and a matched `action.yml` exist, so a tag
  is never pushed for an unbuildable or contract-divergent commit.
- **I3a Major tag promoted only post-Verify** — `@v1` is repointed ONLY at
  `PromoteMajorTag` (after `Verify`); consumers pinned to a moving major never receive
  an unverified release, and the prior major SHA is captured for exact rollback.
- **I4 Immutability of a PROMOTED release** — once `Promoted`, NO signal is legal; a
  new delivery uses a new tag (fresh FSM from Drafted). `Verified` (pre-promotion) is
  still rollback-able.
- **I5 Total failure reachability** — every non-terminal pre-Verified state has a Fail
  edge to Failed; failure is never a stuck state (UNIVERSAL-FAIL).
- **I5a Fact reset on revival** — the `WaitingForOperator → Drafted` revival edge
  resets the captured Facts and forces re-Validate; a revived run never reuses stale
  facts ([FSM-RESET](#delivery-fsm-type-system)).
- **I6 Rollback restores the world** — any path to RolledBack guarantees (via
  `G_RollbackComplete`) all tags/releases/file mutations are undone AND the major tag
  is reverted to the captured `prior_major_tag_sha`; RolledBack is observationally ≤
  Drafted.
- **I7 Operator-gated revival only** — the ONLY way to re-attempt after Failed is
  through `G_OperatorAuthorized` (Failed → WaitingForOperator → Drafted); the automatic
  FSM never silently retries.
- **I8 Gate purity** — every gate is a PURE predicate over recorded typed facts
  (BuildManifest, RenderedActionYml, ReleaseManifest, SmokeReceipt, FailureRecord,
  OperatorDecision); all IO happens INSIDE the Job that emits the fact
  ([JOB-11](#dimension-concurrency-and-jobs-job)).
- **I9 Injection-safety is structural** — no reachable Released/Verified state can
  carry an `action.yml` interpolating `${{ inputs.* }}` inside a `run:` body
  (`G_ActionYmlMatchesContract` forbids it), so every input reaches the binary only as
  an `INPUT_*` env var.
- **I10 Determinism of advance** — `advance(from, signal)` is pure and total; every
  unenumerated (state, signal) returns `ErrIllegalTransition` with the input state
  unchanged.

#### Rust type sketch

```rust
// crate: pleme-action-delivery-fsm (mirrors shigoto's advance-table discipline)
use thiserror::Error;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum State {
    Drafted, Validated, BinaryBuilt, ActionYmlRendered, Released,
    Verified,           // terminal-ok
    Failed,             // terminal-fail (operator-revivable)
    RolledBack,         // terminal-fail
    WaitingForOperator, // operator pause
}
impl State {
    pub fn is_terminal(self) -> bool { matches!(self, State::Verified | State::RolledBack) }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum FailureCause {
    ValidationFailed, CrossBuildFailed, RenderMismatch, ReleasePublishFailed, VerifyFailed,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum OperatorIntent { Retry, Abandon }

/// Signals carry the typed facts the gates inspect (the FSM stays pure).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Signal {
    Validate, BuildBinary, RenderActionYml, Release, Verify,
    Fail(FailureCause), Rollback, Operator(OperatorIntent),
}

#[derive(Debug, Error)]
pub enum AdvanceError {
    #[error("illegal transition: {from:?} cannot consume {signal:?}")]
    Illegal { from: State, signal: Signal },
    #[error("gate {gate} refused the transition {from:?} -> {to:?}")]
    GateRefused { gate: &'static str, from: State, to: State },
}

/// Ctx holds the recorded facts each Job emitted; gates read it, never act.
pub struct Ctx {
    pub contract_typed: bool,
    pub binary_cross_built: bool,
    pub action_yml_matches: bool,
    pub tag_and_assets: bool,
    pub pinned_ref_runs: bool,
    pub failure: Option<FailureCause>,
    pub rollback_complete: bool,
    pub operator_authorized: bool,
}

/// Canonical pure FSM driver — total over (State, Signal); every legal cell
/// enumerated, all else AdvanceError::Illegal. Mirrors shigoto-go Advance.
pub fn advance(from: State, sig: Signal, ctx: &Ctx) -> Result<State, AdvanceError> {
    use State::*; use Signal::*;
    fn step(from: State, to: State, name: &'static str, ok: bool)
        -> Result<State, AdvanceError> {
        if ok { Ok(to) } else { Err(AdvanceError::GateRefused { gate: name, from, to }) }
    }
    match (from, sig) {
        // happy path
        (Drafted,           Validate)        => step(from, Validated,         "G_ContractTyped",                ctx.contract_typed),
        (Validated,         BuildBinary)     => step(from, BinaryBuilt,       "G_BinaryCrossBuilt",             ctx.binary_cross_built),
        (BinaryBuilt,       RenderActionYml) => step(from, ActionYmlRendered, "G_ActionYmlMatchesContract",     ctx.action_yml_matches),
        (ActionYmlRendered, Release)         => step(from, Released,          "G_TagPresentAndAssetsUploaded",  ctx.tag_and_assets),
        (Released,          Verify)          => step(from, Verified,          "G_PinnedRefResolvesAndRuns",     ctx.pinned_ref_runs),
        // failure from every pre-Verified non-terminal state
        (Drafted | Validated | BinaryBuilt | ActionYmlRendered | Released, Fail(_)) =>
            step(from, Failed, "G_FailureObserved", ctx.failure.is_some()),
        // rollback
        (Released | Failed, Rollback) =>
            step(from, RolledBack, "G_RollbackComplete", ctx.rollback_complete),
        // operator revival / abandon
        (Failed,             Operator(OperatorIntent::Retry)) =>
            step(from, WaitingForOperator, "G_OperatorAuthorized", ctx.operator_authorized),
        (WaitingForOperator, Operator(OperatorIntent::Retry)) =>
            step(from, Drafted, "G_OperatorAuthorized", ctx.operator_authorized),
        (WaitingForOperator, Operator(OperatorIntent::Abandon)) =>
            step(from, RolledBack, "G_RollbackComplete", ctx.rollback_complete),
        // everything else (terminals Verified/RolledBack incl.) is illegal
        _ => Err(AdvanceError::Illegal { from, signal: sig }),
    }
}
```

#### Go mirror sketch

```go
// Package actiondelivery mirrors FSM-ACTION in the shigoto-go phase.go/signal.go/
// gate.go style: int-enum State, SignalKind + payload, pure facts-backed gates,
// and one pure table-driven Advance.
package actiondelivery

import (
	"errors"
	"fmt"
)

var ErrIllegalTransition = errors.New("actiondelivery: illegal transition")

type DeliveryState int

const (
	Drafted DeliveryState = iota
	Validated
	BinaryBuilt
	ActionYmlRendered
	Released
	Verified
	Failed
	RolledBack
	WaitingForOperator
)

func (s DeliveryState) String() string {
	switch s {
	case Drafted:
		return "drafted"
	case Validated:
		return "validated"
	case BinaryBuilt:
		return "binary-built"
	case ActionYmlRendered:
		return "action-yml-rendered"
	case Released:
		return "released"
	case Verified:
		return "verified"
	case Failed:
		return "failed"
	case RolledBack:
		return "rolled-back"
	case WaitingForOperator:
		return "waiting-for-operator"
	default:
		return fmt.Sprintf("unknown(%d)", int(s))
	}
}

// IsTerminal: Verified and RolledBack admit no further automatic transition;
// Failed is operator-revivable (like Deadlettered).
func (s DeliveryState) IsTerminal() bool {
	return s == Verified || s == RolledBack
}

type SignalKind int

const (
	SigValidate SignalKind = iota
	SigBuildBinary
	SigRenderActionYml
	SigRelease
	SigVerify
	SigFail
	SigRollback
	SigOperator
)

type FailureCause int

const (
	ValidationFailed FailureCause = iota
	CrossBuildFailed
	RenderMismatch
	ReleasePublishFailed
	VerifyFailed
)

type OperatorIntent int

const (
	OpRetry OperatorIntent = iota
	OpAbandon
)

// Signal carries the discriminant + payload; build via constructors.
type Signal struct {
	Kind   SignalKind
	Cause  FailureCause   // valid when Kind == SigFail
	Intent OperatorIntent // valid when Kind == SigOperator
}

func Validate() Signal                  { return Signal{Kind: SigValidate} }
func BuildBinary() Signal               { return Signal{Kind: SigBuildBinary} }
func RenderActionYml() Signal           { return Signal{Kind: SigRenderActionYml} }
func Release() Signal                   { return Signal{Kind: SigRelease} }
func Verify() Signal                    { return Signal{Kind: SigVerify} }
func Fail(c FailureCause) Signal        { return Signal{Kind: SigFail, Cause: c} }
func Rollback() Signal                  { return Signal{Kind: SigRollback} }
func Operator(i OperatorIntent) Signal  { return Signal{Kind: SigOperator, Intent: i} }

// Facts holds the typed facts each Job emitted; gates read it, never do IO.
type Facts struct {
	ContractTyped      bool          // G_ContractTyped
	BinaryCrossBuilt   bool          // G_BinaryCrossBuilt
	ActionYmlMatches   bool          // G_ActionYmlMatchesContract
	TagAndAssets       bool          // G_TagPresentAndAssetsUploaded
	PinnedRefRuns      bool          // G_PinnedRefResolvesAndRuns
	Failure            *FailureCause // G_FailureObserved (nil == none)
	RollbackComplete   bool          // G_RollbackComplete
	OperatorAuthorized bool          // G_OperatorAuthorized
}

// gateFor returns (gateName, satisfied) for a (from, signal) edge; pure, no IO.
func gateFor(sig Signal, f *Facts) (string, bool) {
	switch sig.Kind {
	case SigValidate:
		return "G_ContractTyped", f.ContractTyped
	case SigBuildBinary:
		return "G_BinaryCrossBuilt", f.BinaryCrossBuilt
	case SigRenderActionYml:
		return "G_ActionYmlMatchesContract", f.ActionYmlMatches
	case SigRelease:
		return "G_TagPresentAndAssetsUploaded", f.TagAndAssets
	case SigVerify:
		return "G_PinnedRefResolvesAndRuns", f.PinnedRefRuns
	case SigFail:
		return "G_FailureObserved", f.Failure != nil
	case SigRollback:
		return "G_RollbackComplete", f.RollbackComplete
	case SigOperator:
		if sig.Intent == OpAbandon {
			return "G_RollbackComplete", f.RollbackComplete
		}
		return "G_OperatorAuthorized", f.OperatorAuthorized
	default:
		return "G_Unknown", false
	}
}

// target enumerates the legal transition table (the only accepting edges).
func target(from DeliveryState, sig Signal) (DeliveryState, bool) {
	switch from {
	case Drafted:
		switch sig.Kind {
		case SigValidate:
			return Validated, true
		case SigFail:
			return Failed, true
		}
	case Validated:
		switch sig.Kind {
		case SigBuildBinary:
			return BinaryBuilt, true
		case SigFail:
			return Failed, true
		}
	case BinaryBuilt:
		switch sig.Kind {
		case SigRenderActionYml:
			return ActionYmlRendered, true
		case SigFail:
			return Failed, true
		}
	case ActionYmlRendered:
		switch sig.Kind {
		case SigRelease:
			return Released, true
		case SigFail:
			return Failed, true
		}
	case Released:
		switch sig.Kind {
		case SigVerify:
			return Verified, true
		case SigRollback:
			return RolledBack, true
		case SigFail:
			return Failed, true
		}
	case Failed:
		switch sig.Kind {
		case SigRollback:
			return RolledBack, true
		case SigOperator:
			if sig.Intent == OpRetry {
				return WaitingForOperator, true
			}
		}
	case WaitingForOperator:
		if sig.Kind == SigOperator {
			switch sig.Intent {
			case OpRetry:
				return Drafted, true
			case OpAbandon:
				return RolledBack, true
			}
		}
	}
	// Verified, RolledBack and all unlisted pairs are illegal.
	return from, false
}

// Advance is the canonical pure FSM driver. Every legal (state, signal) cell is
// enumerated via target(); every other pair returns ErrIllegalTransition with the
// input state unchanged. A structurally-legal edge whose gate refuses also leaves
// the state unchanged (gate-and-table agree).
func Advance(from DeliveryState, sig Signal, f *Facts) (DeliveryState, error) {
	to, legal := target(from, sig)
	if !legal {
		return from, fmt.Errorf("%w: %s cannot consume kind=%d", ErrIllegalTransition, from, int(sig.Kind))
	}
	name, ok := gateFor(sig, f)
	if !ok {
		return from, fmt.Errorf("%w: gate %s refused %s -> %s", ErrIllegalTransition, name, from, to)
	}
	return to, nil
}
```

---

## Appendix: ID normalization map

The enumerated source material used heterogeneous ID schemes; the GSDS normalizes
each dimension to one prefix. The mapping (source → canonical) is:

| Source prefix / scheme | Canonical prefix |
|---|---|
| `RLM-01..12` | `LAYOUT-01..12` |
| `NAM-01..13` | `NAME-01..13` |
| `cli-ux-01..12-*` (slug form) | `CLI-01..13` |
| `CFG-001..014` | `CFG-01..15` |
| `OBS-01..14` | `OBS-01..14` (unchanged) |
| `ERR-01..12` | `ERR-01..12` (unchanged) |
| `LH-01..14` | `LIFE-01..16` |
| `NET-01..13` | `NET-01..14` |
| `CJ-01..14` | `JOB-01..14` |
| `DOC-01..10` | `DOC-01..20` |
| `VER-01..12` | `VER-01..17` |
| `TQ-01..12` | `TEST-01..12` |
| `SEC-01..12` | `SEC-01..19` |
| (new dimension — no source prefix) | `UI-01..12` |
| FSM cases `module-delivery` / `release-delivery` / `image-delivery` / `action-delivery` | `FSM-MODULE` / `FSM-RELEASE` / `FSM-IMAGE` / `FSM-ACTION` |
| FSM shared invariants | `FSM-AUDIT` / `FSM-TRISTATE` / `FSM-FAIL` / `FSM-RESET` / `FSM-IDEMPOTENT` / `FSM-CAS` / `FSM-OBS` |

All cross-references in this document and every entry in
[`rules-registry.yaml`](./rules-registry.yaml) use the canonical IDs. The standalone
typed FSM spec is [`go-delivery-fsms.md`](./go-delivery-fsms.md).

---

## Conformance Checklist

Every rule as a checkable item. A repo is GSDS-conformant iff `nix run .#check-all`
and the four delivery FSM gates pass, which mechanically asserts every box below.
`caixa-validate --conformance` emits this list with pass/fail per item.

### Repo layout and module (LAYOUT)
- [ ] LAYOUT-01 module path `github.com/pleme-io/<slug>` (`-go` suffix preserved)
- [ ] LAYOUT-02 `go` directive pins MINOR only, not ahead of the toolchain
- [ ] LAYOUT-03 `cmd/`/`internal/`/`pkg/` placement is mechanical and correct
- [ ] LAYOUT-04 six required top-level files present, non-empty, canonical (LICENSE == MIT)
- [ ] LAYOUT-05 no `.goreleaser.yml`; release is tag-only via substrate
- [ ] LAYOUT-06 `flake.nix` consumes the matching substrate Go helper, no raw `buildGoModule`
- [ ] LAYOUT-07 CI is the generated `auto-release.yml` shim; `run:` ≤3 lines; explicit minimal `permissions:` (SEC-18)
- [ ] LAYOUT-08 single- vs multi-binary layout matches `:kind`/`:ecosystem`
- [ ] LAYOUT-09 `caixa.lisp` declares a valid `:kind` + Go `:ecosystem`
- [ ] LAYOUT-10 `go.sum` complete; only the 8 first-party libs; no local re-impl
- [ ] LAYOUT-11 one canonical name, byte-identical across every surface
- [ ] LAYOUT-12 no `vendor/`; deps via proxy + `go.sum` + `vendorHash`

### Naming (NAME)
- [ ] NAME-01..13 module/package/file/command/env/key/identifier naming + initialism caps

### CLI UX (CLI)
- [ ] CLI-01..12 cli-go App/Command model, kebab verbs, version, globals, precedence, render, exit shim
- [ ] CLI-13 flag/subcommand rename/removal is MAJOR + hidden `DeprecatedAlias` for ≥1 minor

### Configuration (CFG)
- [ ] CFG-01..14 shikumi-go-only typed config, fixed precedence, SecretRef, Validate, reload classes, bootstrap order
- [ ] CFG-15 `schema_version` + forward migration; no silent field-loss on upgrade

### Observability (OBS)
- [ ] OBS-01..14 one logging-go logger, JSON/stdout, levels, correlation/tenant, context, severity, otel bridge

### Errors (ERR)
- [ ] ERR-01..12 errors-go everywhere, Err-prefixed codes, severity, wrap discipline, exit codes, boundary classification

### Lifecycle and health (LIFE)
- [ ] LIFE-01..14 SignalContext, Shutdown order, probes, RunLoop, graceful stop
- [ ] LIFE-15 canonical ports `:8081` `/healthz` `/readyz` `/metrics`
- [ ] LIFE-16 README `## Usage` runnable `nix run .#<app> --` recipe

### Networking (NET)
- [ ] NET-01..13 todoku-go client, retry/idempotency, ctx, timeouts, auth, health, middleware order
- [ ] NET-14 TLS MinVersion ≥1.2; no `InsecureSkipVerify`; no weak crypto/`math/rand`

### Concurrency and jobs (JOB)
- [ ] JOB-01..14 shigoto-go DAG/scheduler, stable JobIDs, pure gates, idempotent Execute, deadletter, audit

### Documentation and discoverability (DOC)
- [ ] DOC-01..10 godoc, examples, README shape, CHANGELOG, pkg.go.dev (MIT), Built-on, navigate-test, no-shell doc tooling
- [ ] DOC-11 canonical example repos exist and pass (no dead `Demonstrated by:`)
- [ ] DOC-12 Glossary present and complete
- [ ] DOC-13 role-based reading on-ramp present
- [ ] DOC-14 Identity-derivation table present; `caixa-validate` derives from it
- [ ] DOC-15 Concern → library → symbol map present
- [ ] DOC-16 inter-library composition graph present + acyclic + matches LIFE-12
- [ ] DOC-17 gate-triage table (analyzers + FSM verdicts) present
- [ ] DOC-18 generated-file sentinel + authored/generated manifest + regenerate loop
- [ ] DOC-19 Tunables & defaults appendix present
- [ ] DOC-20 annotation/escape-hatch catalog present; unknown `//gsds:` rejected

### Versioning and compatibility (VER)
- [ ] VER-01..10 strict semver, /vN suffix, immutable tags, tag-as-version, stability, crossover, deprecation, notes, pre-release, go.mod (+ go.work + toolchain)
- [ ] VER-04a version-injection target declared (`:version-package`)
- [ ] VER-11a single-module multi-binary monorepo (one go.mod, one version)
- [ ] VER-11b true multi-module repo (N go.mod, path-prefixed tags)
- [ ] VER-12 Tagged ⟺ tag exists (FSM coupling)
- [ ] VER-13 consumer upgrade is `forge tool upgrade`; no two-major diamond
- [ ] VER-14 bad version repudiated by `retract`, never tag deletion
- [ ] VER-15 fleet major upgrade propagates root→leaf
- [ ] VER-16 typed proxy poll deadline; in-FSM timeout
- [ ] VER-17 major crossover is an FSM gate (atomic in one snapshot)

### Testing and quality (TEST)
- [ ] TEST-01..12 table tests, -race, coverage floor, golden, fuzz, vet+staticcheck, gofumpt, FSM gate, hermetic, parallel, error assertions, external test package

### Security and supply chain (SEC)
- [ ] SEC-01..12 static build, FIPS knob, non-root, SBOM, CVE gate, cosign, distroless, OCI labels, govulncheck, dep hygiene, secret scan, provenance
- [ ] SEC-13 image security pipeline WIRED into the release app as a typed DAG; readinessTimeout typed
- [ ] SEC-13a full gosec SAST + weak-crypto/TLS bans
- [ ] SEC-13b substrate security/build libs are Rust, not shell
- [ ] SEC-13c FSM-IMAGE order scan→push→sign/attest (cryptographically correct)
- [ ] SEC-14 distroless-by-default + restricted Pod SecurityContext admission-gated
- [ ] SEC-15 real FIPS boringcrypto post-build probe + CGO resolution
- [ ] SEC-16 released binaries get SBOM + scan + provenance (FSM-RELEASE)
- [ ] SEC-17 base-image + toolchain digest-pinned and recorded
- [ ] SEC-18 signed commits + CODEOWNERS + branch protection + least-priv CI tokens + Go env hardening
- [ ] SEC-19 expiring allowlist gate + deployed-digest ConMon rescan + artifact secret scan

### UI/UX look-and-feel (UI)
- [ ] UI-01 human-facing output rendered through `borealis` only (one `Theme`, one `Render` verb)
- [ ] UI-02 colour via typed `borealis.Role`/`Theme` tokens; no hand-authored hex/ANSI outside `borealis/theme`
- [ ] UI-03 layout/spacing/tables via `comp` + `style` grid; no manual padding/column math
- [ ] UI-04 status/result role derived from `errors-go` Severity (exit/log/screen agree)
- [ ] UI-05 errors + CLI help/usage rendered via `borealis`/`fangx` from the typed error
- [ ] UI-06 TTY-aware: styled for a human, plain for a pipe; `-o json`/`-o yaml` stdout is one clean document
- [ ] UI-07 `NO_COLOR`/`color: never` honoured; never colour-as-sole-signal (glyph+label)
- [ ] UI-08 accessible: profile downsampling + typed `Accessible` mode
- [ ] UI-09 interactive forms via `huh` through `huhx`; degrade non-interactively
- [ ] UI-10 live widgets via `bubblesx`/`tui`; degrade to static `comp`; never on the data stream
- [ ] UI-11 borealis scoped to the human surface; `Biblioteca` renders nothing; v2 leaves import-gated
- [ ] UI-12 theme single-sourced via `borealis.Config` (shikumi-loaded, `FromConfig`-resolved, pure); no hand-authored theme

### Delivery FSMs (FSM-*)
- [ ] FSM-MODULE gapless table; CAS push; in-FSM proxy timeout; retract-aware rollback; major-crossover gate; universal Fail; audited
- [ ] FSM-RELEASE scan/SBOM/provenance states; resume partial publish; receipted rollback; reproducible-build divergence handled; universal Fail; audited
- [ ] FSM-IMAGE scan→push→sign order; push-revert cleanup; tri-state CVE; transient retry; cold rollback; ConMon Degraded; CAS push; universal Fail; audited
- [ ] FSM-ACTION post-Verify major-tag promotion; fact-reset on revival; exact-SHA rollback; injection-safe; universal Fail; audited
- [ ] FSM shared: FSM-AUDIT, FSM-TRISTATE, FSM-FAIL, FSM-RESET, FSM-IDEMPOTENT, FSM-CAS, FSM-OBS all hold on all four machines
- [ ] `forge tool status` surfaces current FSM state + last gate verdict + owning rule

---

## Coverage Statement

This standard asserts coverage of every scenario raised across the four adversarial
gap-analysis lenses. Each closed gap and its closing rule(s):

### New-engineer-navigation lens
- GAP-1 dead canonical example → DOC-11 + `caixa-validate --meta` resolves every `Demonstrated by:`.
- GAP-2 no glossary → DOC-12 + the [Glossary](#glossary).
- GAP-3 no getting-started path → [Day-one setup](#day-one-setup) + DOC-03a (README `## Install` parity).
- GAP-4 no run recipe → LIFE-16 + [Run & debug recipes](#run--debug-recipes); LIFE-15 canonical ports.
- GAP-5 devShell not first-class → TEST-07 (expanded toolchain) + [Day-one setup](#day-one-setup).
- GAP-6 no debugging guidance → [Run & debug recipes](#run--debug-recipes) triage table + dlv recipe.
- GAP-7 no identity table → DOC-14 + the [Identity-derivation table](#identity-derivation-table).
- GAP-8 no concern→file map → DOC-15 + the [Concern → library → symbol map](#concern--library--symbol-map).
- GAP-9 no inter-lib graph → DOC-16 + the [composition graph](#inter-library-composition-graph).
- GAP-10 no scaffold/extend workflow → [Extending / scaffolding](#extending--scaffolding) + DOC-18.
- GAP-11 edit→regenerate loop undrawn → DOC-18 + the [authored-vs-generated manifest](#authored-vs-generated-files).
- GAP-12 no FSM-state readout → [FSM status / observability](#fsm-status--observability) + `forge tool status` (FSM-OBS).
- GAP-13 no gate→fix map → DOC-17 + the gate-verdict tables.
- GAP-14 licensing/vendoring contradictions → source notes rewritten to single MIT + single proxy mechanism (no `-mod=vendor`/Apache wording remains).
- GAP-15 scattered thresholds → DOC-19 + the [Tunables & defaults](#tunables--defaults) appendix.
- GAP-16 scattered escape hatches → DOC-20 + the [annotation catalog](#annotation--escape-hatch-catalog).
- GAP-17 no reading order → DOC-13 on-ramp.
- GAP-18 registry incompleteness → registry now carries rule text + rationale + demonstrated-by + FSM-* IDs and a `caixa-validate --meta` ID-parity check (see `rules-registry.yaml`).

### SRE / delivery-failure-FSM lens
- GAP-1 image partial-push dead terminal → FSM-IMAGE `PushFailed → Cleanup → PushReverted` + decomposed `G_registry_push_*` + idempotent re-push.
- GAP-2 module tag-pushed-but-proxy-fails incoherent rollback → VER-14 + `ModuleRollbackGate` (retract, never delete a cached tag).
- GAP-3 release formula partial publish → FSM-RELEASE `FormulaRevertGate` + RollbackReceipt + `ResumeUpload`.
- GAP-4 action moving-tag before Verify → FSM-ACTION `PromoteMajorTag` (post-Verify) + captured `prior_major_tag_sha`.
- GAP-5 no deploy/verify retry → FSM-IMAGE `RetryDeploy`/`RetryVerify` (`G_transient_and_budget`).
- GAP-6 out-of-FSM proxy timeout → VER-16 + in-FSM `ConfirmProxy`/`poll_budget_exhausted`.
- GAP-7 no runner-death Fail edge → FSM-FAIL universal `Fail(reason)` on all four machines.
- GAP-8 revival reuses stale facts → FSM-RESET + FSM-ACTION I5a ResetFacts.
- GAP-9 unquantified timeouts → SEC-13/VER-16 typed lower-bounded Durations with defaults + inclusive-timeout predicate.
- GAP-10 reproducible-build divergence undefined → FSM-RELEASE `ChecksumGate` clean-runner second build + reference manifest + `DeliveryFailed(BuildError)` diagnostic.
- GAP-11 first-deploy rollback undefined → FSM-IMAGE `ColdRollback` (null to-digest).
- GAP-12 no idempotency rule → FSM-IDEMPOTENT + `ResumeUpload`.
- GAP-13 no concurrency/CAS → FSM-CAS single-writer + `TagPushRaceLost` first-class signal.
- GAP-14 image-release app lacks sign/SBOM/CVE → SEC-13 wires the typed DAG + push-tool precondition.
- GAP-15 audit only in FSM-IMAGE → FSM-AUDIT lifted to all four machines.
- GAP-16 Job-error vs genuine-fail collapsed → FSM-TRISTATE (`Indeterminate` → retryable).

### Security / FedRAMP / supply-chain lens
- A1/A3 pipeline not wired / no provenance → SEC-13 + FSM-RELEASE/IMAGE provenance states.
- A2 sign-before-push/scan order wrong → SEC-13c + reordered FSM-IMAGE.
- A4 security wrappers are shell → SEC-13b + extended DOC-10 meta-lint.
- A5 FIPS probe not real + CGO collision → SEC-15.
- A6 not distroless-by-default / no SecurityContext → SEC-14.
- B1 binaries unscanned/uninventoried → SEC-16.
- B2 base/toolchain not digest-pinned → SEC-17.
- B3 gosec only two checks → SEC-13a.
- B4 no TLS floor → NET-14.
- B5 no source governance → SEC-18.
- B6 no least-priv CI token → SEC-18 + LAYOUT-07 permissions check.
- B7 no Go-env hardening → SEC-18.
- B8 no expiring-allowlist gate → SEC-19.
- B9 no deployed rescan → SEC-19 + FSM-IMAGE `Verified → Degraded`.
- B10 no runtime-privilege assertions → SEC-14 + `G_apply_accepted` restricted conjunct.
- B11 SBOM under-reports static-Go → SEC-13/SEC-16 (Nix dep-graph + non-trivial-component check).
- C1 CVE failOn default disagreement → unified to `HIGH` (SEC-05 == FSM-IMAGE gate).
- C2 no artifact-secret scan → SEC-19 filesystem scan.
- C3 broken `go-docker.nix` callPackage → corrected to `docker.nix` (substrate fix tracked in SEC-13b's library-hygiene scope).
- C4 no post-verify chain-break state → FSM-IMAGE `Verified → Degraded` ConMon edge.

### Version-upgrade / multi-module lens
- GAP-1 VER-11/LAYOUT-08 contradiction → split VER-11a (multi-binary) / VER-11b (multi-module).
- GAP-2 versionPackage undocumented → VER-04a.
- GAP-3 intra-repo diamond → VER-14 INTRA-REPO-MAJOR-COHERENCE.
- GAP-4 monorepo vendorHash divergence → see note below (deferred-with-reason).
- GAP-5 no consumer upgrade op → VER-13 `forge tool upgrade`.
- GAP-6 no fleet upgrade DAG → VER-15 root→leaf topological propagation.
- GAP-7 go.work unaddressed → VER-10 clause (5).
- GAP-8 no `retract` path → VER-14.
- GAP-9 CLI flag/subcommand compat → CLI-13.
- GAP-10 deprecation-window gate mismatch → VER-07 parses `earliest-major-for-removal`.
- GAP-11 config schema migration absent → CFG-15.
- GAP-12 cross-version reload-class change → CFG-12 extension.
- GAP-13 major crossover not an FSM state → VER-17 + FSM-MODULE `MajorCrossoverGate`.
- GAP-14 `toolchain` directive unaddressed → VER-10 clause (6).
- GAP-15 pseudo-version only blocks at release → VER-09 continuous PR warning.

### Deliberately deferred (with reason)
- **Upgrade-lens GAP-4 (monorepo `mkGoMonorepoBinary` hardcodes `vendorHash = null`).**
  The RULE is closed at the standard level: VER-11a documents that a multi-binary
  monorepo resolves its deps through the proxy + `go.sum` (the LAYOUT-12 mechanism),
  which is the hermetic property SEC-10 requires, so `vendorHash = null` is the
  documented, correct monorepo path (not a divergence to "fix"). The substrate
  CODE-CHANGE to give `mkGoMonorepoBinary` an optional explicit `vendorHash` arg is a
  builder enhancement deferred to substrate engineering — it is a `lib/build/go/`
  source edit, out of scope for a docs/registry standard, and the standard already
  records the reconciliation. No conformance gap remains; only an optional ergonomics
  improvement is deferred.
