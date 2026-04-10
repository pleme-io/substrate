# Kubernetes PriorityClass builders.
#
# Pure function — no pkgs dependency.
let
  meta = import ./metadata.nix;
in rec {
  mkPriorityClass = {
    name,
    value,
    labels ? {},
    globalDefault ? false,
    preemptionPolicy ? "PreemptLowerPriority",
    description ? "",
  }: {
    apiVersion = "scheduling.k8s.io/v1";
    kind = "PriorityClass";
    metadata = meta.mkMetadata { inherit name labels; };
    inherit value globalDefault preemptionPolicy description;
  };

  # Standard 4-tier priority class set matching pleme-lib convention
  mkPriorityClassSet = { prefix ? "", labels ? {} }: [
    (mkPriorityClass { name = "${prefix}critical"; value = 10000000; inherit labels; description = "Critical system services"; })
    (mkPriorityClass { name = "${prefix}data"; value = 10500000; inherit labels; description = "Data services (databases, caches)"; })
    (mkPriorityClass { name = "${prefix}background"; value = 1000000; inherit labels; description = "Background workers"; })
    (mkPriorityClass { name = "${prefix}batch"; value = 100000; inherit labels; description = "Batch jobs"; })
  ];
}
