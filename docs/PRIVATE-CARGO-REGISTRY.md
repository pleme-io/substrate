# Private Cargo Registry — GitHub Packages

> **Private crates.io alternative for closed-source pleme-io crates.**

GitHub Packages hosts a Cargo registry at `https://cargo.pkg.github.com/pleme-io/`
that works exactly like crates.io but is private — only org members with a
PAT (or `GITHUB_TOKEN` in CI) can read or publish.

## Architecture

```
push to main
  → bump workspace version (patch/minor/major)
  → commit + tag vX.Y.Z
  → push to main + tags
  → cargo publish --registry=pleme-io
      → uploads to https://cargo.pkg.github.com/pleme-io/
      → visible at https://github.com/orgs/pleme-io/packages
```

## Onboarding a private repo (3 steps)

### 1. Drop the workflow shim

Copy `substrate/templates/private-auto-release.yml` to `.github/workflows/auto-release.yml`:

```yaml
name: auto-release

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
    uses: pleme-io/substrate/.github/workflows/rust-private-auto-release.yml@main
    with:
      bump-type: ${{ inputs.bump-type || 'patch' }}
      registry-name: pleme-io
    secrets: inherit
```

### 2. Add `.cargo/config.toml`

Copy `substrate/templates/private-cargo-config.toml` to `.cargo/config.toml`:

```toml
[registries.pleme-io]
index = "sparse+https://cargo.pkg.github.com/pleme-io/"

[registry]
default = "pleme-io"
```

### 3. Add `publish` restriction to each crate

In each workspace member's `Cargo.toml`:

```toml
[package]
name = "my-private-crate"
version = "0.1.0"
publish = ["pleme-io"]    # prevents accidental crates.io publish
```

## Consuming private crates

Any repo that depends on a private pleme-io crate needs the same
`.cargo/config.toml` (step 2 above) so cargo knows where to resolve it.

In `Cargo.toml`:

```toml
[dependencies]
my-private-crate = { version = "0.1", registry = "pleme-io" }
```

For local development, set the token env var:

```bash
export CARGO_REGISTRIES_PLEME_IO_TOKEN="Bearer ghp_xxxxx"
```

In CI, `GITHUB_TOKEN` is automatically available and works for both
read and write (with `packages: write` permission).

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `bump-type` | `patch` | `patch` / `minor` / `major` |
| `registry-name` | `pleme-io` | Must match `[registries.<name>]` in `.cargo/config.toml` and `publish = [...]` in `Cargo.toml` |
| `source-paths` | `*.rs Cargo.toml Cargo.lock` | Pathspecs the skip-detector inspects |
| `add-paths` | `Cargo.toml Cargo.lock Cargo.gen.lock Cargo.build-spec.json` | Pathspecs the bump commit stages |
| `rename-prefix` | `pleme-io-` | Prefix for auto-renaming conflicting crates |
| `no-verify` | `true` | Skip `cargo publish`'s verification compile |
| `runner` | (auto) | Runner label override (empty = route by repo visibility) |

## Differences from the public auto-release

| Aspect | Public (crates.io) | Private (GitHub Packages) |
|---|---|---|
| Registry URL | `https://crates.io` | `https://cargo.pkg.github.com/pleme-io/` |
| Auth token | `CRATES_API_TOKEN` | `GITHUB_TOKEN` or `BOT_PAT` |
| Token env var | `CARGO_REGISTRY_TOKEN` | `CARGO_REGISTRIES_PLEME_IO_TOKEN` |
| Visibility check | Skips private repos | Works for private repos |
| `publish` field | Not required | `publish = ["pleme-io"]` required |
| Rate limits | 5 new crates/hour | No known limit |
| Publicly visible | Yes | No (org members only) |

## Scheduling drip-publish

For workspaces with many crates, add a cron schedule to the consumer
workflow to drip-publish remaining capacity:

```yaml
on:
  push:
    branches: [main]
  schedule:
    - cron: '*/15 * * * *'    # every 15 minutes
  workflow_dispatch:
```

The drip job is idempotent — it skips already-published crates and
converges to a no-op once everything is on the registry.
