# Kubernetes Deployment builder.
#
# Pure function — no pkgs dependency.
let
  meta = import ./metadata.nix;
  containers = import ./container.nix;
  defs = import ../defaults.nix;
in rec {
  mkDeployment = {
    name,
    namespace,
    labels ? {},
    annotations ? {},
    selectorLabels ? {},
    replicas ? defs.replicas,
    autoscalingEnabled ? false,
    strategy ? defs.strategy,
    serviceAccountName ? name,
    imagePullSecrets ? [],
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
    lifecycle ? {},
    initContainers ? [],
    sidecars ? [],
    volumes ? [],
    terminationGracePeriodSeconds ? defs.terminationGracePeriodSeconds,
    priorityClassName ? null,
    topologySpreadConstraints ? [],
    nodeSelector ? {},
    tolerations ? [],
    affinity ? {},
    attestation ? {},
    downwardApi ? false,
    minReadySeconds ? null,
    revisionHistoryLimit ? null,
  }: {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = meta.mkMetadata {
      inherit name namespace labels;
      annotations = annotations // (meta.mkAttestationAnnotations attestation);
    };
    spec = {
      selector.matchLabels = selectorLabels;
      inherit strategy;
    }
    // (if !autoscalingEnabled then { inherit replicas; } else {})
    // (if minReadySeconds != null then { inherit minReadySeconds; } else {})
    // (if revisionHistoryLimit != null then { inherit revisionHistoryLimit; } else {})
    // {
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
                      resources volumeMounts lifecycle downwardApi;
              securityContext = containerSecurityContext;
              inherit livenessProbe readinessProbe startupProbe;
            })
          ] ++ sidecars;
        }
        // (if imagePullSecrets != [] then { inherit imagePullSecrets; } else {})
        // (if initContainers != [] then { inherit initContainers; } else {})
        // (if volumes != [] then { inherit volumes; } else {})
        // (if priorityClassName != null then { inherit priorityClassName; } else {})
        // (if topologySpreadConstraints != [] then { inherit topologySpreadConstraints; } else {})
        // (if nodeSelector != {} then { inherit nodeSelector; } else {})
        // (if tolerations != [] then { inherit tolerations; } else {})
        // (if affinity != {} then { inherit affinity; } else {});
      };
    };
  };
}
