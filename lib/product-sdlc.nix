# Product SDLC Apps
#
# Generates the full standard SDLC app set for any product using
# the Rust-backend + GraphQL + React/Web stack pattern.
#
# All apps use generic forge commands — no product-specific forge code required.
# The product name is auto-discovered from deploy.yaml at the repo root.
#
# Usage (zero-config):
#   apps = substrateLib.productSdlcApps;
#
# Usage (configured):
#   apps = substrateLib.mkProductSdlcApps {
#     backendDir = "services/rust/backend";
#     infraServices = [ "postgres" "redis" ];
#   };
#
# This generates (all without the :<product> suffix):
#   release, build, rollback, prerelease
#   codegen, schema, sync, drift-check
#   validate-rebac, sync-dashboards, drift-check-dashboards
#   seed, unseed, migrate
#   test, test:unit, test:integration, test:e2e, test:ci, test:coverage, bench
#   infra:up, infra:down, infra:clean
#   migration-new
#
# The forgeCli is resolved from the substrate default.nix forgeCmd.
{ pkgs, forgeCmd }:

# Returns a function accepting product-specific config.
# All params have sensible defaults so zero-config works.
{
  # Path to the backend service directory, relative to REPO_ROOT.
  # Used by: test:ci, test:coverage, bench, infra:*, migrate.
  # Set via deploy.yaml dirs.backend, or override here.
  # Env var BACKEND_DIR takes precedence at runtime.
  backendDir ? "services/rust/backend",

  # Docker Compose service names to start/stop with infra:up/down.
  # Only services in this list are brought up.
  infraServices ? [ "postgres" "redis" "nats" "minio" ],
}:

let
  # Build a minimal app that just wraps a forge command with REPO_ROOT resolved
  mkForgeApp = name: script: {
    type = "app";
    program = toString (pkgs.writeShellScript name script);
  };

  # Discover REPO_ROOT from git (preferred) or pwd
  repoRootExpr = ''REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || pwd)'';

  # Backend service dir — env var takes precedence over Nix-time param
  backendDirExpr = ''BACKEND_DIR=''${BACKEND_DIR:-$REPO_ROOT/${backendDir}}'';

  # Infra services as a space-separated string for docker compose
  infraServicesStr = builtins.concatStringsSep " " infraServices;

in rec {
  # ============================================================================
  # Release lifecycle
  # ============================================================================

  # Full product release: gates → build → push → deploy to all active envs
  # Usage: nix run .#release
  #        nix run .#release -- --env=staging
  #        SKIP_GATES=true nix run .#release
  release = mkForgeApp "product-release" ''
    set -euo pipefail
    export BUN_BIN="${pkgs.bun}/bin/bun"
    export SKOPEO_BIN="${pkgs.skopeo}/bin/skopeo"
    ${repoRootExpr}
    export RELEASE_GIT_SHA=$(${pkgs.git}/bin/git rev-parse --short HEAD)
    exec ${forgeCmd} product-release \
      --repo-root "$REPO_ROOT" \
      "$@"
  '';

  # Build-only: gates → build → push → update artifact JSONs (no deploy)
  build = mkForgeApp "product-build" ''
    set -euo pipefail
    export BUN_BIN="${pkgs.bun}/bin/bun"
    export SKOPEO_BIN="${pkgs.skopeo}/bin/skopeo"
    ${repoRootExpr}
    export RELEASE_GIT_SHA=$(${pkgs.git}/bin/git rev-parse --short HEAD)
    exec ${forgeCmd} product-release \
      --repo-root "$REPO_ROOT" \
      --build-only \
      "$@"
  '';

  # Rollback to the previous deployed version
  rollback = mkForgeApp "product-rollback" ''
    set -euo pipefail
    ${repoRootExpr}
    exec ${forgeCmd} rollback \
      --repo-root "$REPO_ROOT" \
      "$@"
  '';

  # Pre-release validation gates only (no actual release)
  prerelease = mkForgeApp "product-prerelease" ''
    set -euo pipefail
    export BUN_BIN="${pkgs.bun}/bin/bun"
    ${repoRootExpr}
    exec ${forgeCmd} prerelease \
      --working-dir "$REPO_ROOT" \
      "$@"
  '';

  # ============================================================================
  # Schema-driven development
  # ============================================================================

  # GraphQL codegen: export schema + generate TypeScript types
  codegen = mkForgeApp "product-codegen" ''
    export BUN_BIN="${pkgs.bun}/bin/bun"
    ${repoRootExpr}
    ${forgeCmd} codegen --working-dir "$REPO_ROOT"
  '';

  # Schema export only (no TypeScript codegen)
  schema = mkForgeApp "product-schema" ''
    export BUN_BIN="${pkgs.bun}/bin/bun"
    ${repoRootExpr}
    ${forgeCmd} codegen --working-dir "$REPO_ROOT" --schema-only
  '';

  # One-command sync: DB → entities → schema → types/hooks
  sync = mkForgeApp "product-sync" ''
    export BUN_BIN="${pkgs.bun}/bin/bun"
    ${repoRootExpr}
    ${forgeCmd} sync --working-dir "$REPO_ROOT" "$@"
  '';

  # Drift check (CI mode — fails if schema or codegen is out of sync)
  "drift-check" = mkForgeApp "product-drift-check" ''
    export BUN_BIN="${pkgs.bun}/bin/bun"
    ${repoRootExpr}
    ${forgeCmd} sync --working-dir "$REPO_ROOT" --check
  '';

  # ============================================================================
  # Observability and authorization
  # ============================================================================

  # ReBAC validation
  "validate-rebac" = mkForgeApp "product-validate-rebac" ''
    ${repoRootExpr}
    ${forgeCmd} rebac-validate --working-dir "$REPO_ROOT" "$@"
  '';

  # Dashboard sync (Observability as Code)
  "sync-dashboards" = mkForgeApp "product-sync-dashboards" ''
    ${repoRootExpr}
    ${forgeCmd} dashboards --working-dir "$REPO_ROOT" "$@"
  '';

  # Dashboard drift check (CI mode)
  "drift-check-dashboards" = mkForgeApp "product-drift-check-dashboards" ''
    ${repoRootExpr}
    ${forgeCmd} dashboards --working-dir "$REPO_ROOT" --check
  '';

  # ============================================================================
  # Data seeding
  # ============================================================================

  # Seed test profiles into an environment
  seed = mkForgeApp "product-seed" ''
    set -euo pipefail
    ${repoRootExpr}
    exec ${forgeCmd} seed \
      --working-dir "$REPO_ROOT" \
      "$@"
  '';

  # Remove seeded test profiles from an environment
  unseed = mkForgeApp "product-unseed" ''
    set -euo pipefail
    ${repoRootExpr}
    exec ${forgeCmd} unseed \
      --working-dir "$REPO_ROOT" \
      "$@"
  '';

  # ============================================================================
  # Testing
  # ============================================================================

  # Full test pyramid: unit → integration → e2e
  test = mkForgeApp "product-test" ''
    exec ${forgeCmd} test-pyramid --fail-fast "$@"
  '';

  "test:unit" = mkForgeApp "product-test-unit" ''
    exec ${forgeCmd} test-unit "$@"
  '';

  "test:integration" = mkForgeApp "product-test-integration" ''
    exec ${forgeCmd} test-integration "$@"
  '';

  "test:e2e" = mkForgeApp "product-test-e2e" ''
    exec ${forgeCmd} test-e2e "$@"
  '';

  # CI-optimized test run (cargo nextest with ci profile)
  "test:ci" = mkForgeApp "product-test-ci" ''
    set -euo pipefail
    ${repoRootExpr}
    ${backendDirExpr}
    exec ${forgeCmd} test-ci \
      --working-dir "$BACKEND_DIR" \
      --threads ''${RUST_TEST_THREADS:-4}
  '';

  # Run tests with coverage
  "test:coverage" = mkForgeApp "product-test-coverage" ''
    set -euo pipefail
    ${repoRootExpr}
    ${backendDirExpr}
    exec ${forgeCmd} test-coverage \
      --working-dir "$BACKEND_DIR" \
      --format html
  '';

  # Run benchmarks
  bench = mkForgeApp "product-bench" ''
    set -euo pipefail
    ${repoRootExpr}
    ${backendDirExpr}
    cd "$BACKEND_DIR"
    cargo bench "$@"
  '';

  # ============================================================================
  # Local infrastructure (Docker Compose)
  # ============================================================================

  "infra:up" = mkForgeApp "product-infra-up" ''
    set -euo pipefail
    ${repoRootExpr}
    ${backendDirExpr}
    exec ${forgeCmd} infra up \
      --working-dir "$BACKEND_DIR" \
      ${pkgs.lib.concatMapStringsSep " " (s: "--services ${s}") infraServices}
  '';

  "infra:down" = mkForgeApp "product-infra-down" ''
    set -euo pipefail
    ${repoRootExpr}
    ${backendDirExpr}
    exec ${forgeCmd} infra down --working-dir "$BACKEND_DIR"
  '';

  "infra:clean" = mkForgeApp "product-infra-clean" ''
    set -euo pipefail
    ${repoRootExpr}
    ${backendDirExpr}
    exec ${forgeCmd} infra clean --working-dir "$BACKEND_DIR"
  '';

  # ============================================================================
  # Database migrations
  # ============================================================================

  # Run migrations against local infrastructure.
  # DATABASE_URL must be set (from .envrc or environment).
  migrate = mkForgeApp "product-migrate" ''
    set -euo pipefail
    ${repoRootExpr}
    ${backendDirExpr}
    cd "$BACKEND_DIR"
    if [ -z "''${DATABASE_URL:-}" ]; then
      echo "error: DATABASE_URL is not set" >&2
      echo "Set it in your .envrc or environment before running migrate." >&2
      exit 1
    fi
    sqlx database create || true
    sqlx migrate run --source migrations
  '';

  # Scaffold a new migration
  "migration-new" = mkForgeApp "product-migration-new" ''
    set -euo pipefail
    ${repoRootExpr}
    exec ${forgeCmd} migration-new \
      --working-dir "$REPO_ROOT" \
      "$@"
  '';
}
