# KEDA ScaledObject builder.
#
# Pure function — no pkgs dependency.
let
  meta = import ./metadata.nix;
in rec {
  mkScaledObject = {
    name,
    namespace,
    labels ? {},
    targetRef,
    minReplicaCount ? 0,
    maxReplicaCount ? 4,
    cooldownPeriod ? 300,
    pollingInterval ? 15,
    triggers ? [],
  }: {
    apiVersion = "keda.sh/v1alpha1";
    kind = "ScaledObject";
    metadata = meta.mkMetadata { inherit name namespace labels; };
    spec = {
      scaleTargetRef = targetRef;
      inherit minReplicaCount maxReplicaCount cooldownPeriod pollingInterval triggers;
    };
  };
}
