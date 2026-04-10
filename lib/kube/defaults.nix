# nix-kube defaults
#
# Shared default values matching pleme-lib Helm chart conventions.
# All values here are pure data — no pkgs dependency.
{
  # ── Image ──────────────────────────────────────────────────────
  image = {
    pullPolicy = "Always";
  };

  # ── Replicas ───────────────────────────────────────────────────
  replicas = 1;

  # ── Security Contexts ─────────────────────────────────────────
  podSecurityContext = {
    runAsNonRoot = true;
    runAsUser = 1000;
    runAsGroup = 1000;
    fsGroup = 1000;
  };

  containerSecurityContext = {
    allowPrivilegeEscalation = false;
    readOnlyRootFilesystem = true;
    capabilities.drop = [ "ALL" ];
  };

  # ── Probes ─────────────────────────────────────────────────────
  liveness = {
    path = "/healthz";
    port = "http";
    initialDelaySeconds = 5;
    periodSeconds = 10;
    failureThreshold = 3;
  };

  readiness = {
    path = "/readyz";
    port = "http";
    initialDelaySeconds = 5;
    periodSeconds = 5;
    failureThreshold = 2;
  };

  startup = {
    path = "/healthz";
    port = "http";
    initialDelaySeconds = 0;
    periodSeconds = 5;
    failureThreshold = 30;
  };

  # ── Resources ──────────────────────────────────────────────────
  resources = {
    requests = { cpu = "50m"; memory = "64Mi"; };
    limits = { cpu = "200m"; memory = "256Mi"; };
  };

  # ── Monitoring ─────────────────────────────────────────────────
  monitoring = {
    port = "http";
    path = "/metrics";
    interval = "30s";
    scrapeTimeout = "10s";
  };

  # ── Network Policy ────────────────────────────────────────────
  networkPolicy = {
    allowDns = true;
    allowPrometheus = true;
    prometheusNamespaces = [ "prometheus-operator" ];
  };

  # ── Labels ─────────────────────────────────────────────────────
  partOf = "nexus-platform";
  managedBy = "nix-kube";

  # ── Termination ────────────────────────────────────────────────
  terminationGracePeriodSeconds = 30;

  # ── Strategy ───────────────────────────────────────────────────
  strategy = { type = "RollingUpdate"; };
}
