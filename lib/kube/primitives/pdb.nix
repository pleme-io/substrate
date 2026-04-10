# Kubernetes PodDisruptionBudget builder.
#
# Pure function — no pkgs dependency.
let
  meta = import ./metadata.nix;
in rec {
  mkPDB = {
    name,
    namespace,
    labels ? {},
    selectorLabels ? {},
    minAvailable ? null,
    maxUnavailable ? null,
  }: {
    apiVersion = "policy/v1";
    kind = "PodDisruptionBudget";
    metadata = meta.mkMetadata { inherit name namespace labels; };
    spec = {
      selector.matchLabels = selectorLabels;
    }
    // (if minAvailable != null then { inherit minAvailable; } else {})
    // (if maxUnavailable != null then { inherit maxUnavailable; } else {});
  };
}
