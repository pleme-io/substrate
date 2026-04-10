# Prometheus PodMonitor builder.
#
# Pure function — no pkgs dependency.
let
  meta = import ./metadata.nix;
  defs = import ../defaults.nix;
in rec {
  mkPodMonitor = {
    name,
    namespace,
    labels ? {},
    selectorLabels ? {},
    port ? "metrics",
    path ? defs.monitoring.path,
    interval ? defs.monitoring.interval,
    scrapeTimeout ? defs.monitoring.scrapeTimeout,
    namespaceSelector ? null,
  }: {
    apiVersion = "monitoring.coreos.com/v1";
    kind = "PodMonitor";
    metadata = meta.mkMetadata { inherit name namespace labels; };
    spec = {
      selector.matchLabels = selectorLabels;
      podMetricsEndpoints = [{
        inherit port path interval scrapeTimeout;
      }];
    } // (if namespaceSelector != null then { inherit namespaceSelector; } else {});
  };
}
