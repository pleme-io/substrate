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
| `mutatingVerbsBuilder` | `infra/mutating-verbs.nix` | ★★ typed retirement of hand-run mutating verbs (see [`doctrine/mutating-verbs.md`](./doctrine/mutating-verbs.md)) |
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
| `duckdb.nix` (standalone, `{ lib }`) | `duckdb.nix` | DuckDB tuned per profile (`interactive`/`build`) from declared hardware; `wrap` bakes the settings in with `-init`, because `~/.duckdbrc` is read only by an interactive terminal. `checks.duckdb` + `checks.duckdb-wrapper` |

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

