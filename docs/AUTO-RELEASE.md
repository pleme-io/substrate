# pleme-io · Auto-Release pattern

> **One line of yaml per repo.** Every push to `main` auto-bumps
> the patch version, commits, tags, and ships to the appropriate
> upstream (crates.io, npmjs, pypi, ghcr, etc). Operators never
> type version numbers, never call publish commands, never manage
> rate-limit / dep-order / name-conflict edge cases.

## The whole thesis

```
push to main
  ↓
detect repo type (Rust workspace / single crate / npm / python / helm / action)
  ↓
auto-bump patch (skips if no source changes since last tag)
  ↓
commit + tag v<X.Y.Z> + push
  ↓
publish to upstream
  ├── on rate-limit  → sleep + retry
  ├── on name conflict → rename to pleme-io-<original> + retry
  ├── on dep-not-yet-published → defer + retry next pass
  └── on success → emit shipped-count + renamed-crates
```

Every component is a **Rust + tatara-lisp action** in `pleme-io/actions`;
the consumer-side workflow is a **3-line shim** in the repo's
`.github/workflows/auto-release.yml`.

## Consumer shape (the operator-facing yaml)

```yaml
# .github/workflows/auto-release.yml
on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      bump-type:
        description: "patch | minor | major"
        required: false
        default: patch

jobs:
  release:
    uses: pleme-io/substrate/.github/workflows/auto-release.yml@main
    with:
      bump-type: ${{ inputs.bump-type || 'patch' }}
    secrets: inherit
```

That's the entire consumer footprint. Three lines of real config.

## Why this works

1. **One trait per concern.** Each pleme-io action holds one
   primitive (bump / commit-tag / push / publish). The reusable
   workflow composes them; consumers compose the workflow.

2. **Polymorphic per repo type.** `pleme-io/actions/substrate-bump`
   detects the repo type at runtime (galaxy.yml → ansible;
   *.gemspec → ruby gem; Cargo.toml + [workspace] → rust workspace;
   Cargo.toml without [workspace] → rust single-crate; package.json
   → npm; pyproject.toml → python; Chart.yaml → helm; action.yml at
   root → github action). Same action, language-agnostic interface.

3. **Idempotent.** Pre-check before publish (does `(name, version)`
   already exist on the upstream?); skip when yes. Re-running the
   workflow is always safe.

4. **Self-healing under registry edge cases.**
   - **Rate limits:** sleep 600s and retry (configurable).
   - **Name conflicts:** rename the conflicting crate/package to
     `pleme-io-<original>` + update workspace deps + commit + retry.
   - **Dep not yet published:** defer the crate; retry in the next
     pass after its dep lands.

5. **Per-action images are pre-built.** Each tlisp action ships
   as a docker image to `ghcr.io/pleme-io/action-<name>:latest`
   via substrate's `image-push.yml` reusable. Consumer workflows
   pull the image, not the source — boots in seconds.

## The action catalog (Rust + tatara-lisp powered)

| Action | Purpose |
|---|---|
| `pleme-io/actions/substrate-bump@v1` | Polymorphic version bump. Detects repo type, calls the right `nix run .#bump` (or whatever the type wants). Emits `bumped` + `new-version` outputs. |
| `pleme-io/actions/rust-workspace-bump@v1` | Rust-workspace-specific bump (cargo set-version --workspace + crate2nix regen). Called by substrate-bump when repo type = rust-workspace. |
| `pleme-io/actions/git-commit-tag@v1` | Configure bot identity, stage typed paths, commit with templated message, create annotated tag. Does NOT push. |
| `pleme-io/actions/git-push-with-token@v1` | Re-arm origin URL with the given token (BOT_PAT or GITHUB_TOKEN), push branch + tags. |
| `pleme-io/actions/rust-workspace-publish@v1` | Per-crate publish to crates.io. Skips already-published, auto-renames conflicts, multi-pass for dep order, sleeps on rate-limit. |
| `pleme-io/actions/ansible-collection-publish@v1` | Same shape for ansible-galaxy. |
| `pleme-io/actions/gem-publish@v1` | Same shape for rubygems. |
| `pleme-io/actions/helm-oci-publish@v1` | Same shape for helm OCI registries. |
| `pleme-io/actions/oci-image-push@v1` | Multi-arch docker image push to ghcr. |
| `pleme-io/actions/action-release@v1` | Validates action.yml + cuts a GH release + fast-forwards the major branch (v1). |

Every action has the same shape:
- `action.yml` — composite recipe; orchestrates installs + one tatara-script invocation.
- `run.tlisp` — ALL non-trivial logic, in tatara-lisp.
- `tatara-script` — the universal Rust binary that runs the tlisp source.

## Reusable workflows in substrate

| Workflow | Purpose |
|---|---|
| `pleme-io/substrate/.github/workflows/auto-release.yml` | **The one consumers call.** Polymorphic; auto-detects repo type + dispatches. |
| `pleme-io/substrate/.github/workflows/rust-auto-release.yml` | Rust-specific (workspace OR single-crate). |
| `pleme-io/substrate/.github/workflows/ansible-collection-auto-bump.yml` | Ansible-specific (already exists; pattern model). |
| `pleme-io/substrate/.github/workflows/cargo-release.yml` | Tag-triggered single-crate publish (already exists). |
| `pleme-io/substrate/.github/workflows/cargo-ci.yml` | CI checks (already exists). |

## "Blast public" semantics

Patch version bumps on every merge to main. With 15 workspace
crates that means 15 new patch versions per merge — but that's
the point: downstream consumers cargo-pin to a specific version
and pull updates explicitly. The "blast" is fire-and-forget:
operator pushes a code change; the substrate ships the version
to the upstream registry without operator intervention.

For major / minor bumps, use the `workflow_dispatch` input:
```bash
gh workflow run auto-release.yml -f bump-type=minor
```

The `bump-type` defaults to `patch`, so no operator typing is
needed in the common case.

## Adoption by repo

Each pleme-io repo needs ONE 3-line workflow file:

```yaml
# .github/workflows/auto-release.yml
on: { push: { branches: [main] } }
jobs:
  release:
    uses: pleme-io/substrate/.github/workflows/auto-release.yml@main
    secrets: inherit
```

Plus the appropriate metadata in the repo's manifest (Cargo.toml,
package.json, Chart.yaml, action.yml, etc) so the publish step
can run cleanly. The substrate-bump action validates that the
metadata is correct + emits clear errors when something's
missing.

## The NO SHELL discipline this preserves

Every step's logic is Rust + tatara-lisp. Workflow yaml carries
only:
- Triggers (`on:`)
- Inputs (`with:`)
- Secrets (`secrets: inherit`)
- Gating (`if:`)
- Step ordering

The actual work happens in actions, each of which is itself a
typed primitive shipped via the same release pipeline.

## Cross-language extension path

Adding a new language follows the existing pattern:

1. Build `pleme-io/actions/<lang>-bump` — read manifest, bump version,
   regenerate any lockfile, emit outputs.
2. Build `pleme-io/actions/<lang>-publish` — pre-check + retry-on-error +
   skip-already-published.
3. Add detection in `pleme-io/actions/substrate-bump/run.tlisp` for
   the manifest file (`pyproject.toml`, `package.json`, `Chart.yaml`,
   etc).
4. Add a route in `pleme-io/substrate/.github/workflows/auto-release.yml`
   for the new repo type.
5. Add reusable workflow `pleme-io/substrate/.github/workflows/<lang>-auto-release.yml`
   for consumers who want explicit per-language wiring.

No consumer-side change needed — every adopting repo automatically
gets the new path the next time their workflow runs.
