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

  # Helper to get forge command
  forgeCmd = if forge != null
    then "${forge}/bin/forge"
    else "forge";

  # Import modular components
  configModule = import ./config.nix { inherit pkgs; };
  healthSupervisorModule = import ./health-supervisor.nix { inherit pkgs; };
  typescriptToolModule = import ./typescript-tool.nix { inherit pkgs; };

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

  # Generic multi-arch image release (no forge dependency — pure skopeo)
  imageReleaseModule = import ./image-release.nix { inherit pkgs; };

  # Ruby gem/service builders (Docker image, regen, push, release)
  rubyBuildModule = import ./ruby-build.nix {
    inherit pkgs forgeCmd;
    inherit (configModule) defaultGhcrToken;
  };

  # Helm chart build helpers (lint, package, push, release, bump — bump delegates to forge)
  helmBuildModule = import ./helm-build.nix { inherit pkgs forgeCmd; };

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
  # ZIG OVERLAY MODULE (standalone import path)
  # ============================================================================
  # For consumers that need the Zig overlay as a standalone flake overlay.
  # Usage: overlays = [ (import "${substrate}/lib/zig-overlay.nix").mkZigOverlay {} ];
  zigOverlay = ./zig-overlay.nix;

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
  # RUST LIBRARY BUILDER (from rust-library.nix)
  # ============================================================================
  # Standalone module for crates.io Rust library SDLC (build, check, publish).
  # Usage: import "${substrate}/lib/rust-library.nix" { inherit system nixpkgs; nixLib = substrate; crate2nix = inputs.crate2nix; };
  rustLibraryBuilder = ./rust-library.nix;

  # ============================================================================
  # TYPESCRIPT LIBRARY BUILDER (from typescript-library.nix)
  # ============================================================================
  # Standalone module for TypeScript library SDLC (build, check-all, devShell).
  # Usage: import "${substrate}/lib/typescript-library.nix" { inherit system nixpkgs dream2nix; };
  typescriptLibraryBuilder = ./typescript-library.nix;

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
}
