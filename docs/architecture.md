# Architecture

## Overview

Substrate is a library of parameterized Nix functions. It produces no packages
of its own -- consumers import it as a flake input and call its builders to
produce packages, dev shells, apps, overlays, and home-manager modules.

The library is organized into six module categories with a strict dependency DAG.

---

## Layered Design

```
┌─────────────────────────────────────────────────────────────────┐
│                        Consumer Flakes                          │
│  (nexus, mado, kindling, pangea-akeyless, k8s, blackmatter-*)  │
└───────────┬──────────────┬──────────────┬───────────────────────┘
            │              │              │
            ▼              ▼              ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│   service/   │  │    infra/    │  │   codegen/   │
│  lifecycle   │  │     IaC      │  │   code gen   │
│  patterns    │  │   patterns   │  │   patterns   │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │
       ▼                 ▼                 ▼
┌──────────────────────────────────────────────────┐
│                     build/                        │
│  rust/ go/ zig/ swift/ typescript/ ruby/ python/  │
│  dotnet/ java/ wasm/ web/                         │
└──────────────────────┬───────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────┐
│                      util/                        │
│  config  darwin  docker-helpers  release-helpers   │
│  test-helpers  versioned-overlay  repo-flake      │
└──────────────────────────────────────────────────┘

┌──────────────┐  ┌──────────────┐
│     hm/      │  │   devenv/    │   (standalone -- no internal deps)
│ home-manager │  │  devenv.sh   │
│   helpers    │  │   modules    │
└──────────────┘  └──────────────┘
```

---

## Dependency Graph Between Categories

### Allowed imports

| From | To | Reason |
|------|----|--------|
| `build/*` | `util/*` | Builders use `config.nix` for tokens, `darwin.nix` for macOS deps |
| `service/*` | `build/*` | Service lifecycle composes build outputs (images, binaries) |
| `service/*` | `util/*` | Service patterns use config, release helpers |
| `infra/*` | `util/*` | Infrastructure patterns use config |
| `codegen/*` | `util/*` | Code generation uses source registry |

### Prohibited imports

| From | To | Reason |
|------|----|--------|
| `util/*` | `build/*` | Would create cycles |
| `util/*` | `service/*` | Would create cycles |
| `util/*` | `infra/*` | Would create cycles |
| `build/*` | `service/*` | Build layer is lower than service layer |
| `build/*` | `infra/*` | Build layer is lower than infra layer |
| `build/{lang-a}/*` | `build/{lang-b}/*` | Language directories are independent |
| `hm/*` | any internal | hm/ modules are standalone (only need `nixpkgs.lib`) |
| `devenv/*` | any internal | devenv/ modules are standalone |

### Within `build/`

Each language directory (`rust/`, `go/`, `zig/`, etc.) is self-contained.
Files within the same language directory may import each other freely:

```
build/rust/service.nix -> build/rust/overlay.nix       (OK)
build/rust/service.nix -> build/go/tool.nix            (PROHIBITED)
build/go/monorepo-binary.nix -> build/go/monorepo.nix  (OK)
```

---

## Root Aggregation (`lib/default.nix`)

`default.nix` is the single public API surface. It:

1. Accepts `{ pkgs, forge?, system?, crate2nix?, fenix? }` as parameters
2. Imports every module from every category
3. Re-exports all public functions as a flat attribute set
4. Provides standalone import paths as `*Builder` attributes

### How consumers access the API

**Via `flake.nix` outputs:**

```nix
# flake.nix
lib = eachSystem (system: let
  pkgs = import nixpkgs { inherit system; overlays = [...]; };
in import ./lib { inherit pkgs crate2nix; fenix = fenix.packages.${system}; });
```

This evaluates `lib/default.nix`, which returns the full attribute set.

**Via `substrate.libFor`:**

```nix
substrateLib = substrate.libFor { inherit pkgs system; };
```

This calls the same `lib/default.nix` with the consumer's `pkgs`.

**Via standalone imports:**

```nix
rustService = import "${substrate}/lib/build/rust/service.nix" { ... };
hmHelpers = import "${substrate}/lib/hm/service-helpers.nix" { lib = nixpkgs.lib; };
```

These bypass `default.nix` entirely -- useful for minimal imports.

---

## Module Category Details

### `build/` -- Language Build Patterns

Each language directory provides:

| Component | Purpose | Example |
|-----------|---------|---------|
| `overlay.nix` | Toolchain overlay for nixpkgs | `mkRustOverlay`, `mkGoOverlay` |
| `tool.nix` / `tool-release.nix` | CLI tool builder | `mkGoTool`, Rust cross-compile releases |
| `library.nix` | Library SDLC (build, check, publish) | Rust crates.io, TS npm |
| `service.nix` / `service-flake.nix` | Full service builder | Rust service with Docker + HM module |
| `*-flake.nix` | Zero-boilerplate flake wrapper | Wraps builder + eachSystem |

Not every language has every component -- only what is needed.

### `service/` -- Service Lifecycle

Patterns for deploying and managing services:

- **`helpers.nix`**: Docker compose configs, test runners, dev shells, CI checks
- **`platform-service.nix`**: Complete platform service (binary + image + apps)
- **`environment-apps.nix`**: Environment-aware (staging/prod) deployment apps
- **`product-sdlc.nix`**: Full product SDLC (release, test, migrate, infra)
- **`image-release.nix`**: Multi-arch OCI image push via skopeo
- **`helm-build.nix`**: Helm chart lint/package/push/release/bump
- **`db-migration.nix`**: Kubernetes migration Job manifests
- **`health-supervisor.nix`**: Health check supervisor builder

### `infra/` -- Infrastructure as Code

Patterns for infrastructure provisioning and validation:

- **`pangea-workspace.nix`**: Nix->YAML->Pangea workspace config (shikumi pattern)
- **`pangea-infra.nix`**: Per-system Pangea project builder
- **`terraform-module.nix`**: TF init + validate + fmt + tflint
- **`terraform-provider.nix`**: TF provider builds
- **`pulumi-provider.nix`**: Multi-language SDK generation from schema.json
- **`ansible-collection.nix`**: Ansible Galaxy collection packaging
- **`infra-workspace.nix`**: DEPRECATED -- shim kept for backward compat
- **`infra-state-backend.nix`**: DEPRECATED -- shim kept for backward compat

### `hm/` -- Home-Manager Integration

Standalone helpers that only require `nixpkgs.lib`:

- **`service-helpers.nix`**: Reusable launchd (macOS) + systemd (Linux) service templates
- **`mcp-helpers.nix`**: MCP server option types, wrapper scripts, per-agent filtering
- **`skill-helpers.nix`**: Auto-discovery and deployment of Claude Code skills
- **`typed-config-helpers.nix`**: Generate JSON/YAML config from typed Nix options
- **`workspace-helpers.nix`**: Workspace configuration helpers
- **`secret-helpers.nix`**: Secret management integration
- **`nixos-service-helpers.nix`**: NixOS systemd, firewall, kernel, kubeconfig, VM tests

### `codegen/` -- Code Generation

- **`openapi-forge.nix`**: OpenAPI spec parsing and forge integration
- **`openapi-sdk.nix`**: Multi-language SDK generation from OpenAPI specs
- **`openapi-rust-sdk.nix`**: Rust-specific SDK generation
- **`source-registry.nix`**: Centralized pinned source registry for GitHub repos

### `util/` -- Shared Utilities

Foundation layer used by all other categories:

- **`config.nix`**: Token resolution, runtime tools, deployment tools
- **`darwin.nix`**: macOS SDK deps (Security.framework, SystemConfiguration, etc.)
- **`docker-helpers.nix`**: Docker build utilities
- **`release-helpers.nix`**: Release workflow helpers
- **`test-helpers.nix`**: Pure Nix evaluation test infrastructure
- **`completions.nix`**: Shell completion generation
- **`repo-flake.nix`**: Universal flake builder (maps language+builder to pattern)
- **`monorepo-parts.nix`**: flake-parts module for monorepo consumers
- **`versioned-overlay.nix`**: Generate N-track versioned overlay entries
- **`flake-wrapper.nix`**: Flake boilerplate reduction

### `devenv/` -- Devenv Modules

Drop-in modules for `devenv.sh` / `devenv.lib.mkShell`:

- **`rust.nix`**: Base Rust development (toolchain, clippy, rustfmt)
- **`rust-service.nix`**: Rust service dev (+ Docker, Postgres, Redis)
- **`rust-tool.nix`**: Rust CLI tool dev
- **`rust-library.nix`**: Rust library dev (+ crates.io publish)
- **`web.nix`**: Web development (Node, npm, Playwright)
- **`nix.nix`**: Nix development (nixfmt, nil LSP)

---

## Flake Structure

```nix
# flake.nix outputs:
{
  devenvModules     # { rust, rust-service, rust-tool, rust-library, web, nix }
  lib               # Per-system: lib.${system} -> full attribute set
  rustOverlays      # Per-system: rustOverlays.${system}.rust
  libFor            # Function: { pkgs, system, ... } -> full attribute set
  rustToolReleaseFlakeBuilder   # Path to standalone builder (CLI + GitHub releases)
  rustToolImageFlakeBuilder     # Path to standalone builder (CLI + Docker image)
  zigToolReleaseFlakeBuilder    # Path to standalone builder
  rustOverlay                   # Path to overlay module
  monorepoPartsModule           # Path to flake-parts module
}
```

The `lib` and `libFor` outputs both evaluate `lib/default.nix` -- the difference
is that `lib` uses substrate's own nixpkgs, while `libFor` accepts the consumer's.
