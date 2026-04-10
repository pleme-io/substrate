# Kubernetes HorizontalPodAutoscaler (v2) builder.
#
# Pure function — no pkgs dependency.
let
  meta = import ./metadata.nix;
in rec {
  mkHPA = {
    name,
    namespace,
    labels ? {},
    targetRef ? { apiVersion = "apps/v1"; kind = "Deployment"; inherit name; },
    minReplicas ? 1,
    maxReplicas ? 5,
    targetCPUUtilizationPercentage ? null,
    targetMemoryUtilizationPercentage ? null,
    metrics ? null,
    behavior ? null,
  }: let
    autoMetrics =
      (if targetCPUUtilizationPercentage != null then [{
        type = "Resource";
        resource = {
          name = "cpu";
          target = { type = "Utilization"; averageUtilization = targetCPUUtilizationPercentage; };
        };
      }] else [])
      ++ (if targetMemoryUtilizationPercentage != null then [{
        type = "Resource";
        resource = {
          name = "memory";
          target = { type = "Utilization"; averageUtilization = targetMemoryUtilizationPercentage; };
        };
      }] else []);
    finalMetrics = if metrics != null then metrics else autoMetrics;
  in {
    apiVersion = "autoscaling/v2";
    kind = "HorizontalPodAutoscaler";
    metadata = meta.mkMetadata { inherit name namespace labels; };
    spec = {
      scaleTargetRef = targetRef;
      inherit minReplicas maxReplicas;
    }
    // (if finalMetrics != [] then { metrics = finalMetrics; } else {})
    // (if behavior != null then { inherit behavior; } else {});
  };
}
