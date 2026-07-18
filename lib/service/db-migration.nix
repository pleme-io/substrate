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
  mkDbMigration = pkgs: let
    # Hardened by default (Pillar 8 / oci/hardened-base.nix). Both migration
    # types run through a `writeShellScript`-produced entrypoint -- the
    # runner IS a shell script (shebang + `for`/pipe logic), so a shell is
    # mandatory at RUNTIME regardless of type, ruling out a shell-less
    # distroless base outright. `wolfi` (cacert + nonroot passwd/group stub
    # + glibc + busybox) is a drop-in superset of the old ad-hoc
    # `[cacert busybox]`: same shell (busybox) for the script, same glibc
    # liquibase's JVM needs to run, plus TLS roots + (new) a real nonroot
    # user this image never set before (previously implicit root).
    hardened = import ../build/oci/hardened-base.nix { inherit pkgs; };
  in {
    name,
    type ? "liquibase",
    changelogFile ? null,
    migrationsDir ? null,
    extraArgs ? [],
  }: let
    check = import ../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "name" name)
      (check.enum "type" ["liquibase" "sql"] type)
    ];

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

    imageContents = with pkgs; (if type == "liquibase" then [ liquibase ] else []);

    dockerImage = pkgs.dockerTools.buildLayeredImage {
      name = "migrate-${name}";
      tag = "latest";
      fromImage = hardened.bases.wolfi;
      contents = imageContents;
      config = {
        Entrypoint = [ runner ];
        Env = [ "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];
        User = "${toString hardened.nonrootUid}:${toString hardened.nonrootGid}";
      };
    } // {
      closureInfo = pkgs.closureInfo {
        rootPaths = (hardened.bases.wolfi.contents or []) ++ imageContents;
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
