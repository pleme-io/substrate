# Substrate - Reusable Nix Build Patterns
# Provides parameterized functions for building, testing, and deploying services
#
# Modules:
#   - config.nix: Tokens, secrets, runtime tools
#   - health-supervisor.nix: Health supervisor builder
#   - typescript-tool.nix: TypeScript tool builders
#   - web-build.nix: Vite build helpers, dream2nix, dev shell
#   - web-docker.nix: Web Docker image builder & deployment apps
#   - crate2nix-builders.nix: crate2nix project/tool/docker builders
#   - crate2nix-apps.nix: crate2nix service apps (build/push/deploy/release)
#   - service-helpers.nix: Docker compose, test runners, dev shell, checks
#   - environment-apps.nix: Environment-aware deployment apps (staging + production)
#   - image-release.nix: Generic multi-arch OCI image release (skopeo-based)
#   - ruby-build.nix: Ruby gem/service builders (Docker image, regen, push, release)
#   - helm-build.nix: Helm chart lint, package, push, release apps
{
  pkgs,
  forge ? null,
  system ? null,
  crate2nix ? null,
  fenix ? null,
}: let
  # Import Rust overlay module (always available, doesn't need fenix at import time)
  rustOverlayModule = import ./rust-overlay.nix;

  # Import Go overlay module (builds Go from upstream source)
  goOverlayModule = import ./go-overlay.nix;

  # Import Zig overlay module (prebuilt compiler + from-source zls)
  zigOverlayModule = import ./zig-overlay.nix;

  # Import Swift overlay module (prebuilt Swift 6 from swift.org, Darwin-only)
  swiftOverlayModule = import ./swift-overlay.nix;

  # Helper to get forge command
  forgeCmd = if forge != null
    then "${forge}/bin/forge"
    else "forge";

  # Import modular components
  configModule = import ./config.nix { inherit pkgs; };
  healthSupervisorModule = import ./health-supervisor.nix { inherit pkgs; };
  typescriptToolModule = import ./typescript-tool.nix { inherit pkgs forgeCmd; };

  # Web build helpers
  webBuildModule = import ./web-build.nix { inherit pkgs; };

  # WASM build helpers (Yew/Rust WASM applications)
  wasmBuildModule = if fenix != null && crate2nix != null
    then import ./wasm-build.nix { inherit pkgs fenix crate2nix; }
    else {};

  # Web docker and deployment (needs config for tokens)
  webDockerModule = import ./web-docker.nix {
    inherit pkgs forgeCmd;
    inherit (configModule) defaultAtticToken defaultGhcrToken;
  };

  # Crate2nix builders
  crate2nixBuildersModule = import ./crate2nix-builders.nix {
    inherit pkgs crate2nix;
  };

  # Crate2nix service apps
  crate2nixAppsModule = import ./crate2nix-apps.nix {
    inherit pkgs forgeCmd;
    inherit (configModule) defaultAtticToken defaultGhcrToken mkRuntimeToolsEnv deploymentTools kubernetesTools;
  };

  # Service helpers (docker compose, test runners, etc.)
  serviceHelpersModule = import ./service-helpers.nix {
    inherit pkgs forgeCmd;
    inherit (configModule) defaultAtticToken defaultGhcrToken;
  };

  # Environment-aware deployment apps
  environmentAppsModule = import ./environment-apps.nix {
    inherit pkgs forgeCmd;
    inherit (configModule) defaultAtticToken defaultGhcrToken;
    inherit (webDockerModule) mkWebDeploymentApps;
    inherit (serviceHelpersModule) mkServiceApps;
  };

  # Generic multi-arch image release (uses forge CLI for push orchestration)
  imageReleaseModule = import ./image-release.nix { inherit pkgs forgeCmd; };

  # Ruby gem/service builders (Docker image, regen, push, release)
  rubyBuildModule = import ./ruby-build.nix {
    inherit pkgs forgeCmd;
    inherit (configModule) defaultGhcrToken;
  };

  # Helm chart build helpers (lint, package, push, release, bump — bump delegates to forge)
  helmBuildModule = import ./helm-build.nix { inherit pkgs forgeCmd; };

  # Standalone Rust dev environment builder
  rustDevenvModule = import ./rust-devenv.nix { inherit pkgs; };

  # Devenv module paths for consumer repos
  devenvModulePaths = {
    rust = ./devenv/rust.nix;
    rust-service = ./devenv/rust-service.nix;
    rust-tool = ./devenv/rust-tool.nix;
    rust-library = ./devenv/rust-library.nix;
    web = ./devenv/web.nix;
    nix = ./devenv/nix.nix;
  };

  # mkProductSdlcApps: configurable SDLC app factory.
  # Accepts { backendDir, infraServices } — all optional with sensible defaults.
  mkProductSdlcApps = import ./product-sdlc.nix {
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
  inherit ((import ./darwin.nix)) mkDarwinBuildInputs;
  darwinHelpers = ./darwin.nix;

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
  swiftOverlay = ./swift-overlay.nix;

  # ============================================================================
  # ZIG OVERLAY MODULE (standalone import path)
  # ============================================================================
  # For consumers that need the Zig overlay as a standalone flake overlay.
  # Usage: overlays = [ (import "${substrate}/lib/zig-overlay.nix").mkZigOverlay {} ];
  zigOverlay = ./zig-overlay.nix;

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
  zigToolReleaseBuilder = ./zig-tool-release.nix;
  zigToolReleaseFlakeBuilder = ./zig-tool-release-flake.nix;

  # ============================================================================
  # GO OVERLAY MODULE (standalone import path)
  # ============================================================================
  # For consumers that need the Go overlay as a standalone flake overlay.
  # Usage: overlays = [ (import "${substrate}/lib/go-overlay.nix").mkGoOverlay {} ];
  goOverlay = ./go-overlay.nix;

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
  goToolBuilder = ./go-tool.nix;

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
  goMonorepoBuilder = ./go-monorepo.nix;

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
  goMonorepoBinaryBuilder = ./go-monorepo-binary.nix;

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
  versionedOverlay = ./versioned-overlay.nix;

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
  rustServiceFlakeBuilder = ./rust-service-flake.nix;

  # ============================================================================
  # RUST LIBRARY BUILDER (from rust-library.nix)
  # ============================================================================
  # Standalone module for crates.io Rust library SDLC (build, check, publish).
  # Usage: import "${substrate}/lib/rust-library.nix" { inherit system nixpkgs; nixLib = substrate; crate2nix = inputs.crate2nix; };
  rustLibraryBuilder = ./rust-library.nix;

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
  rustToolReleaseBuilder = ./rust-tool-release.nix;
  rustToolReleaseFlakeBuilder = ./rust-tool-release-flake.nix;

  # ============================================================================
  # TYPESCRIPT LIBRARY BUILDER (from typescript-library.nix)
  # ============================================================================
  # Standalone module for TypeScript library SDLC (build, check-all, devShell).
  # Usage: import "${substrate}/lib/typescript-library.nix" { inherit system nixpkgs dream2nix; };
  typescriptLibraryBuilder = ./typescript-library.nix;

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
  typescriptLibraryFlakeBuilder = ./typescript-library-flake.nix;

  # ============================================================================
  # HOME-MANAGER SERVICE HELPERS (standalone import — no pkgs/system needed)
  # ============================================================================
  # Reusable patterns for daemon + MCP tool services (zoekt-mcp, codesearch, etc.).
  # Unlike other substrate exports, this is a standalone file path — consumers
  # import it directly with `{ lib }` since it only needs nixpkgs lib functions.
  #
  # Usage:
  #   hmHelpers = import "${substrate}/lib/hm-service-helpers.nix" { lib = nixpkgs.lib; };
  hmServiceHelpers = ./hm-service-helpers.nix;

  # ============================================================================
  # NIXOS SERVICE HELPERS (standalone import — no pkgs/system needed)
  # ============================================================================
  # Reusable patterns for NixOS modules: systemd services, firewall rules,
  # kernel configuration, kubeconfig setup, and VM tests.
  #
  # Usage:
  #   nixosHelpers = import "${substrate}/lib/nixos-service-helpers.nix" { lib = nixpkgs.lib; };
  nixosServiceHelpers = ./nixos-service-helpers.nix;

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
  testHelpers = ./test-helpers.nix;

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
  rubyGemBuilder = ./ruby-gem.nix;

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
  rubyGemFlakeBuilder = ./ruby-gem-flake.nix;

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
  pangeaInfraBuilder = ./pangea-infra.nix;

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
  pangeaInfraFlakeBuilder = ./pangea-infra-flake.nix;

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
  goLibraryCheckBuilder = ./go-library-check.nix;

  # Instantiated version (requires pkgs from substrate)
  inherit ((import ./go-library-check.nix)) mkGoLibraryCheck mkGoLibraryCheckOverlay;

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
  pythonPackageBuilder = ./python-package.nix;

  inherit ((import ./python-package.nix)) mkPythonPackage mkPythonPackageOverlay;

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
  sourceRegistryBuilder = ./source-registry.nix;

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
  hmSkillHelpers = ./hm-skill-helpers.nix;

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
  inherit devenvModulePaths;
}
