# Kubernetes Job builder.
#
# Pure function — no pkgs dependency.
let
  meta = import ./metadata.nix;
  containers = import ./container.nix;
  defs = import ../defaults.nix;
in rec {
  mkJob = {
    name,
    namespace,
    labels ? {},
    annotations ? {},
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
    restartPolicy ? "Never",
    backoffLimit ? 6,
    activeDeadlineSeconds ? null,
    ttlSecondsAfterFinished ? null,
    volumeMounts ? [],
    volumes ? [],
  }: {
    apiVersion = "batch/v1";
    kind = "Job";
    metadata = meta.mkMetadata { inherit name namespace labels annotations; };
    spec = {
      inherit backoffLimit;
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
      } // (if volumes != [] then { inherit volumes; } else {});
    }
    // (if activeDeadlineSeconds != null then { spec.activeDeadlineSeconds = activeDeadlineSeconds; } else {})
    // (if ttlSecondsAfterFinished != null then { spec.ttlSecondsAfterFinished = ttlSecondsAfterFinished; } else {});
  };
}
