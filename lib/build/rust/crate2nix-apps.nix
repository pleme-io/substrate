# Crate2nix Service Apps - Build, Push, Deploy, Release Apps
# Deployment workflows for crate2nix-based Rust services
{ pkgs, forgeCmd, defaultAtticToken, defaultGhcrToken, mkRuntimeToolsEnv, deploymentTools, kubernetesTools }:

rec {
  # Helper to create a push app for any Docker image
  # Reusable across production and test images
  mkImagePushApp = {
    serviceName,
    imagePath,
    registry,
    ghcrToken ? defaultGhcrToken,
    imageSuffix ? "",  # Empty for prod, "-test" for test images
    imageLabel ? "Docker",  # "Docker" or "TEST Docker"
    forge,
  }: {
    type = "app";
    program = toString (pkgs.writeShellScript "${serviceName}-push${imageSuffix}-image" ''
      set -euo pipefail

      echo "📦 Pushing ${serviceName}${imageSuffix} ${imageLabel} image to GHCR"
      echo "$(printf '=%.0s' {1..50})"
      echo ""
      echo "📦 ${imageLabel} image (Nix-built): ${imagePath}"
      echo "🏷️  Registry: ${registry}"
      echo ""

      ${if ghcrToken != "" then ''export GITHUB_TOKEN="${ghcrToken}"
      export GHCR_TOKEN="${ghcrToken}"'' else ''export GITHUB_TOKEN="''${GITHUB_TOKEN:-''${GHCR_TOKEN:-$(cat "$HOME/.config/github/token" 2>/dev/null || true)}}"
      export GHCR_TOKEN="$GITHUB_TOKEN"''}
      ${mkRuntimeToolsEnv { tools = ["skopeo"]; }}

      exec ${forge}/bin/forge push \
        --image-path "${imagePath}" \
        --registry "${registry}" \
        --auto-tags \
        --retries 3
    '');
  };
  # Generate standard apps for crate2nix-based services
  #
  # Parameters:
  #   serviceName: "email", "auth", "cart", etc.
  #   dockerImage-amd64: Built Docker image for amd64 (optional, defaults to null)
  #   dockerImage-arm64: Built Docker image for arm64 (optional, defaults to null)
  #   dockerImage-test: Built test Docker image (optional, for Kenshi TestGates)
  #   architectures: List of enabled architectures (e.g., ["amd64"] or ["amd64" "arm64"])
  #   productName: product identifier (required — no default to avoid wrong assumptions)
  #   namespace: K8s namespace (required — derive from product config or pass explicitly)
  #   cluster: Target cluster name (e.g., "staging", "production")
  #   forge: forge deployment tool package
  #   atticToken: Attic cache token (default from serviceLib)
  #   ghcrToken: GitHub Container Registry token (default from serviceLib)
  #
  # Cache URL/name: read from env vars at runtime (ATTIC_URL, ATTIC_CACHE_NAME).
  # Forge already reads ATTIC_CACHE_NAME — no --cache-name flag needed.
  mkCrate2nixServiceApps = {
    serviceName,
    src,  # Source directory for cd'ing into before running commands
    repoRoot,  # Repository root path (for root flake pattern)
    dockerImage-amd64 ? null,
    dockerImage-arm64 ? null,
    dockerImage-test ? null,  # Test image for Kenshi TestGates
    architectures ? ["amd64" "arm64"],
    productName ? null,  # Product identifier (e.g., "myapp") — null for standalone repos
    productConfig ? {},  # Product configuration from deploy.yaml (parsed in rust-services.nix)
    # Relative path from repo root to service directory.
    # Used at runtime with `git rev-parse --show-toplevel` for actual working dir paths.
    # Pass explicitly — no monorepo structure assumption.
    serviceDirRelative ? "services/rust/${serviceName}",
    namespace,  # Required: K8s namespace (e.g., "${productName}-staging")
    cluster ? "staging",  # Target cluster name
    registryBase ? null,  # Registry base URL (e.g., "ghcr.io/myorg") — null when registry is set
    registry ? null,  # Explicit registry override (e.g., "ghcr.io/pleme-io/shinka")
    atticToken ? defaultAtticToken,
    ghcrToken ? defaultGhcrToken,
    forge,
    crate2nix,
    nixHooks ? null,  # Optional: Nix hooks package for attic-push-hook
  }: let
    # Compute effective registry: explicit override > product-based derivation
    effectiveRegistry = if registry != null then registry
      else if productName != null && registryBase != null
        then "${registryBase}/${productName}-${serviceName}"
      else throw "mkCrate2nixServiceApps: either 'registry' or both 'productName'+'registryBase' required";

    # Test image registry (same pattern but with -test suffix)
    testRegistry = "${effectiveRegistry}-test";

    # Determine BUILD_ARM64 environment variable based on architectures list
    buildArm64EnvValue = if builtins.elem "arm64" architectures then "auto" else "no";

    # Use the forge parameter for this function's apps
    localForgeCmd = "${forge}/bin/forge";

    # Convert paths to strings for parameters (root flake pattern)
    repoRootPath = toString repoRoot;
    serviceDirPath = toString src;
  in {
    # Build Docker images using crate2nix
    build = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-build" ''
        set -euo pipefail

        ${if atticToken != "" then ''export ATTIC_TOKEN="${atticToken}"'' else ''export ATTIC_TOKEN="''${ATTIC_TOKEN:-$(cat "$HOME/.config/attic/token" 2>/dev/null || true)}"''}
        export BUILD_ARM64="${buildArm64EnvValue}"
        ${if nixHooks != null then "export NIX_HOOKS_PATH=\"${nixHooks}\"" else ""}
        ${mkRuntimeToolsEnv { tools = ["attic" "git"]; }}

        exec ${localForgeCmd} build-rust-service \
          --service ${serviceName} \
          --service-dir "${serviceDirPath}" \
          --repo-root "${repoRootPath}" \
          --cache-url "''${ATTIC_URL:-http://localhost:8080}"
      '');
    };

    # Push Docker images to GHCR and Attic
    push = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-push" ''
        ${if atticToken != "" then ''export ATTIC_TOKEN="${atticToken}"'' else ''export ATTIC_TOKEN="''${ATTIC_TOKEN:-$(cat "$HOME/.config/attic/token" 2>/dev/null || true)}"''}
        ${if ghcrToken != "" then ''export GITHUB_TOKEN="${ghcrToken}"'' else ''export GITHUB_TOKEN="''${GITHUB_TOKEN:-''${GHCR_TOKEN:-$(cat "$HOME/.config/github/token" 2>/dev/null || true)}}"''}

        ${mkRuntimeToolsEnv { tools = ["skopeo" "attic"]; }}

        exec ${localForgeCmd} push-rust-service \
          --service ${serviceName} \
          --service-dir "${serviceDirPath}" \
          --repo-root "${repoRootPath}" \
          --registry ${effectiveRegistry}
      '');
    };

    # Push pre-built Docker image to GHCR (simplified - just build+push, no deploy)
    # Uses mkImagePushApp helper for consistency
    push-image = let
      imageAmd64 = if dockerImage-amd64 != null then dockerImage-amd64 else throw "AMD64 image not available for ${serviceName}";
    in mkImagePushApp {
      inherit serviceName ghcrToken;
      imagePath = imageAmd64;
      registry = effectiveRegistry;
      forge = forge;
    };

    # Deploy to Kubernetes via GitOps
    deploy = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-deploy" ''
        ${mkRuntimeToolsEnv { tools = deploymentTools ++ kubernetesTools; }}

        exec ${localForgeCmd} deploy-rust-service \
          --service ${serviceName} \
          --service-dir "${serviceDirPath}" \
          --repo-root "${repoRootPath}" \
          --registry ${effectiveRegistry} \
          --namespace ${namespace} \
          --watch
      '');
    };

    # Full release workflow
    # Environment selected via --environment flag (default: staging)
    # Namespace is automatically derived from deploy.yaml based on environment
    # Pushes arch-prefixed tags (amd64-{sha}, arm64-{sha}) and creates manifest index ({sha})
    release = let
      hasAmd64 = builtins.elem "amd64" architectures;
      hasArm64 = builtins.elem "arm64" architectures;
      imageAmd64 = if hasAmd64 then (if dockerImage-amd64 != null then dockerImage-amd64 else throw "AMD64 image not available for ${serviceName}") else null;
      imageArm64 = if hasArm64 then (if dockerImage-arm64 != null then dockerImage-arm64 else null) else null;
      hasTestImage = dockerImage-test != null;
      # Check if test image push is enabled in deploy.yaml (default: true for backward compat)
      # Supports both testImage.enabled (product deploy.yaml) and release.test_image.enabled (service deploy.yaml)
      testImageEnabled = productConfig.testImage.enabled or productConfig.release.test_image.enabled or true;
    in {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-release" ''
        set -euo pipefail

        ${if atticToken != "" then ''export ATTIC_TOKEN="${atticToken}"'' else ''export ATTIC_TOKEN="''${ATTIC_TOKEN:-$(cat "$HOME/.config/attic/token" 2>/dev/null || true)}"''}
        ${if ghcrToken != "" then ''export GITHUB_TOKEN="${ghcrToken}"
        export GHCR_TOKEN="${ghcrToken}"'' else ''export GITHUB_TOKEN="''${GITHUB_TOKEN:-''${GHCR_TOKEN:-$(cat "$HOME/.config/github/token" 2>/dev/null || true)}}"
        export GHCR_TOKEN="$GITHUB_TOKEN"''}
        ${mkRuntimeToolsEnv { tools = deploymentTools ++ ["bun"]; }}

        ${if hasTestImage && testImageEnabled then ''
        # Push test image first (same tags as production)
        echo ""
        echo "🧪 Pushing test image for Kenshi TestGates..."
        echo ""
        ${localForgeCmd} push \
          --image-path "${dockerImage-test}" \
          --registry "${testRegistry}" \
          --auto-tags \
          --retries 3
        echo ""
        echo "✅ Test image pushed successfully"
        echo ""
        '' else ''
        echo "ℹ️  Test image ${if hasTestImage then "disabled in deploy.yaml" else "not available"}, skipping test image push"
        ''}

        # Run production release workflow (respects architectures list)
        exec ${localForgeCmd} orchestrate-release \
          --service ${serviceName} \
          --service-dir "$(${pkgs.git}/bin/git rev-parse --show-toplevel)/${serviceDirRelative}" \
          --repo-root "$(${pkgs.git}/bin/git rev-parse --show-toplevel)" \
          --registry ${effectiveRegistry} \
          ${if hasAmd64 then "--image-path ${imageAmd64}" else ""} \
          ${if hasArm64 then "--image-path-arm64 ${imageArm64}" else ""} \
          "$@"
      '');
    };

    # Monitor rollout status
    rollout = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-rollout" ''
        ${mkRuntimeToolsEnv { tools = kubernetesTools; }}
        exec ${localForgeCmd} rollout \
          --namespace ${namespace} \
          --name ${serviceName} \
          --interval 3
      '');
    };

    # Development apps
    test = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-test" ''
        exec ${localForgeCmd} rust-test --service ${serviceName}
      '');
    };

    lint = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-lint" ''
        exec ${localForgeCmd} rust-lint --service ${serviceName}
      '');
    };

    fmt = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-fmt" ''
        exec ${localForgeCmd} rust-fmt --service ${serviceName}
      '');
    };

    fmt-check = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-fmt-check" ''
        exec ${localForgeCmd} rust-fmt-check --service ${serviceName}
      '');
    };

    extract-schema = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-extract-schema" ''
        exec ${localForgeCmd} rust-extract-schema --service ${serviceName}
      '');
    };

    update-cargo-nix = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-update-cargo-nix" ''
        exec ${localForgeCmd} rust-update-cargo-nix --service ${serviceName}
      '');
    };

    regenerate = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-regenerate" ''
        set -euo pipefail

        ACTUAL_REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel)
        ACTUAL_SERVICE_DIR="$ACTUAL_REPO_ROOT/${serviceDirRelative}"

        echo "🔄 Regenerating Cargo.lock and Cargo.nix for ${serviceName}"
        echo "$(printf '=%.0s' {1..50})"
        echo "📂 Service directory: $ACTUAL_SERVICE_DIR"
        echo ""

        ${mkRuntimeToolsEnv { tools = ["crate2nix"]; }}

        exec ${localForgeCmd} rust-regenerate \
          --service ${serviceName} \
          --service-dir "$ACTUAL_SERVICE_DIR" \
          --repo-root "$ACTUAL_REPO_ROOT"
      '');
    };

    cargo-update = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-cargo-update" ''
        set -euo pipefail

        ACTUAL_REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel)
        ACTUAL_SERVICE_DIR="$ACTUAL_REPO_ROOT/${serviceDirRelative}"

        echo "🔄 Updating dependencies for ${serviceName}"
        echo "$(printf '=%.0s' {1..50})"
        echo "📂 Service directory: $ACTUAL_SERVICE_DIR"
        echo ""

        ${mkRuntimeToolsEnv { tools = ["crate2nix"]; }}

        exec ${localForgeCmd} rust-cargo-update \
          --service ${serviceName} \
          --service-dir "$ACTUAL_SERVICE_DIR" \
          --repo-root "$ACTUAL_REPO_ROOT"
      '');
    };

    default = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-help" ''
        exec ${localForgeCmd} rust-service-help --service ${serviceName}
      '');
    };

    integration-test = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-test" ''
        set -euo pipefail

        ACTUAL_REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel)
        ACTUAL_SERVICE_DIR="$ACTUAL_REPO_ROOT/${serviceDirRelative}"

        exec ${localForgeCmd} test \
          --service ${serviceName} \
          --service-dir "$ACTUAL_SERVICE_DIR" \
          --repo-root "$ACTUAL_REPO_ROOT" \
          --service-type rust \
          "$@"
      '');
    };

    status = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-status" ''
        set -euo pipefail

        ACTUAL_REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel)
        ACTUAL_SERVICE_DIR="$ACTUAL_REPO_ROOT/${serviceDirRelative}"

        exec ${localForgeCmd} status \
          --service ${serviceName} \
          --service-dir "$ACTUAL_SERVICE_DIR" \
          --repo-root "$ACTUAL_REPO_ROOT" \
          "$@"
      '');
    };

    # Local development: docker-compose + migrations + cargo run
    # Uses forge rust-dev command for robust handling
    dev = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-dev" ''
        set -euo pipefail

        ACTUAL_REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel)
        ACTUAL_SERVICE_DIR="$ACTUAL_REPO_ROOT/${serviceDirRelative}"

        exec ${localForgeCmd} rust-dev \
          --service ${serviceName} \
          --service-dir "$ACTUAL_SERVICE_DIR" \
          --repo-root "$ACTUAL_REPO_ROOT" \
          --sqlx-cli "${pkgs.sqlx-cli}/bin/sqlx" \
          "$@"
      '');
    };

    # Stop docker-compose services
    # Uses forge rust-dev-down command
    dev-down = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-dev-down" ''
        set -euo pipefail

        ACTUAL_REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel)
        ACTUAL_SERVICE_DIR="$ACTUAL_REPO_ROOT/${serviceDirRelative}"

        exec ${localForgeCmd} rust-dev-down \
          --service ${serviceName} \
          --service-dir "$ACTUAL_SERVICE_DIR" \
          --repo-root "$ACTUAL_REPO_ROOT"
      '');
    };

    # Run database migrations
    migrate = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-migrate" ''
        set -euo pipefail

        ACTUAL_REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel)
        ACTUAL_SERVICE_DIR="$ACTUAL_REPO_ROOT/${serviceDirRelative}"

        cd "$ACTUAL_SERVICE_DIR"

        # Load DATABASE_URL from deploy.yaml
        if [ -f "deploy.yaml" ]; then
          DB_URL=$(${pkgs.yq}/bin/yq -r '.local.env.DATABASE_URL // empty' deploy.yaml 2>/dev/null || echo "")
          if [ -n "$DB_URL" ]; then
            export DATABASE_URL="$DB_URL"
          fi
        fi

        # Fallback if not set
        export DATABASE_URL="''${DATABASE_URL:-postgres://postgres:postgres@localhost:5432/${serviceName}}"

        echo "🔄 Running migrations for ${serviceName}"
        echo "   Database: $DATABASE_URL"
        echo ""

        ${pkgs.sqlx-cli}/bin/sqlx migrate run --source ./migrations "$@"

        echo ""
        echo "✅ Migrations complete"
      '');
    };

    # Show migration status
    migrate-status = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-migrate-status" ''
        set -euo pipefail

        ACTUAL_REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel)
        ACTUAL_SERVICE_DIR="$ACTUAL_REPO_ROOT/${serviceDirRelative}"

        cd "$ACTUAL_SERVICE_DIR"

        # Load DATABASE_URL from deploy.yaml
        if [ -f "deploy.yaml" ]; then
          DB_URL=$(${pkgs.yq}/bin/yq -r '.local.env.DATABASE_URL // empty' deploy.yaml 2>/dev/null || echo "")
          if [ -n "$DB_URL" ]; then
            export DATABASE_URL="$DB_URL"
          fi
        fi

        export DATABASE_URL="''${DATABASE_URL:-postgres://postgres:postgres@localhost:5432/${serviceName}}"

        echo "📋 Migration status for ${serviceName}"
        echo "   Database: $DATABASE_URL"
        echo ""

        ${pkgs.sqlx-cli}/bin/sqlx migrate info --source ./migrations
      '');
    };

    # Create a new migration
    migrate-add = {
      type = "app";
      program = toString (pkgs.writeShellScript "${serviceName}-migrate-add" ''
        set -euo pipefail

        ACTUAL_REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel)
        ACTUAL_SERVICE_DIR="$ACTUAL_REPO_ROOT/${serviceDirRelative}"

        cd "$ACTUAL_SERVICE_DIR"

        if [ -z "''${1:-}" ]; then
          echo "Usage: nix run .#migrate-add${if productName != null then ":${productName}" else ""}:${serviceName} -- <migration_name>"
          echo ""
          echo "Example: nix run .#migrate-add${if productName != null then ":${productName}" else ""}:${serviceName} -- add_users_table"
          exit 1
        fi

        echo "📝 Creating migration: $1"
        ${pkgs.sqlx-cli}/bin/sqlx migrate add -r "$1"
        echo ""
        echo "✅ Created migration files in ./migrations/"
      '');
    };
  } // pkgs.lib.optionalAttrs (dockerImage-test != null) {
    # Push test Docker image to GHCR (for Kenshi TestGates)
    # Only available when dockerImage-test is provided
    push-test-image = mkImagePushApp {
      inherit serviceName ghcrToken;
      imagePath = dockerImage-test;
      registry = testRegistry;
      imageSuffix = "-test";
      imageLabel = "TEST";
      forge = forge;
    };
  };
}
