# Service Helpers - Docker Compose, Test Runners, Dev Shell, Checks, Packages
# Utility functions for Rust service development and testing
{ pkgs, forgeCmd, defaultAtticToken, defaultGhcrToken }:

rec {
  # Generate docker-compose.yml for integration testing
  mkDockerComposeConfig = {
    serviceName,
    dbPort ? 5434,
    redisPort ? 6381,
    dbName ? "${serviceName}_test",
    dbUser ? "${serviceName}_test",
    dbPassword ? "test_password",
  }: let
    check = import ../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "serviceName" serviceName)
      (check.port "dbPort" dbPort)
      (check.port "redisPort" redisPort)
    ];
  in
    pkgs.writeText "docker-compose.yml" ''
      version: "3.8"

      services:
        postgres-test:
          image: postgres:16-alpine
          container_name: ${serviceName}-postgres-test
          environment:
            POSTGRES_DB: ${dbName}
            POSTGRES_USER: ${dbUser}
            POSTGRES_PASSWORD: ${dbPassword}
            POSTGRES_INITDB_ARGS: "-E UTF8"
          ports:
            - "${toString dbPort}:5432"
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -U ${dbUser} -d ${dbName}"]
            interval: 5s
            timeout: 5s
            retries: 5
          tmpfs:
            - /var/lib/postgresql/data
          networks:
            - ${serviceName}-test-network

        redis-test:
          image: redis:7-alpine
          container_name: ${serviceName}-redis-test
          command: redis-server --bind 0.0.0.0 --appendonly yes --protected-mode no
          ports:
            - "${toString redisPort}:6379"
          healthcheck:
            test: ["CMD", "redis-cli", "ping"]
            interval: 5s
            timeout: 3s
            retries: 5
          tmpfs:
            - /data
          networks:
            - ${serviceName}-test-network

      networks:
        ${serviceName}-test-network:
          driver: bridge
    '';

  # Generate test runner scripts for unit and integration tests
  mkTestRunners = {
    serviceName,
    rustToolchain,
    dockerComposeConfig,
    dbUrl,
    redisUrl,
    migrationsPath ? "./migrations",
  }: {
    # Unit test runner (fast, no external dependencies)
    unit = pkgs.writeShellScriptBin "run-unit-tests" ''
      set -euo pipefail

      echo "🧪 Running unit tests for ${serviceName}..."
      export RUST_LOG=debug
      export RUST_BACKTRACE=1
      export SQLX_OFFLINE=true

      ${rustToolchain}/bin/cargo test --lib --bins --features test-helpers

      if [ $? -eq 0 ]; then
        echo "✅ All unit tests passed!"
      else
        echo "❌ Unit tests failed!"
        exit 1
      fi
    '';

    # Integration test runner (with docker-compose orchestration)
    integration = pkgs.writeShellScriptBin "run-integration-tests" ''
      set -euo pipefail

      echo "🚀 Starting integration test environment for ${serviceName}..."

      export DATABASE_URL="${dbUrl}"
      export REDIS_URL="${redisUrl}"
      export RUST_LOG=debug
      export RUST_BACKTRACE=1

      echo "📦 Starting PostgreSQL and Redis..."
      ${pkgs.docker-compose}/bin/docker-compose -f ${dockerComposeConfig} up -d

      echo "⏳ Waiting for services to be ready..."
      timeout=60
      elapsed=0
      until ${pkgs.docker}/bin/docker exec ${serviceName}-postgres-test pg_isready -U ${serviceName}_test -d ${serviceName}_test > /dev/null 2>&1; do
        if [ $elapsed -ge $timeout ]; then
          echo "❌ Timeout waiting for PostgreSQL"
          ${pkgs.docker-compose}/bin/docker-compose -f ${dockerComposeConfig} down
          exit 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
      done

      until ${pkgs.docker}/bin/docker exec ${serviceName}-redis-test redis-cli ping > /dev/null 2>&1; do
        if [ $elapsed -ge $timeout ]; then
          echo "❌ Timeout waiting for Redis"
          ${pkgs.docker-compose}/bin/docker-compose -f ${dockerComposeConfig} down
          exit 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
      done

      echo "✅ Services are ready!"

      echo "🗄️  Running database migrations..."
      ${pkgs.sqlx-cli}/bin/sqlx migrate run --database-url "$DATABASE_URL" --source ${migrationsPath}

      echo "🧪 Running integration tests..."
      ${rustToolchain}/bin/cargo test --test '*' --features test-helpers -- --ignored --test-threads=1

      test_result=$?

      echo "🧹 Cleaning up..."
      ${pkgs.docker-compose}/bin/docker-compose -f ${dockerComposeConfig} down -v

      if [ $test_result -eq 0 ]; then
        echo "✅ All integration tests passed!"
      else
        echo "❌ Integration tests failed!"
        exit $test_result
      fi
    '';
  };

  # DEPRECATED: Use rust-service.nix which auto-generates dev shells
  mkDevShell = {
    serviceName,
    craneLib,
    commonArgs,
    rustToolchain,
    extraPackages ? [],
  }:
    craneLib.devShell {
      packages = with pkgs;
        [
          cargo-watch
          cargo-expand
          cargo-edit
          postgresql
          redis
          sqlx-cli
          docker
          docker-compose
          just
          jq
        ]
        ++ extraPackages ++ [rustToolchain];

      shellHook = ''
        echo "${serviceName} Service Development Environment"
        echo ""
        echo "Development commands:"
        echo "  cargo build              - Build the service"
        echo "  cargo test --lib         - Run unit tests (fast)"
        echo "  cargo run --bin ${serviceName}     - Run the ${serviceName} service"
        echo "  sqlx migrate run         - Run database migrations"
        echo ""
        echo "Nix apps (standardized via forge):"
        echo "  nix run .#run            - Run service locally"
        echo "  nix run .#test           - Run unit tests"
        echo "  nix run .#dev            - Start docker-compose environment"
        echo "  nix run .#schema         - Extract GraphQL schema"
        echo ""
        echo "Deployment:"
        echo "  nix run .#build          - Build Docker image"
        echo "  nix run .#push           - Push to GHCR + Attic"
        echo "  nix run .#deploy         - Deploy to Kubernetes (GitOps)"
        echo "  nix run .#release        - Full workflow (build+push+deploy)"
        echo "  nix run .#rollout        - Monitor deployment status"
        echo ""
        echo "Type 'nix run .' or 'nix run .#default' to see all available commands"
        echo ""
        echo "Environment:"
        echo "  DATABASE_URL=${commonArgs.DATABASE_URL}"
        echo ""
      '';

      RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";
      SQLX_OFFLINE = "true";
      DATABASE_URL = commonArgs.DATABASE_URL;
    };

  # Generate CI-friendly checks for linting, formatting, and testing
  mkChecks = {
    craneLib,
    commonArgs,
    cargoArtifacts,
    src,
  }: {
    clippy = craneLib.cargoClippy (commonArgs
      // {
        inherit cargoArtifacts;
        cargoClippyExtraArgs = "--all-targets -- --deny warnings";
      });

    fmt = craneLib.cargoFmt {
      inherit src;
    };

    unit-tests = craneLib.cargoNextest (commonArgs
      // {
        inherit cargoArtifacts;
        partitions = 1;
        partitionType = "count";
      });
  };

  # Generate standard package outputs structure
  mkPackages = {
    serviceName,
    servicePackage,
    schemaExtractor ? null,
    dockerImages,
    testRunners,
  }:
    {
      default = servicePackage;
      "${serviceName}-service" = servicePackage;
    }
    // (
      if schemaExtractor != null
      then {
        extract-schema = schemaExtractor;
      }
      else {}
    )
    // dockerImages
    // {
      integration-test-env = pkgs.buildEnv {
        name = "${serviceName}-integration-test-env";
        paths = [
          testRunners.integration
          pkgs.docker-compose
          pkgs.postgresql
          pkgs.redis
          pkgs.sqlx-cli
        ];
      };
    };

  # Generate Kubernetes Job manifest for database migrations
  mkMigrationJob = {
    serviceName,
    productName,  # Required: product identifier
    namespace,    # Required: K8s namespace (e.g., "myapp-staging")
    registry,
    pullSecretName ? "ghcr-secret",
    configMapName ? "${serviceName}-config",
    resources ? {
      requests = {
        memory = "128Mi";
        cpu = "100m";
      };
      limits = {
        memory = "256Mi";
        cpu = "500m";
      };
    },
    timeout ? 300,
    ttlSecondsAfterFinished ? 3600,
  }: let
    check = import ../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "serviceName" serviceName)
      (check.nonEmptyStr "productName" productName)
      (check.nonEmptyStr "namespace" namespace)
      (check.nonEmptyStr "registry" registry)
      (check.positiveInt "timeout" timeout)
    ];
  in
    pkgs.writeText "${serviceName}-migration-job.yaml" ''
      ---
      # ${serviceName} Service Migration Job - Runs database migrations before service deployment
      apiVersion: batch/v1
      kind: Job
      metadata:
        name: ${serviceName}-migration
        namespace: ${namespace}
        labels:
          app: ${serviceName}
          component: migration
          service: ${serviceName}
          product: ${productName}
      spec:
        backoffLimit: 3
        activeDeadlineSeconds: ${toString timeout}
        ttlSecondsAfterFinished: ${toString ttlSecondsAfterFinished}
        template:
          metadata:
            labels:
              app: ${serviceName}
              component: migration
              service: ${serviceName}
              product: ${productName}
          spec:
            restartPolicy: Never
            imagePullSecrets:
            - name: ${pullSecretName}
            containers:
            - name: ${serviceName}-migrator
              image: ${registry}:latest
              imagePullPolicy: Always
              env:
              - name: RUN_MODE
                value: "migrate"
              - name: RUST_LOG
                value: "info,${serviceName}=debug"
              envFrom:
              - configMapRef:
                  name: ${configMapName}
              resources:
                requests:
                  memory: "${resources.requests.memory}"
                  cpu: "${resources.requests.cpu}"
                limits:
                  memory: "${resources.limits.memory}"
                  cpu: "${resources.limits.cpu}"
    '';

  # Generate migration job manifest file for a service
  mkMigrationJobApp = {
    serviceName,
    productName,  # Required: product identifier
    namespace,    # Required: K8s namespace
    cluster,      # Required: target cluster name (e.g., "staging", "production")
    registry,
    outputPath ? null,
  }: let
    migrationJob = mkMigrationJob {
      inherit serviceName productName namespace registry;
    };
    finalOutputPath =
      if outputPath != null
      then outputPath
      else "${serviceName}-migration-job.yaml";
  in {
    type = "app";
    program = toString (pkgs.writeShellScript "${serviceName}-generate-migration-job" ''
      set -euo pipefail

      REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
      SERVICE_DIR="$REPO_ROOT/k8s/clusters/${cluster}/products/${namespace}/services/${serviceName}"

      mkdir -p "$SERVICE_DIR"

      echo "📝 Generating migration job manifest..."
      cp ${migrationJob} "$SERVICE_DIR/${finalOutputPath}"

      echo "✅ Migration job manifest generated at:"
      echo "   $SERVICE_DIR/${finalOutputPath}"
      echo ""
      echo "To use this migration job, add it to kustomization.yaml resources:"
      echo "   - ${finalOutputPath}"
    '');
  };

  # Full release workflow with testing
  mkComprehensiveReleaseApp = {
    serviceName,
    productName,  # Required: product identifier
    namespace,    # Required: K8s namespace
    composeFile ? null,
    registry,
    flakeAttr ? "dockerImage-amd64",
    migrationsPath ? "./migrations",
    runMigrations ? true,
    dbPort ? 5434,
    dbUser ? "${serviceName}_test",
    dbPassword ? "test_password",
    dbName ? "${serviceName}_test",
    forge,
  }: {
    type = "app";
    program = toString (pkgs.writeShellScript "${serviceName}-comprehensive-release" ''
      set -euo pipefail

      export RELEASE_GIT_SHA=$(${pkgs.git}/bin/git rev-parse --short HEAD)

      REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
      WORK_DIR="$REPO_ROOT"

      echo "📦 Release Git SHA: $RELEASE_GIT_SHA"

      exec ${forgeCmd} comprehensive-release \
        --service-name ${serviceName} \
        --product-name ${productName} \
        --namespace ${namespace} \
        --flake-attr ${flakeAttr} \
        --working-dir "$WORK_DIR" \
        ${
        if composeFile != null
        then "--compose-file ${toString composeFile}"
        else ""
      } \
        --registry ${registry} \
        --migrations-path ${migrationsPath} \
        ${
        if runMigrations
        then "--run-migrations"
        else ""
      } \
        --cache-url "''${ATTIC_URL:-http://localhost:8080}" \
        --db-port ${toString dbPort} \
        --db-user ${dbUser} \
        --db-password ${dbPassword} \
        --db-name ${dbName} \
        --watch
    '');
  };

  # DEPRECATED: Use mkCrate2nixServiceApps for new services
  mkServiceApps = {
    serviceName,
    productName,  # Required: product identifier
    namespace,    # Required: K8s namespace
    cluster ? "staging",  # Target cluster name
    flakeAttr ? "dockerImage-amd64",
    registryBase,  # Required: registry base URL (e.g., "ghcr.io/myorg")
    ports ? {
      graphql = 8080;
      health = 8081;
      metrics = 9090;
    },
    atticToken ? defaultAtticToken,
    ghcrToken ? defaultGhcrToken,
    servicePackage,
    schemaExtractor ? null,
    runMigrations ? true,
    forge,
  }: let
    check = import ../types/assertions.nix;
    __ = check.all [
      (check.nonEmptyStr "serviceName" serviceName)
      (check.nonEmptyStr "productName" productName)
      (check.nonEmptyStr "namespace" namespace)
      (check.str "cluster" cluster)
    ];
    forgeTool = forge;
    registry = "${registryBase}/${productName}-${serviceName}";
  in
    {
      run = {
        type = "app";
        program = "${servicePackage}/bin/${serviceName}";
      };

      schema =
        if schemaExtractor != null
        then {
          type = "app";
          program = "${schemaExtractor}/bin/extract-schema";
        }
        else null;

      build = {
        type = "app";
        program = toString (pkgs.writeShellScript "${serviceName}-build" ''
          set -euo pipefail

          ${if atticToken != "" then ''export ATTIC_TOKEN="${atticToken}"'' else ''export ATTIC_TOKEN="''${ATTIC_TOKEN:-$(cat "$HOME/.config/attic/token" 2>/dev/null || true)}"''}

          REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
          WORK_DIR="$REPO_ROOT"

          exec ${forgeTool}/bin/forge build \
            --flake-attr ${flakeAttr} \
            --working-dir "$WORK_DIR" \
            --arch x86_64-linux \
            --cache-url "''${ATTIC_URL:-http://localhost:8080}" \
            --push-cache \
            --output result
        '');
      };

      push = {
        type = "app";
        program = toString (pkgs.writeShellScript "${serviceName}-push" ''
          set -euo pipefail

          ${if atticToken != "" then ''export ATTIC_TOKEN="${atticToken}"'' else ''export ATTIC_TOKEN="''${ATTIC_TOKEN:-$(cat "$HOME/.config/attic/token" 2>/dev/null || true)}"''}
          ${if ghcrToken != "" then ''export GHCR_TOKEN="${ghcrToken}"'' else ''export GHCR_TOKEN="''${GHCR_TOKEN:-''${GITHUB_TOKEN:-$(cat "$HOME/.config/github/token" 2>/dev/null || true)}}"''}

          # Get git SHA - check RELEASE_GIT_SHA first (set by release wrapper)
          if [ -n "''${RELEASE_GIT_SHA:-}" ]; then
            GIT_SHA="$RELEASE_GIT_SHA"
          elif [ -n "''${GIT_SHA:-}" ]; then
            GIT_SHA="$GIT_SHA"
          else
            GIT_SHA=$(${pkgs.git}/bin/git rev-parse --short HEAD)
          fi
          exec ${forgeTool}/bin/forge push \
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
        program = toString (pkgs.writeShellScript "${serviceName}-deploy" ''
          set -euo pipefail

          ${if atticToken != "" then ''export ATTIC_TOKEN="${atticToken}"'' else ''export ATTIC_TOKEN="''${ATTIC_TOKEN:-$(cat "$HOME/.config/attic/token" 2>/dev/null || true)}"''}
          ${if ghcrToken != "" then ''export GHCR_TOKEN="${ghcrToken}"'' else ''export GHCR_TOKEN="''${GHCR_TOKEN:-''${GITHUB_TOKEN:-$(cat "$HOME/.config/github/token" 2>/dev/null || true)}}"''}

          REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel)
          CURRENT_DIR="$PWD"
          GIT_SHA=$(${pkgs.git}/bin/git rev-parse --short HEAD)

          cd "$REPO_ROOT"
          rm -f result
          ln -s "$CURRENT_DIR/result" result

          exec ${forgeTool}/bin/forge deploy \
            --registry ${registry} \
            --tag "$GIT_SHA" \
            --namespace ${namespace} \
            --name ${serviceName} \
            --skip-build \
            --watch \
            --timeout 10m \
            --cache-url "''${ATTIC_URL:-http://localhost:8080}"
        '');
      };

      release = {
        type = "app";
        program = toString (pkgs.writeShellScript "${serviceName}-release" ''
          set -euo pipefail
          echo "🚀 ${serviceName} Service Release Workflow"
          echo "$(printf '=%.0s' {1..50})"
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

      rollout = {
        type = "app";
        program = toString (pkgs.writeShellScript "${serviceName}-rollout" ''
          set -euo pipefail
          exec ${forgeTool}/bin/forge rollout \
            --namespace ${namespace} \
            --name ${serviceName} \
            --interval 3
        '');
      };

      default = {
        type = "app";
        program = toString (pkgs.writeShellScript "${serviceName}-help" ''
          echo "${serviceName} Service"
          echo "$(printf '=%.0s' {1..50})"
          echo ""
          echo "Development:"
          echo "  nix run .#run               - Run service locally"
          echo "  nix run .#test              - Run unit tests"
          echo "  nix run .#test-integration  - Run integration tests"
          echo "  nix run .#dev               - Start docker-compose environment"
          ${
            if schemaExtractor != null
            then ''
              echo "  nix run .#schema            - Extract GraphQL schema"
            ''
            else ""
          }
          echo ""
          ${
            if runMigrations
            then ''
              echo "Migrations:"
              echo "  nix run .#generate-migration-job   - Generate migration job manifest"
              echo ""
            ''
            else ""
          }
          echo "Deployment (via forge):"
          echo "  nix run .#build                    - Build Docker image"
          echo "  nix run .#push                     - Push to GHCR + Attic cache"
          echo "  nix run .#deploy                   - Deploy to Kubernetes (GitOps)"
          echo "  nix run .#release                  - Full workflow (build+push+deploy)"
          echo "  nix run .#comprehensive_release    - Full workflow with testing"
          echo "                                       (unit tests + build + integration tests + push + deploy)"
          echo "  nix run .#rollout                  - Monitor deployment rollout"
          echo ""
          echo "All deployment operations use forge for:"
          echo "  • Pretty, formatted output"
          echo "  • Kubernetes API integration"
          echo "  • GitOps workflows"
          echo "  • Centralized deployment logic"
        '');
      };
    }
    // pkgs.lib.optionalAttrs runMigrations {
      generate-migration-job = mkMigrationJobApp {
        inherit serviceName productName namespace cluster;
        registry = registry;
      };
    };
}
