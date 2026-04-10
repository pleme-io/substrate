# Kubernetes DaemonSet builder.
#
# Pure function — no pkgs dependency.
let
  meta = import ./metadata.nix;
  containers = import ./container.nix;
  defs = import ../defaults.nix;
in rec {
  mkDaemonSet = {
    name,
    namespace,
    labels ? {},
    annotations ? {},
    selectorLabels ? {},
    updateStrategy ? { type = "RollingUpdate"; },
    serviceAccountName ? name,
    podSecurityContext ? defs.podSecurityContext,
    podAnnotations ? {},
    podLabels ? {},
    image,
    imagePullPolicy ? defs.image.pullPolicy,
    command ? [],
    args ? [],
    ports ? [],
    env ? [],
    envFrom ? [],
    resources ? defs.resources,
    containerSecurityContext ? defs.containerSecurityContext,
    livenessProbe ? null,
    readinessProbe ? null,
    volumeMounts ? [],
    volumes ? [],
    tolerations ? [],
    nodeSelector ? {},
    hostNetwork ? false,
  }: {
    apiVersion = "apps/v1";
    kind = "DaemonSet";
    metadata = meta.mkMetadata { inherit name namespace labels annotations; };
    spec = {
      selector.matchLabels = selectorLabels;
      inherit updateStrategy;
      template = {
        metadata = {
          labels = selectorLabels // podLabels;
          annotations = podAnnotations;
        };
        spec = {
          inherit serviceAccountName;
          securityContext = podSecurityContext;
          containers = [
            (containers.mkContainer {
              containerName = name;
              inherit image imagePullPolicy command args ports env envFrom
                      resources volumeMounts;
              securityContext = containerSecurityContext;
              inherit livenessProbe readinessProbe;
            })
          ];
        }
        // (if volumes != [] then { inherit volumes; } else {})
        // (if tolerations != [] then { inherit tolerations; } else {})
        // (if nodeSelector != {} then { inherit nodeSelector; } else {})
        // (if hostNetwork then { inherit hostNetwork; } else {});
      };
    };
  };
}
