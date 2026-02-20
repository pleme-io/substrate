# Environment-Aware Deployment Apps (Staging + Production)
# Enhanced deployment apps supporting both staging and production environments
# Adds production-specific safety measures and confirmation prompts
{ pkgs, forgeCmd, defaultAtticToken, defaultGhcrToken, mkWebDeploymentApps, mkServiceApps }:

{
  # Web deployment apps with environment support
  mkEnvironmentWebDeploymentApps = {
    appName,
    productName,
    registry,
    forge,
    clusterName,  # Required: target cluster name
    flakeAttr ? "dockerImage-amd64",
    atticToken ? defaultAtticToken,
    ghcrToken ? defaultGhcrToken,
  }: let
    # Base apps using existing function for staging
    stagingApps = mkWebDeploymentApps {
      inherit appName registry forge flakeAttr atticToken ghcrToken;
      cluster = clusterName;
      namespace = "${productName}-staging";
    };

    # Production-specific build (same as staging)
    productionBuild = stagingApps.build;

    # Production-specific push (same as staging)
    productionPush = stagingApps.push;

    # Production-specific deploy with confirmation
    productionDeploy = {
      type = "app";
      program = toString (pkgs.writeShellScript "${appName}-deploy-production" ''
        set -euo pipefail

        echo "⚠️  PRODUCTION DEPLOYMENT"
        echo "$(printf '=%.0s' {1..50})"
        echo ""
        echo "Product: ${productName}"
        echo "Service: ${appName}"
        echo "Environment: PRODUCTION"
        echo "Cluster: ${clusterName}"
        echo ""
        echo "This will update the production Kubernetes deployment."
        echo ""
        read -p "Type 'yes' to confirm: " confirm

        if [ "$confirm" != "yes" ]; then
          echo "❌ Deployment cancelled"
          exit 1
        fi

        ${if atticToken != "" then ''export ATTIC_TOKEN="${atticToken}"'' else ''export ATTIC_TOKEN="''${ATTIC_TOKEN:-$(cat "$HOME/.config/attic/token" 2>/dev/null || true)}"''}
        ${if ghcrToken != "" then ''export GHCR_TOKEN="${ghcrToken}"'' else ''export GHCR_TOKEN="''${GHCR_TOKEN:-''${GITHUB_TOKEN:-$(cat "$HOME/.config/github/token" 2>/dev/null || true)}}"''}

        REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel)
        CURRENT_DIR="$PWD"
        GIT_SHA="''${RELEASE_GIT_SHA:-$(${pkgs.git}/bin/git rev-parse --short HEAD)}"

        cd "$REPO_ROOT"
        rm -f result
        ln -s "$CURRENT_DIR/result" result

        echo ""
        echo "🚀 Deploying to production..."
        exec ${forgeCmd} deploy \
          --registry ${registry} \
          --tag "$GIT_SHA" \
          --namespace ${productName}-production \
          --name ${appName} \
          --skip-build \
          --watch \
          --timeout 10m \
          --cache-url "''${ATTIC_URL:-http://localhost:8080}"
      '');
    };

    # Production release workflow with double confirmation
    productionRelease = {
      type = "app";
      program = toString (pkgs.writeShellScript "${appName}-release-production" ''
        set -euo pipefail

        echo "⚠️  ⚠️  ⚠️  PRODUCTION RELEASE ⚠️  ⚠️  ⚠️"
        echo "$(printf '=%.0s' {1..50})"
        echo ""
        echo "Product: ${productName}"
        echo "Service: ${appName}"
        echo "Environment: PRODUCTION"
        echo "Cluster: ${clusterName}"
        echo ""
        echo "This will:"
        echo "  1. Build Docker image"
        echo "  2. Push to GHCR registry"
        echo "  3. Deploy to PRODUCTION Kubernetes cluster"
        echo ""
        echo "⚠️  This affects live users!"
        echo ""
        read -p "Type 'PRODUCTION' to confirm: " confirm

        if [ "$confirm" != "PRODUCTION" ]; then
          echo "❌ Release cancelled"
          exit 1
        fi

        echo ""
        echo "🚀 ${appName} PRODUCTION Release Workflow"
        echo "$(printf '=%.0s' {1..50})"
        echo ""

        export RELEASE_GIT_SHA=$(${pkgs.git}/bin/git rev-parse --short HEAD)
        echo "📦 Release Git SHA: $RELEASE_GIT_SHA"
        echo ""

        echo "Step 1/3: Building..."
        nix run .#prod-build

        echo ""
        echo "Step 2/3: Pushing..."
        nix run .#prod-push

        echo ""
        echo "Step 3/3: Deploying to PRODUCTION..."
        nix run .#prod-deploy

        echo ""
        echo "✅ PRODUCTION release complete!"
        echo ""
        echo "Monitor deployment:"
        echo "  kubectl get pods -n ${productName}-production"
        echo "  kubectl logs -n ${productName}-production deployment/${appName} -f"
      '');
    };
  in {
    # Staging apps (default)
    inherit (stagingApps) build push deploy release default;

    # Production apps (explicit prefix for safety)
    prod-build = productionBuild;
    prod-push = productionPush;
    prod-deploy = productionDeploy;
    productionrelease = productionRelease;
  };

  # Service deployment apps with environment support
  mkEnvironmentServiceApps = {
    appName,
    productName,
    registry,
    forge,
    clusterName,  # Required: target cluster name
    composeFile ? null,
    runMigrations ? false,
    migrationsPath ? "./migrations",
    atticToken ? defaultAtticToken,
    ghcrToken ? defaultGhcrToken,
    dbPort ? 5432,
    dbUser ? "postgres",
    dbPassword ? "postgres",
    dbName ? "test",
  }: let
    # Base apps using existing function for staging
    stagingApps = mkServiceApps {
      serviceName = appName;
      inherit registry forge atticToken ghcrToken;
      namespace = "${productName}-staging";
      servicePackage = throw "servicePackage must be provided";
    };

    # Production-specific apps with confirmations
    productionDeploy = {
      type = "app";
      program = toString (pkgs.writeShellScript "${appName}-deploy-production" ''
        set -euo pipefail

        echo "⚠️  PRODUCTION DEPLOYMENT"
        echo "$(printf '=%.0s' {1..50})"
        echo ""
        echo "Product: ${productName}"
        echo "Service: ${appName}"
        echo "Environment: PRODUCTION"
        echo "Cluster: ${clusterName}"
        echo ""
        read -p "Type 'yes' to confirm: " confirm

        if [ "$confirm" != "yes" ]; then
          echo "❌ Deployment cancelled"
          exit 1
        fi

        ${if atticToken != "" then ''export ATTIC_TOKEN="${atticToken}"'' else ''export ATTIC_TOKEN="''${ATTIC_TOKEN:-$(cat "$HOME/.config/attic/token" 2>/dev/null || true)}"''}
        ${if ghcrToken != "" then ''export GHCR_TOKEN="${ghcrToken}"'' else ''export GHCR_TOKEN="''${GHCR_TOKEN:-''${GITHUB_TOKEN:-$(cat "$HOME/.config/github/token" 2>/dev/null || true)}}"''}

        REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel)
        CURRENT_DIR="$PWD"
        GIT_SHA="''${RELEASE_GIT_SHA:-$(${pkgs.git}/bin/git rev-parse --short HEAD)}"

        cd "$REPO_ROOT"
        rm -f result
        ln -s "$CURRENT_DIR/result" result

        echo ""
        echo "🚀 Deploying to production..."
        exec ${forgeCmd} deploy \
          --registry ${registry} \
          --tag "$GIT_SHA" \
          --namespace ${productName}-production \
          --name ${appName} \
          --skip-build \
          --watch \
          --timeout 10m \
          --cache-url "''${ATTIC_URL:-http://localhost:8080}"
      '');
    };

    productionRelease = {
      type = "app";
      program = toString (pkgs.writeShellScript "${appName}-release-production" ''
        set -euo pipefail

        echo "⚠️  ⚠️  ⚠️  PRODUCTION RELEASE ⚠️  ⚠️  ⚠️"
        echo "$(printf '=%.0s' {1..50})"
        echo ""
        echo "Product: ${productName}"
        echo "Service: ${appName}"
        echo "Environment: PRODUCTION"
        echo ""
        read -p "Type 'PRODUCTION' to confirm: " confirm

        if [ "$confirm" != "PRODUCTION" ]; then
          echo "❌ Release cancelled"
          exit 1
        fi

        export RELEASE_GIT_SHA=$(${pkgs.git}/bin/git rev-parse --short HEAD)
        echo ""
        echo "📦 Release Git SHA: $RELEASE_GIT_SHA"
        echo ""

        echo "Step 1/3: Building..."
        nix run .#build

        echo ""
        echo "Step 2/3: Pushing..."
        nix run .#push

        echo ""
        echo "Step 3/3: Deploying..."
        nix run .#prod-deploy

        echo ""
        echo "✅ PRODUCTION release complete!"
      '');
    };
  in {
    # Staging apps (default)
    inherit (stagingApps) build push deploy release default;

    # Production apps
    prod-deploy = productionDeploy;
    productionrelease = productionRelease;
  };
}
