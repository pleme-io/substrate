# Prometheus PrometheusRule builder.
#
# Pure functions — no pkgs dependency.
let
  meta = import ./metadata.nix;
in rec {
  mkPrometheusRule = {
    name,
    namespace,
    labels ? {},
    groups ? [],
  }: {
    apiVersion = "monitoring.coreos.com/v1";
    kind = "PrometheusRule";
    metadata = meta.mkMetadata { inherit name namespace labels; };
    spec = { inherit groups; };
  };

  # Pre-built standard alerts matching pleme-lib.alerts
  mkStandardAlerts = {
    name,
    namespace,
    labels ? {},
    podRestartThreshold ? 5,
    highMemoryThreshold ? 90,
    highErrorRateThreshold ? 5,
    highLatencyThreshold ? 1,
    custom ? [],
  }: mkPrometheusRule {
    name = "${name}-alerts";
    inherit namespace labels;
    groups = [{
      name = "${name}.rules";
      rules = [
        {
          alert = "${name}PodRestarting";
          expr = "increase(kube_pod_container_status_restarts_total{namespace=\"${namespace}\",pod=~\"${name}.*\"}[1h]) > ${toString podRestartThreshold}";
          "for" = "5m";
          labels.severity = "warning";
          annotations = {
            summary = "${name} pod restarting frequently";
            description = "Pod {{ $labels.pod }} restarted {{ $value }} times in the last hour.";
          };
        }
        {
          alert = "${name}HighMemory";
          expr = "container_memory_working_set_bytes{namespace=\"${namespace}\",container=\"${name}\"} / container_spec_memory_limit_bytes{namespace=\"${namespace}\",container=\"${name}\"} * 100 > ${toString highMemoryThreshold}";
          "for" = "5m";
          labels.severity = "warning";
          annotations = {
            summary = "${name} memory usage high";
            description = "Container {{ $labels.container }} using {{ $value }}% of memory limit.";
          };
        }
        {
          alert = "${name}HighErrorRate";
          expr = "rate(http_requests_total{namespace=\"${namespace}\",job=\"${name}\",code=~\"5..\"}[5m]) / rate(http_requests_total{namespace=\"${namespace}\",job=\"${name}\"}[5m]) * 100 > ${toString highErrorRateThreshold}";
          "for" = "5m";
          labels.severity = "critical";
          annotations = {
            summary = "${name} high error rate";
            description = "Error rate is {{ $value }}%.";
          };
        }
        {
          alert = "${name}HighLatency";
          expr = "histogram_quantile(0.99, rate(http_request_duration_seconds_bucket{namespace=\"${namespace}\",job=\"${name}\"}[5m])) > ${toString highLatencyThreshold}";
          "for" = "5m";
          labels.severity = "warning";
          annotations = {
            summary = "${name} high latency";
            description = "P99 latency is {{ $value }}s.";
          };
        }
      ] ++ custom;
    }];
  };
}
