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
│   ├── web/                       # build, docker, github-action
│   ├── helm/                      # chart (mkHelmChart), repo (mkHelmRepo),
│   │                              #   render (mkHelmRender), vendor (shared dep
│   │                              #   vendoring), quirk-apply
│   └── nixos/                     # aws-ami (NixOS → AWS AMI, packer + direct)
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
│   └── tests.nix                  # 57 pure eval tests (was "37" until counted 2026-07-28)
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
│   ├── pangea-arch-workspace.nix  # CANONICAL — subdirectory workspace
│   │                              # in pangea-architectures (six verbs:
│   │                              # plan/deploy/destroy/synth/test/import +
│   │                              # extraApps for custom verbs).
│   │                              # See pangea-architectures/docs/workspace-sdlc.md
│   ├── pangea-workspace.nix       # Nix->YAML->pangea (no .rb template,
│   │                              # whole config in Nix attrsets)
│   ├── pangea-infra.nix           # Top-level repo-as-workspace builder
│   ├── pangea-infra-flake.nix     # Top-level Pangea flake wrapper
│   ├── mutating-verbs.nix         # ★★ typed retirement of hand-run
│   │                              # mutating verbs (apply/destroy/init/
│   │                              # mutating flows). ONE surface, honoured
│   │                              # by every Pangea builder here.
│   ├── fleet-pangea-infra.nix     # Top-level repo with declarative
│   │                              # fleet flows in Nix
│   ├── fleet-pangea-infra-flake.nix # ^ flake wrapper
│   ├── ami-build.nix              # AMI build/test/promote pipeline
│   │                              #   mkBuildTemplate, mkTestTemplate,
│   │                              #   mkAmiBuildPipeline
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

