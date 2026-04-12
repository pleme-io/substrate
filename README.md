# Substrate

Reusable Nix build patterns for all pleme-io repositories. One flake input gives
every repo a complete build, test, and deploy pipeline -- from Rust services to
Ruby infrastructure to TypeScript libraries.

## What It Does

Substrate is a library of parameterized Nix functions. It produces no packages
of its own. Consumers import it as a flake input and call its builders to produce
packages, dev shells, apps, overlays, and home-manager modules.

**12 languages** (Rust, Go, Zig, Swift, TypeScript, Ruby, Python, .NET, Java,
WASM, Web/Vite, Shell), **6 IaC platforms** (Pangea, Terraform, Pulumi,
Crossplane, Ansible, Helm), **home-manager integration**, and
**security-first infrastructure** -- all from a single `inputs.substrate`.

## Module Hierarchy

```
lib/
  build/          Language-specific build patterns
    rust/           overlay, library, service, tool-release, leptos-build, crate2nix, devenv
                    scaffolds: leptos-app, rust-service, rust-tool, dioxus-app, gpu-app
    go/             overlay, tool, monorepo, grpc-service, docker
    zig/            overlay, tool-release, bootstrap, zls
    swift/          overlay, bootstrap, sdk-helpers
    typescript/     tool, library, library-flake
    ruby/           config, build, gem, gem-flake, scaffold: ruby-gem
    python/         package, uv
    dotnet/         build
    java/           maven
    wasm/           build (Yew/WASM with wasm-bindgen + wasm-opt)
    web/            build (Vite/React), docker, github-action

  kube/           Kubernetes resource builders (nix-kube)
    primitives/     29 pure K8s resource builders (no pkgs)
    compositions/   9 service archetypes (mkMicroservice, mkWorker, etc.)
    modules/        NixOS-style overlay system
    tests.nix       37 pure eval tests

  infra/          Infrastructure-as-Code patterns + Unified Infrastructure Theory
    workload-archetypes.nix   7 abstract archetypes -> K8s + Tatara + WASI
    compositions.nix          mkMultiTierApp, mkPipeline
    policies.nix              mkPolicy, evaluateAll, assertPolicies
    renderers/                kubernetes.nix, tatara.nix, wasi.nix
    tests/                    8 Nix eval test suites (151+ assertions)
    pangea-workspace.nix      Nix->YAML->Pangea config (shikumi pattern)
    pangea-infra.nix          Per-system Pangea project builder
    pangea-infra-flake.nix    Zero-boilerplate Pangea flake
    gated-pangea-workspace.nix  Test-gated workspace
    terraform-module.nix      TF validation
    terraform-provider.nix    TF provider builds
    pulumi-provider.nix       Multi-language SDK gen
    ansible-collection.nix    Galaxy collection packaging
    environment-config.nix    Environment variable config

  service/        Service lifecycle patterns
    helpers.nix               Docker compose, test runners
    platform-service.nix      Full platform service builder
    environment-apps.nix      Env-aware deployment apps
    product-sdlc.nix          Product SDLC app factory
    image-release.nix         Multi-arch OCI release
    helm-build.nix            Helm chart SDLC
    db-migration.nix          K8s migration jobs
    health-supervisor.nix     Health check builder

  hm/             home-manager integration (standalone, only needs nixpkgs.lib)
    service-helpers.nix       launchd + systemd service templates
    mcp-helpers.nix           MCP server deployment
    skill-helpers.nix         Claude Code skill framework
    typed-config-helpers.nix  JSON/YAML config from Nix options
    workspace-helpers.nix     Workspace config helpers
    secret-helpers.nix        Secret management helpers
    nixos-service-helpers.nix NixOS module patterns

  codegen/        Code generation patterns
    openapi-forge.nix         OpenAPI parsing + forge
    openapi-sdk.nix           Multi-language SDK gen
    openapi-rust-sdk.nix      Rust SDK gen
    source-registry.nix       Pinned source registry

  util/           Shared utilities (foundation layer)
    config.nix                Tokens, secrets, runtime tools
    darwin.nix                macOS SDK deps
    docker-helpers.nix        Docker build utilities
    release-helpers.nix       Release workflow helpers
    test-helpers.nix          Pure Nix eval test infra
    completions.nix           Shell completion gen
    repo-flake.nix            Universal flake builder
    monorepo-parts.nix        flake-parts monorepo module
    versioned-overlay.nix     N-track overlay gen
    flake-wrapper.nix         Flake boilerplate reduction

  devenv/         devenv.sh module templates (standalone)
    rust.nix, rust-service.nix, rust-tool.nix, rust-library.nix, leptos.nix, web.nix, nix.nix

  examples/       Deployment examples
    leptos-deploy.nix           Full Leptos PWA through all 3 renderers
    leptos-helm-values.nix      Helm values for Leptos SSR
    convergence-bridge.nix      Frontend in the convergence DAG
    leptos-tatara-jobspec.json  Tatara JobSpec for PWA
    leptos-wasi-config.json     WASI Preview 2 component config
```

### Dependency DAG

Modules follow a strict import hierarchy. Violations cause circular imports.

```
service/ ---> build/ ---> util/
infra/   ----------------> util/
codegen/ ----------------> util/
hm/      (standalone -- no internal deps, only nixpkgs.lib)
devenv/  (standalone -- devenv module format)
```

Cross-language imports within `build/` are prohibited (e.g., `rust/` cannot
import from `go/`). `util/` cannot import from any higher layer.

## Security-First Infrastructure

Every infrastructure module in `lib/infra/` enforces absolute least-privilege
as the default. Security is not optional -- it is built into the type signatures.

- **IAM**: Explicit allow-list, no wildcards (`*`) in resource ARNs or actions.
  Every service gets its own IAM role.
- **Encryption**: KMS encryption on all storage (S3, DynamoDB). Never
  platform-default keys.
- **Lifecycle**: `prevent_destroy` on all stateful resources. Destroy requires
  explicit override in a separate commit with PR review.
- **Tags**: `ManagedBy`, `Purpose`, `Environment`, `Team` required on every
  resource. Untagged resources fail validation.
- **Secrets**: Never in Nix store or Terraform state. Dynamic producers
  (Akeyless) with automatic rotation. Reference by path, not value.

See [docs/security.md](docs/security.md) for the full specification.

## Three-Layer Test Pyramid

Infrastructure is gated on tests. Tests must pass before `plan` or `apply`.

```
              Layer 3    InSpec live verification (post-apply, real cloud)
              Layer 2    RSpec architecture synthesis (zero cost, full graph)
              Layer 1    RSpec resource unit tests (instant, pure Ruby)
```

| Layer | Catches | Cost | Speed |
|-------|---------|------|-------|
| 1 | Logic errors, wrong defaults, missing validations | Zero | Milliseconds |
| 2 | Composition errors, missing deps, wrong wiring | Zero | Seconds |
| 3 | Provider bugs, API incompatibilities, permissions | Cloud | Minutes |

Every RSpec synthesis assertion has a corresponding InSpec control. What you
synthesize is what you verify. The gated workspace enforces the ordering:

```bash
nix run .#test      # Layer 1 + 2 (must pass)
nix run .#plan      # Only runs if test passed
nix run .#apply     # Only runs if test passed
nix run .#verify    # Layer 3 (post-apply)
```

See [docs/testing.md](docs/testing.md) for examples and the mirroring pattern.

## Typed Pangea Pattern

Architecture functions compose typed resource functions. The full resource graph
is synthesized in pure Ruby with zero cloud cost, then verified post-apply with
InSpec.

```ruby
# Architecture: typed functions composing typed functions
class StateBackend
  def synthesize
    kms = Resources.kms_key("#{@workspace}-state-key")
    bucket = Resources.s3_bucket("#{@workspace}-state", @region, kms_key_id: kms[:arn])
    table = Resources.dynamodb_table("#{@workspace}-locks", kms_key_id: kms[:arn])
    [kms, bucket, table]
  end
end
```

Configuration flows through the shikumi pattern: Nix evaluates options, writes
YAML, and the Pangea Ruby DSL reads it at runtime. No shell business logic
between Nix and application execution.

See [docs/adding-an-architecture.md](docs/adding-an-architecture.md) for the
full lifecycle.

## Quick Start

### Add as a flake input

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    substrate = {
      url = "github:pleme-io/substrate";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, substrate, ... }: let
    system = "aarch64-darwin";
    substrateLib = substrate.lib.${system};
  in {
    packages.${system}.default = substrateLib.mkCrate2nixProject { ... };
    devShells.${system}.default = substrateLib.mkDevShell { ... };
  };
}
```

### Import patterns

**Via `substrate.lib.${system}`** (recommended):

```nix
substrateLib = substrate.lib.${system};
packages.default = substrateLib.mkCrate2nixProject { ... };
```

**Via `substrate.libFor`** (when you need to pass forge):

```nix
substrateLib = substrate.libFor {
  inherit pkgs system;
  forge = inputs.forge.packages.${system}.forge;
};
```

**Standalone flake builders** (zero boilerplate):

```nix
# Rust tool:
outputs = (import "${substrate}/lib/build/rust/tool-release-flake.nix" {
  inherit nixpkgs crate2nix flake-utils;
}) { toolName = "kindling"; src = self; repo = "pleme-io/kindling"; };

# Ruby gem:
outputs = (import "${substrate}/lib/build/ruby/gem-flake.nix" {
  inherit nixpkgs ruby-nix flake-utils substrate forge;
}) { inherit self; name = "pangea-core"; };

# Pangea infra:
outputs = (import "${substrate}/lib/infra/pangea-infra-flake.nix" {
  inherit nixpkgs ruby-nix flake-utils substrate forge;
}) { inherit self; name = "my-infra"; };
```

**Standalone home-manager helpers** (no pkgs needed):

```nix
hmHelpers = import "${substrate}/lib/hm/service-helpers.nix" { lib = nixpkgs.lib; };
skillHelpers = import "${substrate}/lib/hm/skill-helpers.nix" { lib = nixpkgs.lib; };
mcpHelpers = import "${substrate}/lib/hm/mcp-helpers.nix" { lib = nixpkgs.lib; };
```

**High-level Rust service** (single-function interface):

```nix
let rustService = import "${substrate}/lib/build/rust/service.nix" {
  inherit system nixpkgs;
  nixLib = substrate;
  crate2nix = inputs.crate2nix;
  forge = inputs.forge.packages.${system}.forge;
};
in rustService {
  serviceName = "email";
  src = ./.;
  productName = "myapp";
  registryBase = "ghcr.io/myorg";
  enableAwsSdk = true;
}
# Returns: { packages, devShells, apps }
```

## API Reference

### Build

| Function | Source | Description |
|----------|--------|-------------|
| `mkRustOverlay` | `build/rust/overlay.nix` | Fenix stable overlay for crate2nix |
| `mkGoOverlay` | `build/go/overlay.nix` | Go from upstream source |
| `mkZigOverlay` | `build/zig/overlay.nix` | Prebuilt Zig + source zls |
| `mkSwiftOverlay` | `build/swift/overlay.nix` | Swift 6 from swift.org (Darwin) |
| `mkCrate2nixProject` | `build/rust/crate2nix-builders.nix` | Per-crate cached Rust build |
| `mkCrate2nixDockerImage` | `build/rust/crate2nix-builders.nix` | Multi-arch Docker image |
| `mkCrate2nixServiceApps` | `build/rust/crate2nix-apps.nix` | Full service app set |
| `mkCrate2nixTool` | `build/rust/crate2nix-builders.nix` | Standalone Rust CLI tools |
| `mkCrate2nixTestImage` | `build/rust/crate2nix-builders.nix` | Test runner image for CI |
| `mkGoTool` | `build/go/tool.nix` | Go CLI tool builder |
| `mkGoMonorepoSource` | `build/go/monorepo.nix` | Shared Go monorepo source |
| `mkGoMonorepoBinary` | `build/go/monorepo-binary.nix` | Binary from Go monorepo |
| `mkViteBuild` | `build/web/build.nix` | Vite/React builds |
| `mkDream2nixBuild` | `build/web/build.nix` | NPM with dream2nix |
| `mkTypescriptToolAuto` | `build/typescript/tool.nix` | Auto-discover TS tool |
| `mkTypescriptTool` | `build/typescript/tool.nix` | TS CLI tool with pleme-linker |
| `mkTypescriptPackage` | `build/typescript/library.nix` | TS library package |
| `mkRubyDockerImage` | `build/ruby/build.nix` | Ruby Docker image |
| `mkPythonPackage` | `build/python/package.nix` | Python package builder |
| `mkUvPythonPackage` | `build/python/uv.nix` | UV + pyproject.toml |
| `mkDotnetPackage` | `build/dotnet/build.nix` | .NET package builder |
| `mkJavaMavenPackage` | `build/java/maven.nix` | Maven package builder |
| `mkWasmBuild` | `build/wasm/build.nix` | Yew/WASM builds |
| `mkLeptosBuild` | `build/rust/leptos-build.nix` | Leptos SSR+CSR dual-target |
| `mkLeptosDockerImage` | `build/rust/leptos-build.nix` | Docker for Leptos SSR |
| `mkGitHubAction` | `build/web/github-action.nix` | GitHub Action builder |

### Service

| Function | Source | Description |
|----------|--------|-------------|
| `mkServiceApps` | `service/helpers.nix` | Docker compose + deployment |
| `mkEnvironmentServiceApps` | `service/environment-apps.nix` | Env-aware deployments |
| `mkProductSdlcApps` | `service/product-sdlc.nix` | Full SDLC app factory |
| `mkPlatformService` | `service/platform-service.nix` | Complete platform service |
| `mkImageReleaseApp` | `service/image-release.nix` | Multi-arch OCI release |
| `mkHelmSdlcApps` | `service/helm-build.nix` | Helm chart lifecycle |
| `mkHealthSupervisor` | `service/health-supervisor.nix` | Health check builder |
| `mkMigrationJob` | `service/db-migration.nix` | K8s migration Job manifest |

### Infrastructure

| Function | Source | Description |
|----------|--------|-------------|
| `pangeaInfraBuilder` | `infra/pangea-infra.nix` | Pangea project builder |
| `pangeaInfraFlakeBuilder` | `infra/pangea-infra-flake.nix` | Pangea flake wrapper |
| `mkTerraformModuleCheck` | `infra/terraform-module.nix` | TF validation derivation |
| `mkPulumiProvider` | `infra/pulumi-provider.nix` | Pulumi SDK generation (5 languages) |
| `mkAnsibleCollection` | `infra/ansible-collection.nix` | Ansible Galaxy packaging |

### Home-Manager

| Function | Source | Description |
|----------|--------|-------------|
| `hmServiceHelpers` | `hm/service-helpers.nix` | launchd/systemd patterns |
| `hmSkillHelpers` | `hm/skill-helpers.nix` | Claude Code skill deploy |
| `hmMcpHelpers` | `hm/mcp-helpers.nix` | MCP server management |
| `hmTypedConfigHelpers` | `hm/typed-config-helpers.nix` | Typed config generation |
| `nixosServiceHelpers` | `hm/nixos-service-helpers.nix` | NixOS module patterns |
| `testHelpers` | `util/test-helpers.nix` | Pure Nix eval tests |

### Utility

| Function | Source | Description |
|----------|--------|-------------|
| `mkDarwinBuildInputs` | `util/darwin.nix` | macOS SDK deps |
| `mkRuntimeToolsEnv` | `util/config.nix` | Runtime tool env vars |
| `mkVersionedOverlay` | `util/versioned-overlay.nix` | N-track overlay gen |
| `repoFlakeBuilder` | `util/repo-flake.nix` | Universal flake builder |
| `monorepoPartsModule` | `util/monorepo-parts.nix` | flake-parts module |

### Codegen

| Function | Source | Description |
|----------|--------|-------------|
| `mkOpenApiForge` | `codegen/openapi-forge.nix` | OpenAPI parsing + forge |
| `mkOpenApiSdk` | `codegen/openapi-sdk.nix` | Multi-language SDK gen |
| `mkOpenApiRustSdk` | `codegen/openapi-rust-sdk.nix` | Rust SDK gen |

## Backward Compatibility

All old flat paths (`lib/rust-overlay.nix`, `lib/go-tool.nix`, etc.) are
preserved as one-line shims that forward to the new location:

```nix
# lib/rust-overlay.nix
# Shim -- moved to build/rust/overlay.nix
import ./build/rust/overlay.nix
```

Rules:
- Shims are never removed. External consumers depend on the old paths.
- New code should use the new paths (`lib/build/rust/overlay.nix`).
- The `default.nix` public API (attribute names) is unchanged.

See [docs/migration.md](docs/migration.md) for the full old-to-new path mapping.

## Configuration

### Tokens

```bash
export ATTIC_TOKEN="your-attic-jwt-token"
export GHCR_TOKEN="your-github-token"
```

### Forge

Pass the deployment orchestrator via `forge` parameter:

```nix
substrateLib = substrate.libFor {
  inherit pkgs system;
  forge = inputs.forge.packages.${system}.forge;
};
```

When `forge` is not provided, commands fall back to looking for `forge` on `$PATH`.

## Scaffold System -- Generate Complete Projects

Scaffolds implement convergence computing: declare intent, scaffold converges
it into a complete project. Each scaffold matches a builder.

```nix
scaffold = import "${substrate}/lib/leptos-app-scaffold.nix" { inherit lib; };
app = scaffold.generate ({
  name = "my-product";
  primaryColor = "#6366f1";
} // scaffold.templates.standard);
# app.files -- 22 files ready to write to disk
# app.meta -- project metadata  
# app.deployment -- deployment spec for substrate archetypes
```

| Scaffold | Builder | What It Generates |
|----------|---------|-------------------|
| `leptosAppScaffold` | `leptosBuildFlakeBuilder` | Leptos PWA (22 files, auth + PWA + i18n) |
| `rustServiceScaffold` | `rustServiceFlakeBuilder` | Axum backend (GraphQL/REST, DB, health) |
| `rustToolScaffold` | `rustToolReleaseFlakeBuilder` | Clap CLI (config, completions) |
| `dioxusAppScaffold` | -- | Dioxus desktop/mobile app |
| `gpuAppScaffold` | -- | garasu+egaku+madori GPU app |
| `rubyGemScaffold` | `rubyGemFlakeBuilder` | Pangea IaC gem (RSpec) |

See [docs/scaffolds.md](docs/scaffolds.md) for all templates and options.

## Leptos Web Application Builders

Dual-target Leptos builds: SSR native binary + CSR WASM bundle.

| Function | Source | Description |
|----------|--------|-------------|
| `mkLeptosBuild` | `build/rust/leptos-build.nix` | SSR binary + CSR WASM + combined |
| `mkLeptosDockerImage` | `build/rust/leptos-build.nix` | Docker with SSR serving CSR |
| `mkLeptosDockerImageWithHanabi` | `build/rust/leptos-build.nix` | CSR-only via Hanabi BFF |
| `leptosBuildFlakeBuilder` | `build/rust/leptos-build-flake.nix` | Zero-boilerplate flake |

Devenv module: `lib/devenv/leptos.nix` (cargo-leptos, trunk, tailwindcss, wasm-bindgen, npm).

See [docs/adding-a-leptos-app.md](docs/adding-a-leptos-app.md).

## Unified Infrastructure Theory

Abstract workload archetypes render simultaneously to Kubernetes, Tatara, and WASI:

```nix
svc = archetypes.mkHttpService {
  name = "my-app"; image = "ghcr.io/org/app:latest";
  ports = [{ port = 3000; }]; health = { path = "/healthz"; };
};
# svc.kubernetes -- nix-kube compositions (Deployment + Service + SA + NP + HPA)
# svc.tatara -- JobSpec JSON (7 drivers: exec, oci, nix, kube, wasi, ...)
# svc.wasi -- WASI Component Model config (capability-based security)
```

7 archetypes: `mkHttpService`, `mkWorker`, `mkCronJob`, `mkGateway`,
`mkStatefulService`, `mkFunction`, `mkFrontend`.

See [docs/unified-infrastructure-theory.md](docs/unified-infrastructure-theory.md)
and [docs/metaframework.md](docs/metaframework.md).

## Metaframework

Substrate powers the pleme-io metaframework: declare application state once,
render through any backend (garasu GPU or Leptos web), deploy to any platform.

Framework crates powered by substrate:
- **pleme-app-core** -- state machines, cache, sanitization, convergence types + Leptos web providers
- **pleme-mui** -- 92 Material Web + MUI island components for Leptos
- **egaku** -- platform-agnostic widget state machines (pure Rust, WASM-safe)
- **irodori** -- color system (source of truth for theming)

See [docs/metaframework.md](docs/metaframework.md) and
[docs/convergence-application-theory.md](docs/convergence-application-theory.md).

## Further Reading

- [docs/scaffolds.md](docs/scaffolds.md) -- all 6 scaffold generators with templates
- [docs/metaframework.md](docs/metaframework.md) -- application framework architecture
- [docs/convergence-application-theory.md](docs/convergence-application-theory.md) -- manufacturing intent into computational reality
- [docs/adding-a-leptos-app.md](docs/adding-a-leptos-app.md) -- Leptos PWA scaffold + build + deploy
- [docs/unified-infrastructure-theory.md](docs/unified-infrastructure-theory.md) -- workload archetypes + renderers
- [docs/architecture.md](docs/architecture.md) -- layered design, dependency graph, flake structure
- [docs/security.md](docs/security.md) -- IAM, encryption, lifecycle, secrets, tagging
- [docs/testing.md](docs/testing.md) -- three-layer test pyramid, gated workspaces
- [docs/adding-a-builder.md](docs/adding-a-builder.md) -- step-by-step builder creation
- [docs/adding-an-architecture.md](docs/adding-an-architecture.md) -- Pangea architecture lifecycle
- [docs/migration.md](docs/migration.md) -- old-to-new path mapping

## License

MIT License - see [LICENSE](LICENSE) for details.
