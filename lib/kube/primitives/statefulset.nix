# Kubernetes StatefulSet builder.
#
# Pure function — no pkgs dependency.
let
  meta = import ./metadata.nix;
  containers = import ./container.nix;
  defs = import ../defaults.nix;
in rec {
  mkStatefulSet = {
    name,
    namespace,
    labels ? {},
    annotations ? {},
    selectorLabels ? {},
    replicas ? 1,
    serviceName,
    podManagementPolicy ? "OrderedReady",
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
    startupProbe ? null,
    volumeMounts ? [],
    volumes ? [],
    volumeClaimTemplates ? [],
    initContainers ? [],
    terminationGracePeriodSeconds ? defs.terminationGracePeriodSeconds,
    priorityClassName ? null,
    nodeSelector ? {},
    tolerations ? [],
    affinity ? {},
  }: {
    apiVersion = "apps/v1";
    kind = "StatefulSet";
    metadata = meta.mkMetadata { inherit name namespace labels annotations; };
    spec = {
      inherit replicas serviceName podManagementPolicy;
      selector.matchLabels = selectorLabels;
      updateStrategy = updateStrategy;
      template = {
        metadata = {
          labels = selectorLabels // podLabels;
          annotations = podAnnotations;
        };
        spec = {
          inherit serviceAccountName terminationGracePeriodSeconds;
          securityContext = podSecurityContext;
          containers = [
            (containers.mkContainer {
              containerName = name;
              inherit image imagePullPolicy command args ports env envFrom
                      resources volumeMounts;
              securityContext = containerSecurityContext;
              inherit livenessProbe readinessProbe startupProbe;
            })
          ];
        }
        // (if initContainers != [] then { inherit initContainers; } else {})
        // (if volumes != [] then { inherit volumes; } else {})
        // (if priorityClassName != null then { inherit priorityClassName; } else {})
        // (if nodeSelector != {} then { inherit nodeSelector; } else {})
        // (if tolerations != [] then { inherit tolerations; } else {})
        // (if affinity != {} then { inherit affinity; } else {});
      };
    }
    // (if volumeClaimTemplates != [] then { inherit volumeClaimTemplates; } else {});
  };
}
