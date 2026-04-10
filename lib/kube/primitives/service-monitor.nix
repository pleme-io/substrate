# Prometheus ServiceMonitor builder.
#
# Pure function — no pkgs dependency.
let
  meta = import ./metadata.nix;
  defs = import ../defaults.nix;
in rec {
  mkServiceMonitor = {
    name,
    namespace,
    labels ? {},
    selectorLabels ? {},
    port ? defs.monitoring.port,
    path ? defs.monitoring.path,
    interval ? defs.monitoring.interval,
    scrapeTimeout ? defs.monitoring.scrapeTimeout,
    endpoints ? null,
  }: {
    apiVersion = "monitoring.coreos.com/v1";
    kind = "ServiceMonitor";
    metadata = meta.mkMetadata { inherit name namespace labels; };
    spec = {
      selector.matchLabels = selectorLabels;
      endpoints = if endpoints != null then endpoints else [{
        inherit port path interval scrapeTimeout;
      }];
    };
  };
}
