# substrate · auto-release recipe catalog

> Canonical index of every release recipe substrate ships, for
> operators selecting an adoption path AND for the polymorphic
> `auto-release.yml` dispatcher that routes by repo type.

Source of truth: [`lib/release/catalog.nix`](../lib/release/catalog.nix).
Per the ★★ AUTO-RELEASE prime directive (see
[`pleme-io/CLAUDE.md`](https://github.com/pleme-io/blackmatter-pleme/blob/main/docs/pleme-io-CLAUDE.md))
every adopting repo uses ONE consumer shim:

```yaml
# .github/workflows/auto-release.yml — the only file you write
on:
  push: { branches: [main] }
  workflow_dispatch:
    inputs:
      bump-type:
        default: patch
jobs:
  release:
    uses: pleme-io/substrate/.github/workflows/auto-release.yml@main
    with:
      bump-type: ${{ inputs.bump-type || 'patch' }}
    secrets: inherit
```

The polymorphic dispatcher detects the repo type + routes to one
of the per-language reusables below.

## Recipes (sortable status overview)

| Recipe | Detect | Upstream | Status |
|---|---|---|---|
| `rust-workspace` | `Cargo.toml + [workspace]` | crates.io | ✅ shipping |
| `rust-single-crate` | `Cargo.toml + [package]` | crates.io | ✅ shipping |
| `npm` | `package.json` | npmjs.org | ✅ shipping |
| `python` | `pyproject.toml` | pypi.org | ✅ shipping |
| `helm` | `Chart.yaml` | OCI registry | ✅ shipping |
| `ansible-collection` | `galaxy.yml` | ansible-galaxy | ✅ shipping (pre-pattern; dispatcher integration pending) |
| `ruby-gem` | `*.gemspec` | rubygems.org | ✅ shipping (pre-pattern) |
| `github-action` | `action.yml` at root | ghcr action image + v1 | ✅ shipping (pre-pattern) |

## How to query the catalog

From a nix flake that consumes substrate as an input:

```nix
# in a flake's outputs:
let
  catalog = substrate.lib.release.catalog;
  rust-workspace-recipe = catalog.rust-workspace;
in {
  # rust-workspace-recipe.workflow → full uses: ref
  # rust-workspace-recipe.secrets  → list of secret names needed
  # rust-workspace-recipe.semantics → human description
}
```

From a CI workflow:

```yaml
- name: List supported recipes
  shell: bash
  run: |
    nix eval --raw "github:pleme-io/substrate#lib.release.catalog" \
      --apply 'cat: builtins.concatStringsSep "\n" (builtins.attrNames cat)'
```

From a Claude session: invoke the
[`pleme-io-auto-release`](https://github.com/pleme-io/blackmatter-pleme/blob/main/skills/pleme-io-auto-release/SKILL.md)
skill — the skill's "supported ecosystems" table mirrors this
file.

## Per-recipe detail

For each recipe, the catalog entry exposes:

- `detect` — the manifest file or `[section]` that signals this type
- `upstream` — where the artifact ships
- `bump-action` — the `pleme-io/actions/<name>@<ref>` for version bumping
- `publish-action` — the `pleme-io/actions/<name>@<ref>` for publishing
- `workflow` — the substrate reusable workflow consumers reference
- `secrets` — list of secret names required (`?` suffix = optional)
- `semantics` — one-line description of self-healing behaviors
- `status` — `shipping` / `pre-pattern` / `pending`
- `reference-impl` — a real consumer repo running this recipe

## Adding a new recipe (cross-language extension template)

Documented in the
[`pleme-io-auto-release`](https://github.com/pleme-io/blackmatter-pleme/blob/main/skills/pleme-io-auto-release/SKILL.md)
skill's "Adding a new language" section. Three artifacts per
ecosystem:

1. `pleme-io/actions/<lang>-bump/` — bump action (tlisp, uses _tlisp-stdlib)
2. `pleme-io/actions/<lang>-publish/` — publish action (tlisp, uses _tlisp-stdlib)
3. `pleme-io/substrate/.github/workflows/<lang>-auto-release.yml` — reusable workflow

Then:

4. Add detection branch in `pleme-io/actions/detect-repo-type/run.tlisp`
5. Add route in `pleme-io/substrate/.github/workflows/auto-release.yml`
6. Add entry to `lib/release/catalog.nix` (this file's source)
7. Add row to the status table above

The polymorphic dispatcher absorbs the new route with **zero**
consumer-side change.

## Future: shikumi-backed CLI

A planned `pleme-io/releaser` crate will expose the same
recipes as a local CLI (shikumi-typed config). Operators can
preview a release, manually trigger any step, or onboard a new
repo (`releaser onboard`). GH actions become thin wrappers
around the binary — same logic, two surfaces. Tracked under
`AUTO-RELEASE-CLI` milestone (TBD).
