# Substrate

Reusable Nix build patterns consumed by all pleme-io product and library repos.
This repo is PUBLIC. Never commit secrets, user-specific data, or private paths.

---

## Module Hierarchy

```
lib/
├── default.nix                    # Root aggregation — ALL public API surfaces
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
├── infra/                         # Infrastructure-as-Code patterns
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
build/ ----> util/       (OK: builders use config, darwin, docker helpers)
service/ --> build/      (OK: service patterns compose build outputs)
service/ --> util/       (OK: service patterns use config, release helpers)
infra/ ----> util/       (OK: infra uses config)
codegen/ --> util/       (OK: codegen uses source registry)
hm/ -------> (none)     (standalone: only needs nixpkgs.lib)
devenv/ ---> (none)     (standalone: devenv module format)

util/ -----> build/     (PROHIBITED: would create cycles)
util/ -----> service/   (PROHIBITED)
util/ -----> infra/     (PROHIBITED)
build/ ----> service/   (PROHIBITED)
build/ ----> infra/     (PROHIBITED)
```

Within `build/`, language directories are independent of each other.
Cross-language imports (e.g., `rust/` importing from `go/`) are prohibited.

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

#### Standalone Rust Flake Builders

These are imported directly from substrate (not via `lib.${system}`):

| Builder | Source | Description |
|---------|--------|-------------|
| `rust-tool-release-flake.nix` | `build/rust/tool-release-flake.nix` | CLI tool with 4-target GitHub releases |
| `rust-tool-image-flake.nix` | `build/rust/tool-image-flake.nix` | CLI tool as Docker image for K8s CronJobs/init containers |
| `rust-workspace-release-flake.nix` | `build/rust/tool-release-flake.nix` | Workspace CLI with `packageName` member selection |
| `rust-service-flake.nix` | `build/rust/service-flake.nix` | Dockerized microservice |
| `rust-library.nix` | `build/rust/library.nix` | crates.io library (check + test) |

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

---

## File Naming Conventions

- Builders: `mk{Thing}` (e.g., `mkCrate2nixProject`, `mkGoTool`)
- Flake wrappers: `*-flake.nix` (e.g., `service-flake.nix`, `gem-flake.nix`)
- Overlays: `overlay.nix` within each language directory
- Helpers: `*-helpers.nix` (e.g., `service-helpers.nix`, `docker-helpers.nix`)
- Standalone import paths: exposed as `*Builder` attrs (e.g., `rustLibraryBuilder`)
