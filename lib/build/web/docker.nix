# Web Docker Image Builder & Deployment Apps
# Generates Docker images for Node.js/web applications (Vite, Next.js, etc.)
# Uses Hanabi - shared Rust BFF web server (Axum) instead of nginx
{ pkgs, defaultAtticToken, defaultGhcrToken, forgeCmd }:

{
  # Generate Docker images for Node.js/web applications
  # Parameters:
  #   appName: Application name (e.g., "myapp-web")
  #   builtApp: Built application directory (from buildNpmPackage)
  #   webServer: Pure Rust web server binary (Axum static server + health checks)
  #   architecture: "amd64" or "arm64"
  #   tag: Docker image tag (default: "latest")
  #   envConfigPath: Optional path to env.js file for runtime config
  mkNodeDockerImage = {
    appName,
    builtApp,
    webServer,
    architecture ? "amd64",
    tag ? "latest",
    envConfigPath ? null,
  }:
    pkgs.dockerTools.buildLayeredImage {
      name = appName;
      inherit tag architecture;

      contents = with pkgs; [
        webServer
        cacert
        curl
        busybox
      ];

      fakeRootCommands = (import ../../util/docker-helpers.nix).mkWebUserSetup;

      extraCommands = let dockerHelpers = import ../../util/docker-helpers.nix; in ''
        mkdir -p app/static
        cp -r ${builtApp}/* app/static/
        ${
          if envConfigPath != null
          then ''cp ${envConfigPath} app/static/env.js''
          else ""
        }
        chmod -R 755 app/static
        ${dockerHelpers.mkTmpDirs}
      '';

      config = {
        Cmd = ["${webServer}/bin/hanabi"];
        ExposedPorts = {
          "80/tcp" = {};
          "8080/tcp" = {};
        };
        Env = [
          (import ../../util/docker-helpers.nix).mkSslEnv pkgs
          "NODE_ENV=production"
        ];
        WorkingDir = "/app/static";
        User = "web";
      };
    };

  # Generate standardized deployment apps for web applications
  mkWebDeploymentApps = {
    appName,
    registry,
    forge,
    namespace,  # Required: K8s namespace (e.g., "myapp-staging")
    cluster,    # Required: target cluster name (e.g., "staging", "production")
    flakeAttr ? "dockerImage-amd64",
    atticToken ? defaultAtticToken,
    ghcrToken ? defaultGhcrToken,
  }: {
    build = {
      type = "app";
      program = toString (pkgs.writeShellScript "${appName}-build" ''
        set -euo pipefail
        ${if atticToken != "" then ''export ATTIC_TOKEN="${atticToken}"'' else ''export ATTIC_TOKEN="''${ATTIC_TOKEN:-$(cat "$HOME/.config/attic/token" 2>/dev/null || true)}"''}
        REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
        exec ${forgeCmd} build \
          --flake-attr ${flakeAttr} \
          --working-dir "$REPO_ROOT" \
          --arch x86_64-linux \
          --cache-url "''${ATTIC_URL:-http://localhost:8080}" \
          --push-cache \
          --output result
      '');
    };

    push = {
      type = "app";
      program = toString (pkgs.writeShellScript "${appName}-push" ''
        set -euo pipefail
        ${if atticToken != "" then ''export ATTIC_TOKEN="${atticToken}"'' else ''export ATTIC_TOKEN="''${ATTIC_TOKEN:-$(cat "$HOME/.config/attic/token" 2>/dev/null || true)}"''}
        ${if ghcrToken != "" then ''export GHCR_TOKEN="${ghcrToken}"'' else ''export GHCR_TOKEN="''${GHCR_TOKEN:-''${GITHUB_TOKEN:-$(cat "$HOME/.config/github/token" 2>/dev/null || true)}}"''}
        GIT_SHA="''${RELEASE_GIT_SHA:-$(${pkgs.git}/bin/git rev-parse --short HEAD)}"
        exec ${forgeCmd} push \
          --image-path result \
          --registry ${registry} \
          --tag "amd64-$GIT_SHA" \
          --tag "amd64-latest" \
          --retries 10 \
          --push-attic \
          --attic-cache "''${ATTIC_CACHE_NAME:-cache}"
      '');
    };

    deploy = {
      type = "app";
      program = toString (pkgs.writeShellScript "${appName}-deploy" ''
        set -euo pipefail
        ${if atticToken != "" then ''export ATTIC_TOKEN="${atticToken}"'' else ''export ATTIC_TOKEN="''${ATTIC_TOKEN:-$(cat "$HOME/.config/attic/token" 2>/dev/null || true)}"''}
        ${if ghcrToken != "" then ''export GHCR_TOKEN="${ghcrToken}"'' else ''export GHCR_TOKEN="''${GHCR_TOKEN:-''${GITHUB_TOKEN:-$(cat "$HOME/.config/github/token" 2>/dev/null || true)}}"''}
        REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel)
        CURRENT_DIR="$PWD"
        GIT_SHA="''${RELEASE_GIT_SHA:-$(${pkgs.git}/bin/git rev-parse --short HEAD)}"
        cd "$REPO_ROOT"
        rm -f result
        ln -s "$CURRENT_DIR/result" result
        MANIFEST_PATH="$REPO_ROOT/k8s/clusters/${cluster}/products/${namespace}/web/kustomization.yaml"
        exec ${forgeCmd} deploy \
          --manifest "$MANIFEST_PATH" \
          --registry ${registry} \
          --tag "$GIT_SHA" \
          --namespace ${namespace} \
          --name ${appName} \
          --skip-build \
          --watch \
          --timeout 10m \
          --cache-url "''${ATTIC_URL:-http://localhost:8080}"
      '');
    };

    release = {
      type = "app";
      program = toString (pkgs.writeShellScript "${appName}-release" ''
        set -euo pipefail
        echo "🚀 ${appName} Release Workflow"
        echo "$(printf '=%.0s' {1..50})"
        export RELEASE_GIT_SHA=$(${pkgs.git}/bin/git rev-parse --short HEAD)
        echo "📦 Release Git SHA: $RELEASE_GIT_SHA"
        echo ""
        echo "Step 1/3: Building..."
        nix run .#build
        echo ""
        echo "Step 2/3: Pushing..."
        nix run .#push
        echo ""
        echo "Step 3/3: Deploying..."
        nix run .#deploy
        echo ""
        echo "✅ Release complete!"
      '');
    };

    default = {
      type = "app";
      program = toString (pkgs.writeShellScript "${appName}-help" ''
        echo "🌐 ${appName} Web Application"
        echo "$(printf '=%.0s' {1..50})"
        echo ""
        echo "Development:"
        echo "  nix run .#dev               - Start development server"
        echo "  npm run dev                 - Alternative: npm dev server"
        echo ""
        echo "Deployment (via forge):"
        echo "  nix run .#build             - Build Docker image"
        echo "  nix run .#push              - Push to GHCR"
        echo "  nix run .#deploy            - Deploy to Kubernetes"
        echo "  nix run .#release           - Full workflow (build+push+deploy)"
      '');
    };
  };
}
