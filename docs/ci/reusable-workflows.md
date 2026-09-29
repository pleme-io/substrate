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

## ★★ A job output is NOT a workflow output — 13 values computed and dropped

A reusable workflow exposes a value to its caller ONLY through
`on.workflow_call.outputs`. A `jobs.<j>.outputs` entry is visible to other jobs
in the SAME workflow and to nobody else. Declare it in the wrong block and the
value is computed correctly, logged as `Set output '<name>'`, and silently
unreachable.

**Measured 2026-07-31, and the denominator matters because the raw count is
misleading.** Over 75 workflows, 69 of which are `workflow_call`:

| | count | verdict |
|---|---|---|
| job outputs not in `workflow_call.outputs`, but consumed by another job in the same file | **24** | CORRECT — internal wiring, must NOT be exposed |
| job outputs not exposed AND not referenced anywhere in the file | **13** | dead, or lost at the boundary |

Reporting the 37 together would be the exact rounding the standing rule
(state the denominator; never round a mixed count into one verdict) forbids: most are right. The 13 are the signal. The one with the clearest
consequence is `container-stack.yml` `build.digest` — a caller of a
container-build reusable plainly wants the digest, and it is computed and
dropped.

**actionlint does NOT catch this class.** It validates expression syntax and
context availability; it has no opinion on whether a job output was meant to
cross the boundary. So the linter wired in hardened-images (66d9b91) is green on
every one of the 13.

**Receipt for why this is worth a section.** hardened-images run 30669854126:
`vendor-image-mirror.yml` resolved a Zot digest correctly and logged both
`Zot serves … at digest sha256:6e891d92…` and `Set output 'zot-digest'`, while
the consuming promote job read `""` and failed on the empty value two jobs later.
Every symptom pointed away from the cause — the producer was green, the value
was right there in the log, and the only red was elsewhere on an empty input.
Fixed in `ae5c3c3` by declaring it in `on.workflow_call.outputs`.

This is the same defect `pleme-io/actions/doca`'s outputs block already warns
about one layer down — "a composite action must DECLARE them or they stop at the
action boundary and the caller sees nothing" — so the shape is now documented at
both layers it occurs on.

`pending-workflow-output-boundary: 13 job outputs unexposed and unreferenced.`
Each needs a per-case judgement (expose, or delete as dead); a blanket sweep
would expose values no caller asked for.

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
| `rust-binary-release.yml` | GH Release | cross-arch (linux/macOS × x86_64/aarch64) feature-aware cargo build → attach binaries + .sha256 to Release. `artifact-only: true` (default false) writes no Release and marks nothing Latest: each leg uploads a workflow artifact, and `artifact-set` merges them once every leg and the linux baseline pass (`artifact-name` output). Pinned by `rust-binary-release.cases.tsv` (jobs) and `tools/artifact-only-guard.tlisp` (release steps) |
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

