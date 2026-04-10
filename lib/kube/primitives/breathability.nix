# KEDA breathability (zero-scale) + HPA composition.
#
# Pure functions — no pkgs dependency.
# Matches pleme-lib.breathability pattern.
let
  scaledObj = import ./scaled-object.nix;
  hpaLib = import ./hpa.nix;
in rec {
  mkBreathability = {
    name,
    namespace,
    labels ? {},
    targetRef,
    min ? 0,
    max ? 4,
    cooldown ? 300,
    pollingInterval ? 15,
    trigger ? null,
    hpa ? null,
  }: let
    kedaObj = scaledObj.mkScaledObject {
      inherit name namespace labels;
      targetRef = targetRef;
      minReplicaCount = min;
      maxReplicaCount = max;
      cooldownPeriod = cooldown;
      inherit pollingInterval;
      triggers = if trigger != null then [ trigger ] else [];
    };
    hpaObj = if hpa != null && (hpa.enabled or false) then
      hpaLib.mkHPA {
        inherit name namespace labels;
        targetRef = targetRef;
        minReplicas = hpa.minReplicas or 1;
        maxReplicas = hpa.maxReplicas or max;
        targetCPUUtilizationPercentage = hpa.targetCPU or null;
        targetMemoryUtilizationPercentage = hpa.targetMemory or null;
      }
    else null;
  in
    [ kedaObj ] ++ (if hpaObj != null then [ hpaObj ] else []);
}
