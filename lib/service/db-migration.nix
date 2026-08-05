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
    #
    # Below builds on `hardened.mkPackageImage` directly rather than a hand
    # `dockerTools.buildLayeredImage { fromImage = base; ... }` call --
    # this file carries no custom OCI labels (nothing under a `Labels` key
    # to merge), so the conversion is purely mechanical: `mkPackageImage`'s
    # own `io.pleme.rebuild.*`/`org.opencontainers.image.*` defaults now
    # apply where the direct call added none. See `dbPackage`'s own comment
    # below for the one real shape mismatch this call had to route around
    # (the entrypoint script can't be `package`).
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

    # DESHELLIFIED. This was a writeShellScript whose body was
    # `for f in ${migrationsDir}/*.sql; do ''${DATABASE_CLI:-psql} "$DB_URL" < "$f"; done`.
    # Two things were wrong with it beyond the no-shell rule:
    #
    #   1. Piping a whole file to a CLI yields ONE exit status for the file, so
    #      "this migration already ran" and "the table I need is missing" were
    #      indistinguishable. sql-apply splits the file and classifies each
    #      failure by driver error code, tolerating only the already-exists
    #      family (and only when asked).
    #   2. Because the runner WAS a shell script, a shell was mandatory at
    #      runtime, which is what pinned this pattern to the busybox-carrying
    #      wolfi base. A typed binary that talks TCP needs neither a shell nor a
    #      database CLI, so the sql type now runs distroless-static.
    #
    # $DATABASE_URL is unchanged -- the same env contract the shell runner used --
    # so this is a drop-in for consumers. $DATABASE_CLI is gone: sqlx dispatches
    # on the URL scheme (mysql:// or postgres://) instead.
    sqlApply = (import ../build/sql-apply.nix { inherit pkgs; });

    sqlRunnerArgs = [
      "${sqlApply}/bin/sql-apply"
      "apply"
      "--dir"
      "${migrationsDir}"
    ];

    # entrypoint, not a single script: the sql type's entrypoint is a typed
    # binary plus its flags, while liquibase remains a shell script wrapping a
    # JVM invocation.
    entrypointArgv =
      if type == "liquibase" then [ "${liquibaseRunner}" ]
      else if type == "sql" then sqlRunnerArgs
      else throw "Unsupported migration type: ${type}. Use 'liquibase' or 'sql'.";

    # The sql type no longer needs a shell OR a database CLI, so it drops from
    # wolfi (glibc + busybox) to distroless-static. liquibase still needs glibc
    # for its JVM and a shell for its wrapper, so it stays on wolfi -- the base
    # is now chosen by what the type actually requires rather than by the
    # runner's implementation language.
    imageBase =
      if type == "liquibase" then hardened.bases.wolfi
      else hardened.bases.distroless-static;

    # `hardened.mkPackageImage`'s `package` param is mandatory and gets
    # folded into `contents` via `buildLayeredImage`'s own
    # symlinkJoin/lndir merge -- which requires a DIRECTORY-shaped
    # derivation (`lndir` errors "Not a directory" against a raw file,
    # confirmed empirically 2026-07-18 against a `writeShellScript`
    # output). `runner` itself can therefore never BE that `package` --
    # exactly as before, it's referenced ONLY via `entrypoint` (Nix's own
    # textual reference-scan of the image config JSON is what pulls a
    # referenced derivation's closure into the image; `contents` is a
    # separate, directory-merge-only concern). `dbPackage` below is the
    # type's REAL extra runtime content instead: liquibase's JVM + jars
    # for the liquibase type, nothing for the sql type. `pkgs.emptyDirectory`
    # (a real nixpkgs primitive -- an immutable, content-addressed empty
    # directory) stands in for "nothing" so the mandatory `package` param
    # is satisfiable without smuggling anything extra into the sql image.
    dbPackage = if type == "liquibase" then pkgs.liquibase else pkgs.emptyDirectory;

    dockerImage = hardened.mkPackageImage {
      service = name;
      base = imageBase;
      package = dbPackage;
      publishName = "migrate-${name}";
      publishTag = "latest";
      entrypoint = entrypointArgv;
      env = [ "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];
      user = "${toString hardened.nonrootUid}:${toString hardened.nonrootGid}";
    };
  in {
    # `package` is the executable itself: the typed binary for the sql type, the
    # JVM wrapper script for liquibase.
    package = if type == "liquibase" then liquibaseRunner else sqlApply;
    inherit dockerImage;
    app = {
      type = "app";
      program =
        if type == "liquibase" then "${liquibaseRunner}" else "${sqlApply}/bin/sql-apply";
    };
  };
}
