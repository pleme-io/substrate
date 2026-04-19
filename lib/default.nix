# Substrate - Reusable Nix Build Patterns
# Provides parameterized functions for building, testing, and deploying services
#
# Module Organization:
#   build/       — Language-specific build patterns
#     rust/      — overlay, library, service-flake, tool-release, tool-image, devenv, crate2nix
#     go/        — overlay, tool, monorepo, monorepo-binary, library-check
#     zig/       — overlay, tool-release, tool-release-flake
#     swift/     — overlay
#     typescript/ — tool, library, library-flake
#     ruby/      — build, gem, gem-flake
#     python/    — package, uv
#     dotnet/    — build
#     java/      — maven
#     wasm/      — build, wasi-overlay, wasi-service, wasi-service-flake, wasi-component
#     web/       — build, docker, github-action
#   service/     — Service lifecycle (helpers, environment-apps, product-sdlc, image-release, helm-build, health-supervisor)
#   hm/          — home-manager integration (service-helpers, skill-helpers, mcp-helpers, typed-config-helpers, nixos-service-helpers)
#   infra/       — IaC patterns (pangea-infra, terraform-module, pulumi-provider, ansible-collection,
#                  argocd-appset, helm-values-composition, external-secrets, multi-tenant-naming,
#                  terraform-multi-tenant, environment-config)
#   codegen/     — Code generation (source-registry)
#   util/        — Shared utilities (config, darwin, test-helpers, versioned-overlay, repo-flake, monorepo-parts)
#   devenv/      — Devenv modules (rust, web, nix, android, gitops, infrastructure)
{
  pkgs,
  forge ? null,
  system ? null,
  crate2nix ? null,
  fenix ? null,
}: let
  # Import Rust overlay module (always available, doesn't need fenix at import time)
  rustOverlayModule = import ./build/rust/overlay.nix;

  # Import Go overlay module (builds Go from upstream source)
  goOverlayModule = import ./build/go/overlay.nix;

  # Import Zig overlay module (prebuilt compiler + from-source zls)
  zigOverlayModule = import ./build/zig/overlay.nix;

  # Import Swift overlay module (prebuilt Swift 6 from swift.org, Darwin-only)
  swiftOverlayModule = import ./build/swift/overlay.nix;

  # Helper to get forge command
  forgeCmd = if forge != null
    then "${forge}/bin/forge"
    else "forge";

  # Import modular components
  configModule = import ./util/config.nix { inherit pkgs; };
  healthSupervisorModule = import ./service/health-supervisor.nix { inherit pkgs; };
  typescriptToolModule = import ./build/typescript/tool.nix { inherit pkgs forgeCmd; };

  # Web build helpers
  webBuildModule = import ./build/web/build.nix { inherit pkgs; };

  # WASM build helpers (Yew/Rust WASM applications)
  wasmBuildModule = if fenix != null && crate2nix != null
    then import ./build/wasm/build.nix { inherit pkgs fenix crate2nix; }
    else {};

  # Leptos build helpers (SSR + CSR dual-target applications)
  leptosBuildModule = if fenix != null && crate2nix != null
    then import ./build/rust/leptos-build.nix { inherit pkgs fenix crate2nix; }
    else {};

  # WASI build helpers (wasm32-wasip2 services and components)
  wasiOverlayModule = import ./build/wasm/wasi-overlay.nix;

  # Web docker and deployment (needs config for tokens)
  webDockerModule = import ./build/web/docker.nix {
    inherit pkgs forgeCmd;
    inherit (configModule) defaultAtticToken defaultGhcrToken;
  };

  # Crate2nix builders
  crate2nixBuildersModule = import ./build/rust/crate2nix-builders.nix {
    inherit pkgs crate2nix;
  };

  # Crate2nix service apps
  crate2nixAppsModule = import ./build/rust/crate2nix-apps.nix {
    inherit pkgs forgeCmd;
    inherit (configModule) defaultAtticToken defaultGhcrToken mkRuntimeToolsEnv deploymentTools kubernetesTools;
  };

  # Service helpers (docker compose, test runners, etc.)
  serviceHelpersModule = import ./service/helpers.nix {
    inherit pkgs forgeCmd;
    inherit (configModule) defaultAtticToken defaultGhcrToken;
  };

  # Environment-aware deployment apps
  environmentAppsModule = import ./service/environment-apps.nix {
    inherit pkgs forgeCmd;
    inherit (configModule) defaultAtticToken defaultGhcrToken;
    inherit (webDockerModule) mkWebDeploymentApps;
    inherit (serviceHelpersModule) mkServiceApps;
  };

  # Generic multi-arch image release (uses forge CLI for push orchestration)
  imageReleaseModule = import ./service/image-release.nix { inherit pkgs forgeCmd; };

  # Ruby gem/service builders (Docker image, regen, push, release)
  rubyBuildModule = import ./build/ruby/build.nix {
    inherit pkgs forgeCmd;
    inherit (configModule) defaultGhcrToken;
  };

  # Helm chart build helpers (lint, package, push, release, bump — bump delegates to forge)
  helmBuildModule = import ./service/helm-build.nix { inherit pkgs forgeCmd; };

  # Shared cross-cutting middleware (typed, language-agnostic)
  sharedDockerModule = import ./build/shared/docker-image.nix { inherit pkgs; };
  sharedReleaseModule = import ./build/shared/release-app.nix { inherit pkgs forgeCmd; };
  sharedDevShellModule = import ./build/shared/devshell.nix { inherit pkgs; };

  # Hardened OCI bases + vendor rewrap (Path 2 — pleme-io owns Akeyless
  # image substrate; see arch-synthesizer::akeyless_image).
  ociHardenedModule = import ./build/oci/hardened-base.nix { inherit pkgs; };

  # K8s manifest primitives (metadata, syncPolicy, helm source — shared by appset + es)
  k8sManifestModule = import ./infra/k8s-manifest.nix;

  # ArgoCD ApplicationSet builder (cluster-generator, git-generator, matrix-generator)
  argocdAppSetModule = import ./infra/argocd-appset.nix;

  # Helm values composition hierarchy builder
  helmValuesCompositionModule = import ./infra/helm-values-composition.nix;

  # ExternalSecrets builder (vault-agnostic secret injection)
  externalSecretsModule = import ./infra/external-secrets.nix;

  # Multi-tenant resource naming conventions (pure — no pkgs)
  multiTenantNamingModule = import ./infra/multi-tenant-naming.nix;

  # Multi-tenant Terraform module patterns (KMS, IAM, failover, scaffolding)
  terraformMultiTenantModule = import ./infra/terraform-multi-tenant.nix;

  # Standalone Rust dev environment builder
  rustDevenvModule = import ./build/rust/devenv.nix { inherit pkgs; };

  # Devenv module paths for consumer repos
  devenvModulePaths = {
    rust = ./devenv/rust.nix;
    rust-service = ./devenv/rust-service.nix;
    rust-tool = ./devenv/rust-tool.nix;
    rust-library = ./devenv/rust-library.nix;
    web = ./devenv/web.nix;
    nix = ./devenv/nix.nix;
    android = ./devenv/android.nix;
    gitops = ./devenv/gitops.nix;
    infrastructure = ./devenv/infrastructure.nix;
  };

  # mkProductSdlcApps: configurable SDLC app factory.
  # Accepts { backendDir, infraServices } — all optional with sensible defaults.
  mkProductSdlcApps = import ./service/product-sdlc.nix {
    inherit pkgs forgeCmd;
  };

  # productSdlcApps: zero-config SDLC apps — backward-compat alias.
  productSdlcApps = mkProductSdlcApps {};

in rec {
  # Re-export forgeCmd for use in consumers
  inherit forgeCmd;

  # ============================================================================
  # TOKENS, SECRETS & RUNTIME TOOLS (from config.nix)
  # ============================================================================
  inherit (configModule)
    defaultAtticToken
    defaultGhcrToken
    runtimeTools
    mkRuntimeToolsEnv
    deploymentTools
    kubernetesTools
    allRuntimeTools;

  # ============================================================================
  # DARWIN BUILD HELPERS (from darwin.nix)
  # ============================================================================
  # Standard macOS SDK dependencies for Rust crates using TLS/networking.
  # Returns empty list on non-Darwin. Handles both old and new nixpkgs.
  #
  # Usage (instantiated):
  #   buildInputs = substrateLib.mkDarwinBuildInputs pkgs;
  #
  # Usage (standalone):
  #   darwinHelpers = import "${substrate}/lib/darwin.nix";
  #   buildInputs = darwinHelpers.mkDarwinBuildInputs pkgs;
  inherit ((import ./util/darwin.nix)) mkDarwinBuildInputs;
  darwinHelpers = ./util/darwin.nix;

  # ============================================================================
  # HEALTH SUPERVISOR BUILDER (from health-supervisor.nix)
  # ============================================================================
  inherit (healthSupervisorModule) mkHealthSupervisor;

  # ============================================================================
  # WEB BUILD HELPERS (from web-build.nix)
  # ============================================================================
  inherit (webBuildModule)
    mkViteBuild
    mkDream2nixBuild
    mkWebDevShell
    mkWebPackages
    mkWebLocalApps;

  # ============================================================================
  # WASM BUILD HELPERS (from wasm-build.nix)
  # ============================================================================
  mkWasmBuild = wasmBuildModule.mkWasmBuild or null;
  mkWasmDockerImage = wasmBuildModule.mkWasmDockerImage or null;
  mkWasmDockerImageWithHanabi = wasmBuildModule.mkWasmDockerImageWithHanabi or null;
  mkWasmDevShell = wasmBuildModule.mkWasmDevShell or null;
  wasmToolchain = wasmBuildModule.wasmToolchain or null;

  # ============================================================================
  # LEPTOS BUILD HELPERS (from leptos-build.nix)
  # ============================================================================
  # Dual-target Leptos application builders (SSR native + CSR WASM).
  #
  # mkLeptosBuild: Build SSR binary + CSR WASM bundle + combined deployment
  # mkLeptosDockerImage: Docker image with SSR binary serving CSR bundle
  # mkLeptosDockerImageWithHanabi: CSR-only served via Hanabi BFF
  #
  # Usage:
  #   result = mkLeptosBuild { name = "my-app"; src = ./.; };
  #   result.combined  -- SSR binary + CSR bundle
  #   result.packages  -- { default, ssrBinary, csrBundle }
  mkLeptosBuild = leptosBuildModule.mkLeptosBuild or null;
  mkLeptosDockerImage = leptosBuildModule.mkLeptosDockerImage or null;
  mkLeptosDockerImageWithHanabi = leptosBuildModule.mkLeptosDockerImageWithHanabi or null;
  mkLeptosDevShell = leptosBuildModule.mkLeptosDevShell or null;
  leptosWasmToolchain = leptosBuildModule.wasmToolchain or null;
  leptosNativeToolchain = leptosBuildModule.nativeToolchain or null;

  # ============================================================================
  # WASI BUILD HELPERS (from wasi-*.nix)
  # ============================================================================
  # WASI/Wasm infrastructure builders for wasm32-wasip2 services and components.
  #
  # mkWasiOverlay: Nix overlay providing wasiRustToolchain + wasiTools
  # mkWasiService: Rust source -> wasm32-wasip2 -> Docker image with wasmtime
  # mkWasiComponent: Rust source -> WASI Component Model artifact + WIT extraction
  #
  # Usage (overlay):
  #   pkgs = import nixpkgs { overlays = [ (substrateLib.mkWasiOverlay { inherit fenix; }) ]; };
  #
  # Usage (service):
  #   wasiSvc = import "${substrate}/lib/wasi-service.nix" { inherit pkgs; fenix = fenixPkgs; };
  #   result = wasiSvc { name = "my-svc"; src = ./.; };
  #   # result.wasmModule, result.dockerImage, result.devShell
  #
  # Usage (component):
  #   wasiComp = import "${substrate}/lib/wasi-component.nix" { inherit pkgs; fenix = fenixPkgs; };
  #   result = wasiComp { name = "my-comp"; src = ./.; };
  #   # result.component, result.wit, result.wasmModule
  mkWasiOverlay = wasiOverlayModule;
  mkWasiService = ./build/wasm/wasi-service.nix;
  mkWasiComponent = ./build/wasm/wasi-component.nix;

  # ============================================================================
  # WASI SERVICE FLAKE BUILDER (standalone import path)
  # ============================================================================
  # Complete multi-system flake outputs for a WASI service.
  # Wraps wasi-service.nix + eachSystem + overlays + flake-hygiene for
  # zero-boilerplate consumer flakes.
  #
  # Usage:
  #   outputs = (import "${substrate}/lib/wasi-service-flake.nix" {
  #     inherit nixpkgs substrate fenix;
  #   }) { inherit self; serviceName = "my-wasi-svc"; };
  wasiServiceFlakeBuilder = ./build/wasm/wasi-service-flake.nix;

  # ============================================================================
  # WEB DOCKER & DEPLOYMENT (from web-docker.nix)
  # ============================================================================
  inherit (webDockerModule)
    mkNodeDockerImage
    mkWebDeploymentApps;

  # ============================================================================
  # CRATE2NIX BUILDERS (from crate2nix-builders.nix)
  # ============================================================================
  inherit (crate2nixBuildersModule)
    mkCrate2nixProject
    mkCrate2nixTool
    mkCrate2nixDockerImage
    mkCrate2nixTestImage
    mkRustTestImage;

  # ============================================================================
  # CRATE2NIX SERVICE APPS (from crate2nix-apps.nix)
  # ============================================================================
  inherit (crate2nixAppsModule) mkCrate2nixServiceApps mkImagePushApp;

  # ============================================================================
  # SERVICE HELPERS (from service-helpers.nix)
  # ============================================================================
  inherit (serviceHelpersModule)
    mkDockerComposeConfig
    mkTestRunners
    mkDevShell
    mkChecks
    mkPackages
    mkMigrationJob
    mkMigrationJobApp
    mkComprehensiveReleaseApp
    mkServiceApps;

  # ============================================================================
  # ENVIRONMENT-AWARE DEPLOYMENT APPS (from environment-apps.nix)
  # ============================================================================
  inherit (environmentAppsModule)
    mkEnvironmentWebDeploymentApps
    mkEnvironmentServiceApps;

  # ============================================================================
  # PRODUCT SDLC APPS (from product-sdlc.nix)
  # ============================================================================
  # Ready-to-use app set for any product using the Rust + GraphQL + React stack.
  # Assign directly to `apps` in perSystem to get all standard SDLC commands
  # without the :<product> suffix.
  #
  # Example:
  #   apps = substrateLib.productSdlcApps;
  #   # Adds: release, build, rollback, prerelease, codegen, schema, sync,
  #   #       drift-check, validate-rebac, sync-dashboards, seed, unseed,
  #   #       test, test:unit, test:integration, test:e2e, test:ci, test:coverage,
  #   #       bench, infra:up, infra:down, infra:clean, migrate, migration-new
  inherit mkProductSdlcApps productSdlcApps;

  # ============================================================================
  # GENERIC IMAGE RELEASE (from image-release.nix)
  # ============================================================================
  # Multi-arch OCI image push to GHCR with standard tag convention.
  # Use mkImageReleaseApp for a single image, mkImageReleaseApps for multiple.
  #
  # Example (single):
  #   release = substrateLib.mkImageReleaseApp {
  #     name = "my-service";
  #     registry = "ghcr.io/myorg/my-service";
  #     mkImage = system: mkMyImage system;
  #   };
  #
  # Example (multiple):
  #   apps = substrateLib.mkImageReleaseApps {
  #     debug = { registry = "..."; mkImage = ...; };
  #     k8s   = { registry = "..."; mkImage = ...; };
  #   };
  inherit (imageReleaseModule) mkImageReleaseApp mkImageReleaseApps;

  # ============================================================================
  # TYPESCRIPT TOOL BUILDERS (from typescript-tool.nix)
  # ============================================================================
  inherit (typescriptToolModule)
    mkPlemeLinker
    fetchTypescriptDeps
    mkTypescriptManifestJson
    mkTypescriptPackage
    mkTypescriptTool
    mkTypescriptToolWithWorkspace
    mkTypescriptToolAuto
    mkTypescriptRegenApp;

  # ============================================================================
  # RUST OVERLAY (from rust-overlay.nix)
  # ============================================================================
  # Creates a Rust overlay using latest stable from fenix (1.90+)
  # Usage: pkgs = import nixpkgs { overlays = [ (substrateLib.mkRustOverlay { inherit fenix system; }) ]; };
  inherit (rustOverlayModule) mkRustOverlay getRustToolchain;

  # ============================================================================
  # GO OVERLAY (from go-overlay.nix)
  # ============================================================================
  # Builds Go from upstream source (go.dev) with NixOS-compatibility patches.
  # Full independence from nixpkgs Go version — single source of truth.
  # Usage: pkgs = import nixpkgs { overlays = [ (substrateLib.mkGoOverlay {}) ]; };
  inherit (goOverlayModule) mkGoOverlay getGoToolchain;

  # ============================================================================
  # ZIG OVERLAY (from zig-overlay.nix)
  # ============================================================================
  # Prebuilt Zig compiler from ziglang.org + zls built from source.
  # Usage: pkgs = import nixpkgs { overlays = [ (substrateLib.mkZigOverlay {}) ]; };
  inherit (zigOverlayModule) mkZigOverlay;

  # ============================================================================
  # SWIFT OVERLAY (from swift-overlay.nix)
  # ============================================================================
  # Prebuilt Swift 6 toolchain from swift.org (Darwin-only).
  # Usage: pkgs = import nixpkgs { overlays = [ (substrateLib.mkSwiftOverlay {}) ]; };
  inherit (swiftOverlayModule) mkSwiftOverlay;

  # ============================================================================
  # SWIFT OVERLAY MODULE (standalone import path)
  # ============================================================================
  # For consumers that need the Swift overlay as a standalone flake overlay.
  # Usage: overlays = [ (import "${substrate}/lib/swift-overlay.nix").mkSwiftOverlay {} ];
  swiftOverlay = ./build/swift/overlay.nix;

  # ============================================================================
  # ZIG OVERLAY MODULE (standalone import path)
  # ============================================================================
  # For consumers that need the Zig overlay as a standalone flake overlay.
  # Usage: overlays = [ (import "${substrate}/lib/zig-overlay.nix").mkZigOverlay {} ];
  zigOverlay = ./build/zig/overlay.nix;

  # ============================================================================
  # ZIG TOOL RELEASE BUILDER (standalone import path)
  # ============================================================================
  # Cross-platform Zig CLI tool builds + GitHub releases.
  # Uses Zig's built-in cross-compilation — all targets built on host.
  #
  # Usage:
  #   outputs = (import "${substrate}/lib/zig-tool-release-flake.nix" {
  #     inherit nixpkgs;
  #   }) { toolName = "z9s"; src = self; repo = "drzln/z9s"; };
  zigToolReleaseBuilder = ./build/zig/tool-release.nix;
  zigToolReleaseFlakeBuilder = ./build/zig/tool-release-flake.nix;

  # ============================================================================
  # GO OVERLAY MODULE (standalone import path)
  # ============================================================================
  # For consumers that need the Go overlay as a standalone flake overlay.
  # Usage: overlays = [ (import "${substrate}/lib/go-overlay.nix").mkGoOverlay {} ];
  goOverlay = ./build/go/overlay.nix;

  # ============================================================================
  # GO TOOL BUILDER (standalone import path)
  # ============================================================================
  # Reusable pattern for building Go CLI tools from upstream source.
  # Wraps buildGoModule with version ldflags injection, shell completions, and
  # standard meta attributes.
  #
  # Usage:
  #   goToolBuilder = import "${substrate}/lib/go-tool.nix";
  #   myTool = goToolBuilder.mkGoTool pkgs { pname = "my-tool"; ... };
  goToolBuilder = ./build/go/tool.nix;

  # ============================================================================
  # GO MONOREPO SOURCE FACTORY (standalone import path)
  # ============================================================================
  # Shared source + ldflags for Go projects that produce multiple binaries
  # from a single repository (e.g., kubernetes/kubernetes → kubelet, kubeadm,
  # kube-apiserver, kube-controller-manager, kube-scheduler, kube-proxy).
  #
  # Extends the Go toolchain story: mkGoTool builds one tool from one repo,
  # mkGoMonorepoSource provides the shared source for multiple binaries.
  #
  # Usage:
  #   mkGoMonorepoSource = (import "${substrate}/lib/go-monorepo.nix").mkGoMonorepoSource;
  #   k8sSrc = mkGoMonorepoSource pkgs {
  #     owner = "kubernetes"; repo = "kubernetes";
  #     version = "1.34.3"; srcHash = "sha256-...";
  #     versionPackage = "k8s.io/component-base/version";
  #   };
  goMonorepoBuilder = ./build/go/monorepo.nix;

  # ============================================================================
  # GO MONOREPO BINARY BUILDER (standalone import path)
  # ============================================================================
  # Builds a single binary from a Go monorepo source (extends mkGoMonorepoSource).
  # Wraps buildGoModule with per-binary metadata: pname, description, homepage,
  # optional shell completions.
  #
  # Usage:
  #   mkGoMonorepoBinary = (import "${substrate}/lib/go-monorepo-binary.nix").mkGoMonorepoBinary;
  #   kubelet = mkGoMonorepoBinary pkgs k8sSrc {
  #     pname = "kubelet";
  #     description = "Kubernetes node agent";
  #   };
  goMonorepoBinaryBuilder = ./build/go/monorepo-binary.nix;

  # ============================================================================
  # VERSIONED OVERLAY GENERATOR (standalone import path)
  # ============================================================================
  # Generates versioned overlay entries for N tracks × M components, plus
  # default and latest aliases. Eliminates cartesian-product boilerplate.
  #
  # Usage:
  #   mkVersionedOverlay = (import "${substrate}/lib/versioned-overlay.nix").mkVersionedOverlay;
  #   entries = mkVersionedOverlay {
  #     lib = nixpkgs.lib;
  #     tracks = [ "1.30" "1.34" "1.35" ];
  #     defaultTrack = "1.34"; latestTrack = "1.35";
  #     components = { kubelet = { src = k8sPkgs; }; };
  #   };
  versionedOverlay = ./util/versioned-overlay.nix;

  # ============================================================================
  # RUST SERVICE FLAKE BUILDER (standalone import path)
  # ============================================================================
  # Complete multi-system flake outputs for a Rust service.
  # Wraps rust-service.nix + eachSystem + homeManagerModules + nixosModules + overlays.
  #
  # Usage:
  #   outputs = (import "${substrate}/lib/rust-service-flake.nix" {
  #     inherit nixpkgs substrate forge crate2nix;
  #   }) { inherit self; serviceName = "hanabi"; registry = "ghcr.io/pleme-io/hanabi"; };
  rustServiceFlakeBuilder = ./build/rust/service-flake.nix;

  # ============================================================================
  # LEPTOS BUILD FLAKE BUILDER (standalone import path)
  # ============================================================================
  # Complete multi-system flake outputs for a Leptos web application.
  # Wraps leptos-build.nix + eachSystem + overlays for zero-boilerplate consumer
  # flakes. Produces SSR binary, CSR WASM bundle, Docker images, and dev shell.
  #
  # Usage:
  #   outputs = (import "${substrate}/lib/leptos-build-flake.nix" {
  #     inherit nixpkgs substrate;
  #   }) { inherit self; name = "lilitu-web"; };
  leptosBuildFlakeBuilder = ./build/rust/leptos-build-flake.nix;

  # ============================================================================
  # LEPTOS APP SCAFFOLD (standalone import path)
  # ============================================================================
  # Generate a complete Leptos PWA project structure from a declaration.
  # Implements convergence computing: declare -> scaffold -> build -> deploy.
  #
  # Usage:
  #   scaffold = import "${substrate}/lib/leptos-app-scaffold.nix" { inherit lib; };
  #   files = scaffold.generate {
  #     name = "my-app";
  #     displayName = "My App";
  #     features = [ "auth" "pwa" "i18n" ];
  #   };
  #
  # Templates: scaffold.templates.{minimal,standard,product,internal}
  leptosAppScaffold = ./build/rust/leptos-app-scaffold.nix;

  # ============================================================================
  # RUST SERVICE SCAFFOLD (Axum backend)
  # ============================================================================
  # Generate a complete Axum backend service with GraphQL/REST, DB, auth, health.
  # Usage: scaffold = import "${substrate}/lib/rust-service-scaffold.nix" { inherit lib; };
  #        app = scaffold.generate ({ name = "my-svc"; } // scaffold.templates.graphql);
  # Templates: scaffold.templates.{minimal,api,graphql,full}
  rustServiceScaffold = ./build/rust/rust-service-scaffold.nix;

  # ============================================================================
  # RUST TOOL SCAFFOLD (Clap CLI)
  # ============================================================================
  # Generate a complete Clap CLI tool with config, completions, MCP.
  # Usage: scaffold = import "${substrate}/lib/rust-tool-scaffold.nix" { inherit lib; };
  #        app = scaffold.generate ({ name = "my-tool"; } // scaffold.templates.standard);
  # Templates: scaffold.templates.{minimal,standard,mcp}
  rustToolScaffold = ./build/rust/rust-tool-scaffold.nix;

  # ============================================================================
  # DIOXUS APP SCAFFOLD (Desktop/Mobile)
  # ============================================================================
  # Generate a complete Dioxus desktop/mobile app with routing and theme.
  # Usage: scaffold = import "${substrate}/lib/dioxus-app-scaffold.nix" { inherit lib; };
  #        app = scaffold.generate ({ name = "my-app"; } // scaffold.templates.desktop);
  # Templates: scaffold.templates.{desktop,mobile,full}
  dioxusAppScaffold = ./build/rust/dioxus-app-scaffold.nix;

  # ============================================================================
  # GPU APP SCAFFOLD (garasu+egaku+madori)
  # ============================================================================
  # Generate a complete GPU-rendered application using the pleme GPU stack.
  # Usage: scaffold = import "${substrate}/lib/gpu-app-scaffold.nix" { inherit lib; };
  #        app = scaffold.generate ({ name = "my-gpu"; } // scaffold.templates.minimal);
  # Templates: scaffold.templates.{minimal,editor,media,full}
  gpuAppScaffold = ./build/rust/gpu-app-scaffold.nix;

  # ============================================================================
  # RUBY GEM SCAFFOLD (Library/Pangea provider)
  # ============================================================================
  # Generate a complete Ruby gem or Pangea IaC provider with RSpec.
  # Usage: scaffold = import "${substrate}/lib/ruby-gem-scaffold.nix" { inherit lib; };
  #        app = scaffold.generate ({ name = "my-gem"; } // scaffold.templates.library);
  # Templates: scaffold.templates.{library,pangea}
  rubyGemScaffold = ./build/ruby/ruby-gem-scaffold.nix;

  # ============================================================================
  # RUST LIBRARY BUILDER (from rust-library.nix)
  # ============================================================================
  # Standalone module for crates.io Rust library SDLC (build, check, publish).
  # Usage: import "${substrate}/lib/rust-library.nix" { inherit system nixpkgs; nixLib = substrate; crate2nix = inputs.crate2nix; };
  rustLibraryBuilder = ./build/rust/library.nix;

  # ============================================================================
  # RUST TOOL RELEASE BUILDER (standalone import path)
  # ============================================================================
  # Cross-platform CLI tool builds + GitHub releases.
  # Builds for 4 targets: aarch64-apple-darwin, x86_64-apple-darwin,
  # x86_64-unknown-linux-musl, aarch64-unknown-linux-musl.
  #
  # Usage:
  #   outputs = (import "${substrate}/lib/rust-tool-release-flake.nix" {
  #     inherit nixpkgs crate2nix flake-utils;
  #   }) { toolName = "kindling"; src = self; repo = "pleme-io/kindling"; };
  rustToolReleaseBuilder = ./build/rust/tool-release.nix;
  rustToolReleaseFlakeBuilder = ./build/rust/tool-release-flake.nix;

  # ============================================================================
  # TYPESCRIPT LIBRARY BUILDER (from typescript-library.nix)
  # ============================================================================
  # Standalone module for TypeScript library SDLC (build, check-all, devShell).
  # Usage: import "${substrate}/lib/typescript-library.nix" { inherit system nixpkgs dream2nix; };
  typescriptLibraryBuilder = ./build/typescript/library.nix;

  # ============================================================================
  # TYPESCRIPT LIBRARY FLAKE BUILDER (standalone import path)
  # ============================================================================
  # Complete multi-system flake outputs for a TypeScript library.
  # Wraps typescript-library.nix + eachSystem for zero-boilerplate consumer flakes.
  #
  # Usage:
  #   outputs = (import "${substrate}/lib/typescript-library-flake.nix" {
  #     inherit nixpkgs dream2nix substrate;
  #   }) { inherit self; name = "pleme-ui-components"; };
  typescriptLibraryFlakeBuilder = ./build/typescript/library-flake.nix;

  # ============================================================================
  # HOME-MANAGER SERVICE HELPERS (standalone import — no pkgs/system needed)
  # ============================================================================
  # Reusable patterns for daemon + MCP tool services (zoekt-mcp, codesearch, etc.).
  # Unlike other substrate exports, this is a standalone file path — consumers
  # import it directly with `{ lib }` since it only needs nixpkgs lib functions.
  #
  # Usage:
  #   hmHelpers = import "${substrate}/lib/hm-service-helpers.nix" { lib = nixpkgs.lib; };
  hmServiceHelpers = ./hm/service-helpers.nix;

  # ============================================================================
  # HOME-MANAGER FLAKE FRAGMENT HELPERS (standalone import — no pkgs/system needed)
  # ============================================================================
  # Option types and activation script generator for nix-place flake fragment
  # composition. Any blackmatter module can contribute fragments to any directory.
  #
  # Usage:
  #   fragmentHelpers = import "${substrate}/lib/hm/flake-fragment-helpers.nix" { lib = nixpkgs.lib; };
  #   imports = [ (fragmentHelpers.mkFlakeFragmentModule {}) ];  # uses pkgs.nix-place from overlay
  hmFlakeFragmentHelpers = ./hm/flake-fragment-helpers.nix;

  # ============================================================================
  # HOME-MANAGER CLAUDE.MD HELPERS (standalone import — no pkgs/system needed)
  # ============================================================================
  # Composable CLAUDE.md deployment at every directory level.
  # Any blackmatter module can contribute content to any directory path.
  #
  # Usage:
  #   claudeMdHelpers = import "${substrate}/lib/hm/claude-md-helpers.nix" { lib = nixpkgs.lib; };
  #   imports = [ (claudeMdHelpers.mkClaudeMdModule {}) ];
  hmClaudeMdHelpers = ./hm/claude-md-helpers.nix;

  # ============================================================================
  # NIXOS SERVICE HELPERS (standalone import — no pkgs/system needed)
  # ============================================================================
  # Reusable patterns for NixOS modules: systemd services, firewall rules,
  # kernel configuration, kubeconfig setup, and VM tests.
  #
  # Usage:
  #   nixosHelpers = import "${substrate}/lib/nixos-service-helpers.nix" { lib = nixpkgs.lib; };
  nixosServiceHelpers = ./hm/nixos-service-helpers.nix;

  # ============================================================================
  # TEST HELPERS (standalone import — no pkgs/system needed)
  # ============================================================================
  # Pure Nix evaluation test infrastructure for NixOS and home-manager modules.
  # Tests run as pure Nix evaluation — no VMs, no builds, instant results.
  #
  # Provides: mkTest, runTests, mkNixOSModuleStubs, evalNixOSModule,
  #           mkProfileEvalCheck
  #
  # Usage:
  #   testHelpers = import "${substrate}/lib/test-helpers.nix" { lib = nixpkgs.lib; };
  #   tests.unit = testHelpers.runTests [
  #     (testHelpers.mkTest "my-test" (1 + 1 == 2) "math works")
  #   ];
  testHelpers = ./util/test-helpers.nix;

  # ============================================================================
  # RUBY GEM BUILDER (standalone import path)
  # ============================================================================
  # Per-system Ruby gem builder (follows rust-library.nix pattern).
  # Takes system-level deps, returns a function that produces { devShells, apps }.
  #
  # Usage:
  #   rubyGem = import "${substrate}/lib/ruby-gem.nix" {
  #     inherit nixpkgs system ruby-nix substrate forge;
  #   };
  #   outputs = rubyGem { inherit self; name = "pangea-core"; };
  rubyGemBuilder = ./build/ruby/gem.nix;

  # ============================================================================
  # RUBY GEM FLAKE BUILDER (standalone import path)
  # ============================================================================
  # Complete multi-system flake outputs for a Ruby gem library.
  # Wraps ruby-gem.nix + eachSystem for zero-boilerplate consumer flakes.
  #
  # Usage:
  #   outputs = (import "${substrate}/lib/ruby-gem-flake.nix" {
  #     inherit nixpkgs ruby-nix flake-utils substrate forge;
  #   }) { inherit self; name = "pangea-core"; };
  rubyGemFlakeBuilder = ./build/ruby/gem-flake.nix;

  # ============================================================================
  # PANGEA INFRASTRUCTURE BUILDER (standalone import path)
  # ============================================================================
  # Per-system Pangea infrastructure project builder (follows ruby-gem.nix pattern).
  # Takes system-level deps, returns a function that produces { devShells, apps }.
  # Apps: validate, plan, apply, destroy, init, test, drift, regen.
  #
  # Usage:
  #   pangeaInfra = import "${substrate}/lib/pangea-infra.nix" {
  #     inherit nixpkgs system ruby-nix substrate forge;
  #   };
  #   outputs = pangeaInfra { inherit self; name = "my-infra"; };
  pangeaInfraBuilder = ./infra/pangea-infra.nix;

  # ============================================================================
  # PANGEA INFRASTRUCTURE FLAKE BUILDER (standalone import path)
  # ============================================================================
  # Complete multi-system flake outputs for a Pangea infrastructure project.
  # Wraps pangea-infra.nix + eachSystem for zero-boilerplate consumer flakes.
  #
  # Usage:
  #   outputs = (import "${substrate}/lib/pangea-infra-flake.nix" {
  #     inherit nixpkgs ruby-nix flake-utils substrate forge;
  #   }) { inherit self; name = "my-infra"; };
  pangeaInfraFlakeBuilder = ./infra/pangea-infra-flake.nix;

  # ============================================================================
  # FLEET + PANGEA INFRASTRUCTURE BUILDER (standalone import path)
  # ============================================================================
  # Per-system Fleet + Pangea infrastructure project builder. Extends
  # pangea-infra.nix with Fleet DAG orchestration. Generates fleet.yaml
  # from Nix attrsets (shikumi pattern), wraps fleet+pangea+tofu into apps.
  #
  # Apps: flow-{name} (per-flow), flow-list, plan, apply, destroy, validate,
  #       test, drift, regen.
  #
  # Usage:
  #   fleetPangeaInfra = import "${substrate}/lib/infra/fleet-pangea-infra.nix" {
  #     inherit nixpkgs system ruby-nix substrate forge;
  #     fleet = inputs.fleet;
  #   };
  #   outputs = fleetPangeaInfra {
  #     inherit self;
  #     name = "my-infra";
  #     flows = { deploy = { ... }; };
  #   };
  fleetPangeaInfraBuilder = ./infra/fleet-pangea-infra.nix;

  # ============================================================================
  # FLEET + PANGEA INFRASTRUCTURE FLAKE BUILDER (standalone import path)
  # ============================================================================
  # Complete multi-system flake outputs for a Fleet + Pangea infrastructure
  # project. Wraps fleet-pangea-infra.nix + eachSystem for zero-boilerplate.
  #
  # Usage:
  #   outputs = (import "${substrate}/lib/fleet-pangea-infra-flake.nix" {
  #     inherit nixpkgs ruby-nix flake-utils substrate forge fleet;
  #   }) { inherit self; name = "my-infra"; flows = { ... }; };
  fleetPangeaInfraFlakeBuilder = ./infra/fleet-pangea-infra-flake.nix;

  # ============================================================================
  # GATED PANGEA WORKSPACE BUILDER (standalone import path)
  # ============================================================================
  # Wraps pangea-workspace.nix with RSpec test gates. Infrastructure is NEVER
  # instantiated without passing the full test suite.
  #
  # Usage:
  #   mkGatedPangeaWorkspace = import "${substrate}/lib/infra/gated-pangea-workspace.nix" {
  #     inherit pkgs; pangea = ...; ruby = pkgs.ruby_3_3;
  #   };
  #   workspace = mkGatedPangeaWorkspace {
  #     name = "k3s-dev"; architecture = "k3s_cluster_iam";
  #     architecturesSrc = inputs.pangea-architectures;
  #   };
  gatedPangeaWorkspaceBuilder = ./infra/gated-pangea-workspace.nix;

  # ============================================================================
  # INFRASTRUCTURE SDLC (standalone import path)
  # ============================================================================
  # Complete lifecycle apps for gated Pangea workspaces. Encapsulates the full
  # cycle: rspec → plan → apply → inspec → destroy as reusable nix apps.
  #
  # Usage:
  #   mkInfraSdlc = import "${substrate}/lib/infra/infra-sdlc.nix" {
  #     inherit pkgs; pangea = ...; ruby = pkgs.ruby_3_3;
  #   };
  #   apps = mkInfraSdlc {
  #     name = "k3s-dev"; architecture = "k3s_cluster_iam";
  #     architecturesSrc = inputs.pangea-architectures;
  #   };
  #   # Gets: cycle, cycle-destroy, drift, validate, test, plan, apply, verify,
  #   #        deploy, plan-ungated, apply-ungated, destroy, show, status, ...
  infraSdlcBuilder = ./infra/infra-sdlc.nix;

  # ============================================================================
  # AMI BUILD PIPELINE (from infra/ami-build.nix)
  # ============================================================================
  # Reusable AMI build + test pipeline apps using ami-forge + Packer.
  # Generates 7 nix run apps: build, build-tested, build-vpn-tested,
  # build-full, boot-test, vpn-test, status.
  #
  # Usage:
  #   amiBuild = import "${substrate}/lib/infra/ami-build.nix" { inherit pkgs; };
  #   apps = amiBuild.mkAmiBuildApps {
  #     forgePackage = inputs.ami-forge.packages.${system}.default;
  #     packerTemplate = self.packages.${system}.packer-template;
  #     ssmParameter = "/my/ssm/param";
  #   };
  #   packages.packer-template = amiBuild.mkPackerTemplate {
  #     amiName = "my-ami";
  #     flakeRef = "github:my-org/my-profiles#builder";
  #     provisionerScript = [ "nixos-rebuild switch --flake $FLAKE_REF" ];
  #   };
  amiBuildBuilder = ./infra/ami-build.nix;

  # ============================================================================
  # CLOUDWATCH METRIC PUBLISHER (from infra/cloudwatch-metric-publisher.nix)
  # ============================================================================
  # Reusable NixOS module that publishes custom CloudWatch metrics on a
  # systemd timer cadence. Feeds custom alarms (e.g. arch-synthesizer
  # `AtticQuiescentTriggerDecl` / `BuilderQuiescentTriggerDecl`) so the
  # alarm fires as soon as the metric goes to zero.
  #
  # Usage (in a NixOS config for an AMI):
  #   imports = [ (import "${substrate}/lib/infra/cloudwatch-metric-publisher.nix") ];
  #   pleme.metrics = {
  #     enable = true;
  #     publishers.atticWriteCount = {
  #       namespace = "Pleme/Attic";
  #       metricName = "WriteCount";
  #       intervalSecs = 10;
  #       command = "ss -tHn state established '( sport = :8080 or sport = :443 )' | wc -l | tr -d ' '";
  #     };
  #   };
  cloudwatchMetricPublisherModule = ./infra/cloudwatch-metric-publisher.nix;

  # ============================================================================
  # RUBY BUILD HELPERS (from ruby-build.nix)
  # ============================================================================
  # Build Docker images, regenerate gemset.nix, push/release Ruby services.
  #
  # Example (full service with Docker image):
  #   apps = substrateLib.mkRubyServiceApps {
  #     srcDir = self;
  #     imageOutput = "dockerImage";
  #     registry = "ghcr.io/myorg/my-ruby-app";
  #     name = "my-ruby-app";
  #   };
  #   # Adds: regen:my-ruby-app, push:my-ruby-app, release:my-ruby-app
  #
  # Example (gem library — regen only):
  #   apps.regen = substrateLib.mkRubyRegenApp {
  #     srcDir = self;
  #     name = "my-gem";
  #   };
  inherit (rubyBuildModule)
    mkRubyDockerImage
    mkRubyRegenApp
    mkRubyPushApp
    mkRubyServiceApps
    mkRubyGemBumpApp
    mkRubyGemBuildApp
    mkRubyGemPushApp
    mkRubyGemApps;

  # ============================================================================
  # HELM CHART BUILD HELPERS (from helm-build.nix)
  # ============================================================================
  # Lint, package, push, and release Helm charts to OCI registries.
  # Use mkHelmSdlcApps for a single chart, mkHelmAllApps for multiple.
  #
  # Example (single chart):
  #   apps = substrateLib.mkHelmSdlcApps {
  #     name = "pleme-microservice";
  #     chartDir = ./charts/pleme-microservice;
  #     libChartDir = ./charts/pleme-lib;
  #   };
  #
  # Example (all charts):
  #   apps = substrateLib.mkHelmAllApps {
  #     libChartDir = ./charts/pleme-lib;
  #     charts = [
  #       { name = "pleme-microservice"; chartDir = ./charts/pleme-microservice; }
  #       { name = "pleme-worker"; chartDir = ./charts/pleme-worker; }
  #     ];
  #   };
  inherit (helmBuildModule)
    mkHelmLintApp
    mkHelmPackageApp
    mkHelmPushApp
    mkHelmReleaseApp
    mkHelmTemplateApp
    mkHelmBumpApp
    mkHelmSdlcApps
    mkHelmAllApps;

  # ============================================================================
  # RUST DEV ENVIRONMENT (from rust-devenv.nix)
  # ============================================================================
  # Standalone Rust devShell builder with optional tool sets.
  # Use when you need a dev environment without the full rust-service.nix pipeline.
  #
  # Requires substrate rust overlay applied to pkgs (for fenixRustToolchain).
  #
  # Example:
  #   devShells.default = substrateLib.mkRustDevShell {
  #     withSqlite = true;
  #     withHelm = true;
  #     extraPackages = [ pkgs.protobuf ];
  #   };
  inherit (rustDevenvModule) mkRustDevShell;

  # ============================================================================
  # GO LIBRARY CHECK BUILDER (standalone import path)
  # ============================================================================
  # Verifies a Go library compiles without producing a binary.
  # For external SDK repos where you want build verification as a Nix derivation.
  #
  # Usage:
  #   goLibCheckBuilder = import "${substrate}/lib/go-library-check.nix";
  #   sdk-check = goLibCheckBuilder.mkGoLibraryCheck pkgs {
  #     pname = "my-sdk"; version = "1.0"; src = ...; vendorHash = "sha256-...";
  #   };
  goLibraryCheckBuilder = ./build/go/library-check.nix;

  # Instantiated version (requires pkgs from substrate)
  inherit ((import ./build/go/library-check.nix)) mkGoLibraryCheck mkGoLibraryCheckOverlay;

  # ============================================================================
  # PYTHON PACKAGE BUILDER (standalone import path)
  # ============================================================================
  # Reusable pattern for building Python packages from external source.
  # Wraps buildPythonPackage with common conventions for external SDKs.
  #
  # Usage:
  #   pythonPkgBuilder = import "${substrate}/lib/python-package.nix";
  #   sdk = pythonPkgBuilder.mkPythonPackage pkgs {
  #     pname = "my-sdk"; version = "1.0"; src = ...;
  #     propagatedBuildInputs = with pkgs.python3Packages; [ requests ];
  #   };
  pythonPackageBuilder = ./build/python/package.nix;

  inherit ((import ./build/python/package.nix)) mkPythonPackage mkPythonPackageOverlay;

  # ============================================================================
  # PYTHON UV BUILDER (standalone import path)
  # ============================================================================
  # Modern Python package builder using UV and pyproject.toml.
  # Default builder for Python projects. Uses pyproject.toml format with
  # configurable build backend (setuptools, hatchling, flit-core, etc.).
  # Also provides mkUvDevShell for Python + UV development environments.
  #
  # Usage (package):
  #   uvPythonBuilder = import "${substrate}/lib/python-uv.nix";
  #   pkg = uvPythonBuilder.mkUvPythonPackage pkgs {
  #     pname = "my-pkg"; version = "1.0"; src = ...;
  #     propagatedBuildInputs = with pkgs.python3Packages; [ requests ];
  #   };
  #
  # Usage (dev shell):
  #   devShells.default = uvPythonBuilder.mkUvDevShell pkgs {
  #     extraPackages = [ pkgs.postgresql ];
  #   };
  uvPythonBuilder = ./build/python/uv.nix;

  inherit ((import ./build/python/uv.nix)) mkUvPythonPackage mkUvPythonPackageOverlay mkUvDevShell;

  # ============================================================================
  # GITHUB ACTION BUILDER (standalone import path)
  # ============================================================================
  # Builds GitHub Actions that use @vercel/ncc to bundle into dist/.
  # Handles npm install → ncc build → copy dist/ + action.yml.
  #
  # Usage:
  #   actionBuilder = import "${substrate}/lib/github-action.nix";
  #   action = actionBuilder.mkGitHubAction pkgs {
  #     pname = "my-action"; src = ./.; npmDepsHash = "sha256-...";
  #   };
  githubActionBuilder = ./build/web/github-action.nix;

  inherit ((import ./build/web/github-action.nix)) mkGitHubAction mkGitHubActionOverlay;

  # ============================================================================
  # JAVA MAVEN PACKAGE BUILDER (standalone import path)
  # ============================================================================
  # Reusable pattern for building Java packages from Maven-based source.
  # Wraps maven.buildMavenPackage with common conventions for external SDKs.
  #
  # Usage:
  #   javaMavenBuilder = import "${substrate}/lib/java-maven.nix";
  #   sdk = javaMavenBuilder.mkJavaMavenPackage pkgs {
  #     pname = "akeyless-java"; version = "4.3.0"; src = ...;
  #     mvnHash = "sha256-...";
  #   };
  javaMavenBuilder = ./build/java/maven.nix;

  inherit ((import ./build/java/maven.nix)) mkJavaMavenPackage mkJavaMavenPackageOverlay;

  # ============================================================================
  # .NET PACKAGE BUILDER (standalone import path)
  # ============================================================================
  # Reusable pattern for building .NET/C# packages from source.
  # Wraps buildDotnetModule with common conventions for external SDKs.
  #
  # Usage:
  #   dotnetBuilder = import "${substrate}/lib/dotnet-build.nix";
  #   sdk = dotnetBuilder.mkDotnetPackage pkgs {
  #     pname = "akeyless-csharp"; version = "4.3.0"; src = ...;
  #     nugetDeps = ./deps.json;
  #   };
  dotnetBuilder = ./build/dotnet/build.nix;

  inherit ((import ./build/dotnet/build.nix)) mkDotnetPackage mkDotnetPackageOverlay;

  # ============================================================================
  # TERRAFORM MODULE BUILDER (standalone import path)
  # ============================================================================
  # Validates Terraform modules (init + validate + fmt check + tflint).
  # Produces a derivation that succeeds only if the module is valid.
  #
  # Usage:
  #   tfBuilder = import "${substrate}/lib/terraform-module.nix";
  #   check = tfBuilder.mkTerraformModuleCheck pkgs {
  #     pname = "my-tf-module"; version = "1.0"; src = ./.;
  #   };
  terraformModuleBuilder = ./infra/terraform-module.nix;

  inherit ((import ./infra/terraform-module.nix)) mkTerraformModuleCheck mkTerraformDevShell mkTerraformModuleCheckOverlay;

  # ============================================================================
  # SOURCE REGISTRY (standalone import path)
  # ============================================================================
  # Centralized, pinned source registry from GitHub repos.
  # Single place to track versions, revisions, and hashes for external repos.
  #
  # Usage:
  #   mkSourceRegistry = import "${substrate}/lib/source-registry.nix";
  #   sources = mkSourceRegistry {
  #     inherit (pkgs) fetchFromGitHub;
  #     repos = { cli = { owner = "org"; repo = "cli"; rev = "abc"; hash = "sha256-..."; }; };
  #   };
  sourceRegistryBuilder = ./codegen/source-registry.nix;

  # ============================================================================
  # UNIVERSAL REPO FLAKE BUILDER (standalone import path)
  # ============================================================================
  # Single abstraction for all repo types. Eliminates flake.nix boilerplate.
  # Maps (language, builder) to the correct substrate pattern and devShell.
  #
  # Usage:
  #   outputs = inputs: (import "${inputs.substrate}/lib/repo-flake.nix" {
  #     inherit (inputs) nixpkgs flake-utils;
  #   }) {
  #     self = inputs.self;
  #     language = "go";
  #     builder = "tool";
  #     pname = "my-tool";
  #     vendorHash = "sha256-...";
  #     description = "My Go tool";
  #   };
  repoFlakeBuilder = ./util/repo-flake.nix;

  # ============================================================================
  # SKILL DEPLOYMENT HELPERS (standalone import path)
  # ============================================================================
  # Auto-discovery and deployment of Claude Code skills from a skills/ directory.
  # Any repo with a skills/ dir can use this to deploy SKILL.md files to
  # ~/.claude/skills/{name}/SKILL.md via home-manager.
  #
  # Usage:
  #   skillHelpers = import "${substrate}/lib/hm-skill-helpers.nix" { lib = nixpkgs.lib; };
  #   options.myModule.skills = skillHelpers.mkSkillOptions;
  #   config = mkIf cfg.skills.enable (skillHelpers.mkSkillConfig {
  #     skillsDir = ../skills;
  #   });
  hmSkillHelpers = ./hm/skill-helpers.nix;

  # ============================================================================
  # MCP SERVER DEPLOYMENT HELPERS (standalone import path)
  # ============================================================================
  # Reusable patterns for AI coding agent MCP server management.
  # Provides option types (mcpServerOpts, agentOpts), wrapper script generation,
  # server resolution, per-agent filtering, and config deployment.
  #
  # Usage:
  #   mcpHelpers = import "${substrate}/lib/hm-mcp-helpers.nix" { lib = nixpkgs.lib; };
  #   options.mcp.servers = mkOption {
  #     type = types.attrsOf (types.submodule mcpHelpers.mcpServerOpts);
  #   };
  hmMcpHelpers = ./hm/mcp-helpers.nix;

  # ============================================================================
  # TYPED CONFIGURATION HELPERS (standalone import path)
  # ============================================================================
  # Reusable patterns for generating config files (JSON/YAML) from typed
  # Nix options. Provides conditional attribute builders (optAttr, optList,
  # optNested) and config file deployment helpers.
  #
  # Usage:
  #   configHelpers = import "${substrate}/lib/hm-typed-config-helpers.nix" { lib = nixpkgs.lib; };
  #   home.file = configHelpers.mkJsonConfig {
  #     path = ".config/app/config.json";
  #     config = { theme = "nord"; };
  #   };
  hmTypedConfigHelpers = ./hm/typed-config-helpers.nix;

  # ============================================================================
  # PULUMI PROVIDER BUILDER (standalone import path)
  # ============================================================================
  # Generate multi-language SDKs from a Pulumi schema.json.
  # Produces TypeScript, Python, Go, C#, and Java packages using
  # `pulumi package gen-sdk`.
  #
  # Usage:
  #   pulumiBuilder = import "${substrate}/lib/pulumi-provider.nix";
  #   outputs = pulumiBuilder.mkPulumiProvider pkgs {
  #     name = "akeyless"; version = "0.1.0"; schema = ./schema.json;
  #   };
  pulumiProviderBuilder = ./infra/pulumi-provider.nix;

  inherit ((import ./infra/pulumi-provider.nix)) mkPulumiProvider;

  # ============================================================================
  # ANSIBLE COLLECTION BUILDER (standalone import path)
  # ============================================================================
  # Package generated Ansible modules into a Galaxy collection with build,
  # install, publish, lint, check-all, and bump apps.
  #
  # Usage:
  #   ansibleBuilder = import "${substrate}/lib/ansible-collection.nix";
  #   outputs = ansibleBuilder.mkAnsibleCollection pkgs {
  #     namespace = "pleme"; name = "akeyless"; version = "0.1.0"; src = ./.;
  #   };
  ansibleCollectionBuilder = ./infra/ansible-collection.nix;

  inherit ((import ./infra/ansible-collection.nix)) mkAnsibleCollection;

  # ============================================================================
  # K8S MANIFEST PRIMITIVES (from k8s-manifest.nix)
  # ============================================================================
  # Shared pure functions for building K8s manifest attrsets. Used internally
  # by argocd-appset.nix and external-secrets.nix. Also available for custom
  # manifest construction.
  #
  # Example:
  #   meta = substrateLib.mkK8sMetadata { name = "my-app"; namespace = "prod"; };
  #   sync = substrateLib.mkSyncPolicy { autoSync = true; prune = true; };
  inherit (k8sManifestModule)
    mkMetadata
    mkSyncPolicy
    mkHelmSource
    mkApplicationSet
    mkAppTemplate
    mkClusterSelector
    mkManifestGeneratePaths;
  # Rename to avoid collision with other mkMetadata functions
  mkK8sMetadata = k8sManifestModule.mkMetadata;
  k8sManifestBuilder = ./infra/k8s-manifest.nix;

  # ============================================================================
  # ARGOCD APPLICATIONSET BUILDER (from argocd-appset.nix)
  # ============================================================================
  # Generate ArgoCD ApplicationSet manifests from Nix attrsets.
  # Supports cluster-generator, git-generator, and matrix-generator strategies.
  # Includes common ignoreDifferences presets (HPA, webhooks, configmaps).
  #
  # Example (cluster-generator):
  #   appSet = substrateLib.mkClusterAppSet {
  #     name = "api-gateway";
  #     repoURL = "git@github.com:myorg/envs.git";
  #     chartPath = "helm/api-gateway";
  #     clusterLabel = "api-gateway";
  #     excludeTenants = [ "old-customer" ];
  #     valuesHierarchy = [
  #       "envs/global/{{.metadata.labels.environment}}/values.yaml"
  #       "envs/{{tenant}}/{{.metadata.labels.environment}}/{{.metadata.labels.cloudProvider}}/{{.metadata.labels.region}}/values.yaml"
  #     ];
  #   };
  #
  # Example (git-generator):
  #   appSet = substrateLib.mkGitAppSet {
  #     name = "ingress-nginx";
  #     repoURL = "git@github.com:myorg/envs.git";
  #     chartPath = "helm/ingress-nginx";
  #     filePaths = [ "envs/**/config.json" ];
  #   };
  #
  # Example (batch generation):
  #   yamls = substrateLib.mkAppSetSuite {
  #     services = {
  #       api-gateway = { repoURL = "..."; chartPath = "..."; clusterLabel = "api-gateway"; ... };
  #       monitoring  = { repoURL = "..."; chartPath = "..."; clusterLabel = "datadog"; ... };
  #     };
  #   };
  inherit (argocdAppSetModule)
    mkClusterAppSet
    mkClusterAppSetYaml
    mkAppSetYaml
    mkGitAppSet
    mkMatrixAppSet
    mkAppSetSuite
    resolveValuePaths
    resolveHelmParams
    ignoreDifferencesPresets;
  argocdAppSetBuilder = ./infra/argocd-appset.nix;

  # ============================================================================
  # HELM VALUES COMPOSITION HIERARCHY (from helm-values-composition.nix)
  # ============================================================================
  # Multi-tenant, multi-environment Helm value file management.
  # Generates ArgoCD valueFile paths, validates directory layout,
  # scaffolds missing files, and diffs between environments.
  #
  # Example:
  #   values = substrateLib.mkValuesHierarchy {
  #     name = "my-platform";
  #     tenants = [ "global" "customer-a" "customer-b" ];
  #     environments = [ "staging" "production" ];
  #     cloudProviders = [ "AWS" "AZR" ];
  #     regions = { AWS = [ "us-east-1" "eu-west-1" ]; AZR = [ "eastus2" ]; };
  #     services = [ "api-gateway" "config" ];
  #   };
  #   # values.argocdValuePaths → list of GoTemplate paths for ApplicationSets
  #   # values.validate → nix app to validate directory structure
  #   # values.scaffold → nix app to create missing files
  #   # values.diff → nix app to diff between environments
  inherit (helmValuesCompositionModule) mkValuesHierarchy;
  helmValuesCompositionBuilder = ./infra/helm-values-composition.nix;

  # ============================================================================
  # EXTERNAL SECRETS BUILDER (from external-secrets.nix)
  # ============================================================================
  # Generate Kubernetes ExternalSecret manifests for any secret store backend.
  # Supports Akeyless, AWS Secrets Manager, HashiCorp Vault, Azure Key Vault, GCP.
  #
  # Example (Nix manifest):
  #   es = substrateLib.mkExternalSecret {
  #     name = "db-credentials";
  #     secretStoreName = "cluster-secret-store";
  #     secrets = [
  #       { secretKey = "password"; remotePath = "/platform/staging/db-password"; }
  #     ];
  #   };
  #
  # Example (Helm template):
  #   template = substrateLib.mkExternalSecretHelmTemplate {
  #     name = "db-credentials";
  #     secretStoreName = "cluster-secret-store";
  #     secrets = [
  #       { secretKey = "password"; remotePath = "/platform/{{ $.Values.environment }}/db-password"; }
  #     ];
  #     condition = ".Values.externalSecrets.enabled";
  #   };
  #
  # Example (ClusterSecretStore):
  #   store = substrateLib.mkClusterSecretStore {
  #     name = "akeyless-store";
  #     provider = "akeyless";
  #     providerConfig = { gatewayUrl = "https://gw.example.com"; };
  #   };
  inherit (externalSecretsModule)
    mkExternalSecret
    mkExternalSecretHelmTemplate
    mkClusterSecretStore
    mkSecretPaths;
  externalSecretsBuilder = ./infra/external-secrets.nix;

  # ============================================================================
  # MULTI-TENANT NAMING CONVENTIONS (from multi-tenant-naming.nix)
  # ============================================================================
  # Tenant-aware resource naming for infrastructure and Kubernetes resources.
  # Default tenants get short names; named tenants get prefixed names.
  #
  # Example (Nix):
  #   name = substrateLib.mkResourceName {
  #     tenant = "customer-a"; environment = "production";
  #     region = "us-east-2"; resource = "eks";
  #   };
  #   # → "customer-a-production-us-east-2-eks"
  #
  # Example (Terraform locals):
  #   hcl = substrateLib.mkTerraformNamingLocals {
  #     defaultTenants = [ "mte" "" ];
  #   };
  #
  # Example (full naming scheme):
  #   scheme = substrateLib.mkNamingScheme {
  #     tenant = "customer-a"; environment = "production"; region = "us-east-2";
  #   };
  #   scheme.eksCluster    # → "customer-a-production-us-east-2-eks"
  #   scheme.resource "rds" # → "customer-a-production-us-east-2-rds"
  inherit (multiTenantNamingModule)
    isDefaultTenant
    mkResourceName
    mkNamingScheme
    mkTenantExpr
    mkTenantPathExpr
    mkTerraformNamingLocals;
  multiTenantNamingBuilder = ./infra/multi-tenant-naming.nix;

  # ============================================================================
  # MULTI-TENANT TERRAFORM PATTERNS (from terraform-multi-tenant.nix)
  # ============================================================================
  # Enhanced Terraform module patterns for multi-tenant infrastructure.
  # Validates multi-cloud module layouts, scaffolds new modules with
  # tenant-aware naming, and provides multi-tenant dev shells.
  #
  # Example (validate all modules):
  #   check = substrateLib.mkMultiTenantModuleCheck {
  #     pname = "my-platform"; version = "1.0"; src = ./.;
  #     modules = [ "kms_key" "rds" "eks_cluster" ];
  #     cloudProviders = [ "AWS" "AZR" ];
  #   };
  #
  # Example (scaffold a new module):
  #   apps.scaffold = substrateLib.mkModuleScaffold {
  #     name = "s3_bucket"; cloudProvider = "AWS";
  #   };
  #
  # Example (dev shell):
  #   devShells.default = substrateLib.mkMultiTenantTerraformDevShell {
  #     awsCli = true; azureCli = true;
  #   };
  inherit (terraformMultiTenantModule)
    mkMultiTenantModuleCheck
    mkModuleScaffold
    mkMultiTenantTerraformDevShell;
  terraformMultiTenantBuilder = ./infra/terraform-multi-tenant.nix;

  # ============================================================================
  # ENVIRONMENT CONFIGURATION (from environment-config.nix)
  # ============================================================================
  # Build K8s ConfigMaps from multi-tenant environment config directories.
  # See environment-config.nix for full documentation.
  inherit ((import ./infra/environment-config.nix)) mkEnvironmentConfig;
  environmentConfigBuilder = ./infra/environment-config.nix;

  # ============================================================================
  # DEVENV MODULE PATHS (from lib/devenv/)
  # ============================================================================
  # Import paths for devenv modules. Use with devenv.lib.mkShell or
  # devenv.shells.default.imports in flake-parts consumers.
  #
  # Example:
  #   devenv.lib.mkShell {
  #     modules = [ (import substrateLib.devenvModulePaths.rust-service) ];
  #   };
  #
  # Available modules:
  #   rust, rust-service, rust-tool, rust-library — Rust development
  #   web — Web/frontend development (Vite, React)
  #   nix — Nix development
  #   android — Android development
  #   gitops — ArgoCD, Helm, kubectl, kustomize, YAML validation
  #   infrastructure — Terraform, cloud CLIs, Python automation
  inherit devenvModulePaths;

  # ============================================================================
  # INFRASTRUCTURE TESTS (from infra/tests.nix)
  # ============================================================================
  # 105 pure Nix evaluation tests covering all infra builders.
  # Run: nix eval --impure --raw --file lib/infra/tests.nix --apply 'r: r.summary'
  infraTests = ./infra/tests.nix;

  # ============================================================================
  # HOME-MANAGER TESTS (from hm/tests.nix)
  # ============================================================================
  # 65 pure Nix evaluation tests covering all hm/ helpers:
  # service-helpers, typed-config-helpers, mcp-helpers, nixos-service-helpers,
  # secret-helpers, workspace-helpers, claude-md-helpers, flake-fragment-helpers.
  # Run: nix eval --impure --raw --file lib/hm/tests.nix --apply 'r: r.summary'
  hmTests = ./hm/tests.nix;

  # ============================================================================
  # UTILITY TESTS (from util/tests.nix)
  # ============================================================================
  # 22 pure Nix evaluation tests covering util/ helpers:
  # test-helpers self-tests, versioned-overlay, docker-helpers.
  # Run: nix eval --impure --raw --file lib/util/tests.nix --apply 'r: r.summary'
  utilTests = ./util/tests.nix;

  # ============================================================================
  # TYPE SYSTEM (from types/)
  # ============================================================================
  # Complete type lattice for builder inputs, outputs, and domain specs.
  # Standalone import (no pkgs needed):
  #   types = import "${substrate}/lib/types" { lib = nixpkgs.lib; };
  #
  # Sub-modules:
  #   types.foundation  — NixSystem, Architecture, Language, ArtifactKind, etc.
  #   types.ports       — Unified port representation with coercion bridges
  #   types.buildResult — Universal output contract (packages, devShells, apps)
  #   types.buildSpec   — Per-language typed input specs
  #   types.serviceSpec — Health checks, scaling, resources, monitoring
  #   types.deploySpec  — Docker images, registries, release automation
  #   types.infraSpec   — Workload archetypes, policies, compositions
  #   types.kubeSpec    — K8s metadata, security, probes, RBAC
  #   types.validate    — Builder wrapping and validation middleware
  #
  # Tests: nix eval --impure --expr '(import ./lib/types/tests.nix { lib = (import <nixpkgs> {}).lib; }).summary'
  # ============================================================================
  # TYPED BUILDER WRAPPERS (from build/*/...-typed.nix)
  # ============================================================================
  # Module-system validated versions of complex builders. These validate
  # all inputs through lib.evalModules before delegating to the original
  # builders. Drop-in replacements with type checking at the boundary.
  #
  # Standalone import paths:
  #   rustServiceTyped = import "${substrate}/lib/build/rust/service-typed.nix" { ... };
  #   rustToolReleaseTyped = import "${substrate}/lib/build/rust/tool-release-typed.nix" { ... };
  #   rustWorkspaceReleaseTyped = import "${substrate}/lib/build/rust/workspace-release-typed.nix" { ... };
  #   goGrpcServiceTyped = (import "${substrate}/lib/build/go/grpc-service-typed.nix").mkGoGrpcService;
  rustServiceTypedBuilder = ./build/rust/service-typed.nix;
  rustToolReleaseTypedBuilder = ./build/rust/tool-release-typed.nix;
  rustWorkspaceReleaseTypedBuilder = ./build/rust/workspace-release-typed.nix;
  goGrpcServiceTypedBuilder = ./build/go/grpc-service-typed.nix;

  # Module definitions (for custom evalModules compositions)
  rustServiceModule = ./build/rust/service-module.nix;
  rustToolReleaseModule = ./build/rust/tool-release-module.nix;
  rustWorkspaceReleaseModule = ./build/rust/workspace-release-module.nix;
  goGrpcServiceModule = ./build/go/grpc-service-module.nix;

  substrateTypes = import ./types { lib = pkgs.lib; };
  substrateTypesPath = ./types;
  typeTests = ./types/tests.nix;
  assertionTests = ./types/assertion-tests.nix;
  convergenceTests = ./types/property-tests.nix;
  convergenceTypestate = ./types/convergence.nix;

  # ============================================================================
  # SHARED CROSS-CUTTING MIDDLEWARE (from build/shared/)
  # ============================================================================
  # Language-agnostic typed builders for Docker images, release apps, and devShells.
  # These replace the per-language duplications with a single implementation.
  #
  # Docker: mkTypedDockerImage, mkWebDockerImage, mkServiceDockerImage
  # Release: mkReleaseApps, mkReleaseApp, mkBumpApp, mkCheckAllApp, mkLockPlatformApp, mkImagePushApp
  # DevShell: mkTypedDevShell, mkRustServiceDevShell, mkGoGrpcDevShell, language tool presets
  inherit (sharedDockerModule) mkTypedDockerImage mkWebDockerImage mkServiceDockerImage;
  inherit (sharedReleaseModule) mkReleaseApps;
  sharedReleaseApps = sharedReleaseModule;

  # ──────────────────────────────────────────────────────────────────
  # OCI HARDENED BASES (from build/oci/hardened-base.nix)
  # ──────────────────────────────────────────────────────────────────
  # Path 2: `hardenedBases.{distroless-static,distroless-glibc,wolfi}`
  # are ready-to-use base images; `mkVendorRewrap` pulls an upstream
  # image, extracts a binary, and repackages on a hardened base for
  # publication to ghcr.io/pleme-io/*.
  hardenedBases = ociHardenedModule.bases;
  inherit (ociHardenedModule)
    mkDistrolessStaticBase
    mkDistrolessGlibcBase
    mkWolfiBase
    mkVendorRewrap
    nonrootUid
    nonrootGid;
  inherit (sharedDevShellModule) mkTypedDevShell mkRustServiceDevShell mkGoGrpcDevShell;
  sharedDevShell = sharedDevShellModule;
}
