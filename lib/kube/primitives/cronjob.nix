# Kubernetes CronJob builder.
#
# Pure function — no pkgs dependency.
let
  meta = import ./metadata.nix;
  containers = import ./container.nix;
  defs = import ../defaults.nix;
in rec {
  mkCronJob = {
    name,
    namespace,
    labels ? {},
    annotations ? {},
    schedule,
    image,
    imagePullPolicy ? defs.image.pullPolicy,
    command ? [],
    args ? [],
    env ? [],
    envFrom ? [],
    resources ? defs.resources,
    securityContext ? defs.containerSecurityContext,
    podSecurityContext ? defs.podSecurityContext,
    serviceAccountName ? name,
    restartPolicy ? "OnFailure",
    concurrencyPolicy ? "Forbid",
    successfulJobsHistoryLimit ? 3,
    failedJobsHistoryLimit ? 1,
    activeDeadlineSeconds ? null,
    volumeMounts ? [],
    volumes ? [],
  }: {
    apiVersion = "batch/v1";
    kind = "CronJob";
    metadata = meta.mkMetadata { inherit name namespace labels annotations; };
    spec = {
      inherit schedule concurrencyPolicy successfulJobsHistoryLimit failedJobsHistoryLimit;
      jobTemplate.spec = {
        template.spec = {
          inherit serviceAccountName restartPolicy;
          securityContext = podSecurityContext;
          containers = [
            (containers.mkContainer {
              containerName = name;
              inherit image imagePullPolicy command args env envFrom resources volumeMounts;
              securityContext = securityContext;
            })
          ];
        }
        // (if volumes != [] then { template.spec.volumes = volumes; } else {});
      }
      // (if activeDeadlineSeconds != null then { inherit activeDeadlineSeconds; } else {});
    };
  };
}
