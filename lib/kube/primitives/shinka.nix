# Shinka DatabaseMigration CRD builder + wait init container.
#
# Pure functions — no pkgs dependency.
let
  meta = import ./metadata.nix;
in rec {
  mkDatabaseMigration = {
    name,
    namespace,
    labels ? {},
    database,
    migrator,
    safety ? null,
    timeouts ? null,
  }: {
    apiVersion = "shinka.pleme.io/v1alpha1";
    kind = "DatabaseMigration";
    metadata = meta.mkMetadata { inherit name namespace labels; };
    spec = {
      inherit database migrator;
    }
    // (if safety != null then { inherit safety; } else {})
    // (if timeouts != null then { inherit timeouts; } else {});
  };

  # Init container that blocks until Shinka migration completes
  mkShinkaWaitContainer = {
    name,
    image ? "ghcr.io/pleme-io/shinka:amd64-latest",
    migrationName ? name,
    timeoutSeconds ? 300,
    retryIntervalSeconds ? 5,
    logLevel ? "info",
    resources ? { requests = { cpu = "10m"; memory = "16Mi"; }; limits = { cpu = "50m"; memory = "32Mi"; }; },
  }: {
    name = "shinka-wait";
    inherit image resources;
    command = [ "shinka-wait" ];
    args = [
      "--migration-name" migrationName
      "--timeout" (toString timeoutSeconds)
      "--retry-interval" (toString retryIntervalSeconds)
      "--log-level" logLevel
    ];
    securityContext = {
      allowPrivilegeEscalation = false;
      readOnlyRootFilesystem = true;
      capabilities.drop = [ "ALL" ];
    };
  };
}
