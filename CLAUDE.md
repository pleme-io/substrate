# Substrate

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
│   └── web/                       # build, docker, github-action
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
│   └── tests.nix                  # 37 pure eval tests
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
│   ├── pangea-workspace.nix       # Nix->YAML->pangea pattern
│   ├── pangea-infra.nix           # Per-system Pangea builder
│   ├── pangea-infra-flake.nix     # Zero-boilerplate Pangea flake
│   ├── ami-build.nix              # AMI build/test/promote pipeline
│   │                              #   mkBuildTemplate, mkTestTemplate,
│   │                              #   mkAmiBuildPipeline
│   ├── infra-workspace.nix        # DEPRECATED (shim kept)
│   ├── infra-state-backend.nix    # DEPRECATED (shim kept)
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

#### Standalone Rust Flake Builders

These are imported directly from substrate (not via `lib.${system}`):

| Builder | Source | Description |
|---------|--------|-------------|
| `rust-tool-release-flake.nix` | `build/rust/tool-release-flake.nix` | CLI tool with 4-target GitHub releases |
| `rust-tool-image-flake.nix` | `build/rust/tool-image-flake.nix` | CLI tool as Docker image for K8s CronJobs/init containers |
| `rust-workspace-release-flake.nix` | `build/rust/tool-release-flake.nix` | Workspace CLI with `packageName` member selection |
| `rust-service-flake.nix` | `build/rust/service-flake.nix` | Dockerized microservice |
| `rust-library.nix` | `build/rust/library.nix` | crates.io library (check + test) |
| `leptos-build-flake.nix` | `build/rust/leptos-build-flake.nix` | Zero-boilerplate Leptos PWA flake |

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

Standalone import: `types = import "${substrate}/lib/types" { lib = nixpkgs.lib; };`

Key type modules:
- `types.foundation` — NixSystem, Architecture, Language, ArtifactKind, ServiceType, etc.
- `types.ports` — Unified port types with `attrTag` + `coercedTo` for legacy compat
- `types.buildResult` — Universal output contract (`packages`, `devShells`, `apps`)
- `types.buildSpec` — Per-language typed input specs (rust, go, zig, ts, ruby, python, web, wasm)
- `types.serviceSpec` — HealthCheck, ScalingSpec, ResourceSpec, MonitoringSpec
- `types.deploySpec` — DockerImageSpec, DeploySpec, ReleaseSpec
- `types.infraSpec` — WorkloadSpec, PolicyRule, MultiTierAppSpec
- `types.kubeSpec` — KubeMetadata, SecurityContext, Probes, RBAC rules
- `types.validate` — `mkTypedBuilder`, `validateSpec`, `checkBuildResult`

### Kubernetes (nix-kube) — Standalone Import

These are imported directly from substrate, not via `lib.${system}`:

| Builder | Source | Description |
|---------|--------|-------------|
| nix-kube primitives | `kube/primitives/*.nix` | 29 pure K8s resource builders (no pkgs) |
| nix-kube compositions | `kube/compositions/*.nix` | 9 service archetypes (mkMicroservice, mkWorker, etc.) |
| nix-kube eval | `kube/eval.nix` | Dependency ordering + JSON serialization |
| nix-kube flake | `kube/flake.nix` | Zero-boilerplate K8s resource flake |
| nix-kube modules | `kube/modules/eval.nix` | NixOS-style overlay system |
| nix-kube tests | `kube/tests.nix` | 37 pure eval tests |

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
