# Database Migration Runner
#
# Generic database schema migration pattern supporting Liquibase, sqlx,
# and raw SQL migrations. Extracts the common pattern from microservices
# that manage per-service schema evolution.
#
# Usage:
#   mkDbMigration = (import "${substrate}/lib/db-migration.nix").mkDbMigration;
#
#   # Liquibase-based migrations
#   migration = mkDbMigration pkgs {
#     name = "auth-service";
#     type = "liquibase";
#     changelogFile = ./db.changelog.xml;
#     # url, username, password set via env vars at runtime
#   };
#
#   # SQL file-based migrations
#   migration = mkDbMigration pkgs {
#     name = "vault-service";
#     type = "sql";
#     migrationsDir = ./migrations;
#   };
#
# Returns: { package, app, dockerImage }
#   - package: migration runner script
#   - app: nix run app for manual execution
#   - dockerImage: init container image for K8s
{
  mkDbMigration = pkgs: {
    name,
    type ? "liquibase",
    changelogFile ? null,
    migrationsDir ? null,
    extraArgs ? [],
  }: let
    inherit (pkgs) lib writeShellScript;

    liquibaseRunner = writeShellScript "migrate-${name}" ''
      set -euo pipefail
      DB_URL="''${DATABASE_URL:?DATABASE_URL required}"
      DB_USER="''${DATABASE_USER:-root}"
      DB_PASS="''${DATABASE_PASSWORD:-}"

      echo "Running Liquibase migrations for ${name}..."
      ${pkgs.liquibase}/bin/liquibase \
        --changeLogFile=${changelogFile} \
        --url="$DB_URL" \
        --username="$DB_USER" \
        --password="$DB_PASS" \
        update \
        ${lib.concatStringsSep " " extraArgs}
      echo "Migrations complete."
    '';

    sqlRunner = writeShellScript "migrate-${name}" ''
      set -euo pipefail
      DB_URL="''${DATABASE_URL:?DATABASE_URL required}"

      echo "Running SQL migrations for ${name} from ${migrationsDir}..."
      for f in ${migrationsDir}/*.sql; do
        echo "Applying: $(basename $f)"
        # Generic: pipe SQL files to database CLI
        # Users should set DATABASE_CLI to their DB client (mysql, psql, etc.)
        ''${DATABASE_CLI:-psql} "$DB_URL" < "$f"
      done
      echo "Migrations complete."
    '';

    runner = if type == "liquibase" then liquibaseRunner
             else if type == "sql" then sqlRunner
             else throw "Unsupported migration type: ${type}. Use 'liquibase' or 'sql'.";

    dockerImage = pkgs.dockerTools.buildLayeredImage {
      name = "migrate-${name}";
      tag = "latest";
      contents = with pkgs; [ cacert busybox ] ++
        (if type == "liquibase" then [ liquibase ] else []);
      config = {
        Entrypoint = [ runner ];
        Env = [ "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];
      };
    };
  in {
    package = runner;
    inherit dockerImage;
    app = {
      type = "app";
      program = "${runner}";
    };
  };
}
