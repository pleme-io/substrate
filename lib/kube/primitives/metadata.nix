# Kubernetes metadata, labels, and annotation builders.
#
# Pure functions — no pkgs dependency.
# Reuses mkMetadata from lib/infra/k8s-manifest.nix.
let
  k8s = import ../../infra/k8s-manifest.nix;
in rec {
  # Re-export k8s.mkMetadata for use within the kube module
  inherit (k8s) mkMetadata;

  # Standard Kubernetes labels following pleme-lib.labels convention
  mkLabels = {
    name,
    instance ? name,
    version ? "latest",
    component ? null,
    partOf ? "nexus-platform",
    managedBy ? "nix-kube",
    additionalLabels ? {},
  }: {
    "app.kubernetes.io/name" = name;
    "app.kubernetes.io/instance" = instance;
    "app.kubernetes.io/version" = version;
    "app.kubernetes.io/managed-by" = managedBy;
    "app.kubernetes.io/part-of" = partOf;
    app = instance;
  } // (if component != null then { "app.kubernetes.io/component" = component; } else {})
    // additionalLabels;

  # Selector subset (immutable after creation)
  mkSelectorLabels = { name, instance ? name }: {
    "app.kubernetes.io/name" = name;
    "app.kubernetes.io/instance" = instance;
  };

  # Attestation annotations for sekiban integrity verification
  mkAttestationAnnotations = {
    enabled ? false,
    signature ? null,
    certificationHash ? null,
    complianceHash ? null,
    changesetHash ? null,
  }: if !enabled then {} else
    {}
    // (if signature != null then { "sekiban.pleme.io/signature" = signature; } else {})
    // (if certificationHash != null then { "sekiban.pleme.io/certification-hash" = certificationHash; } else {})
    // (if complianceHash != null then { "sekiban.pleme.io/compliance-hash" = complianceHash; } else {})
    // (if changesetHash != null then { "sekiban.pleme.io/changeset-hash" = changesetHash; } else {});

  # Prometheus scrape annotations for pod templates
  mkPrometheusAnnotations = {
    enabled ? true,
    port ? "8080",
    path ? "/metrics",
  }: if !enabled then {} else {
    "prometheus.io/scrape" = "true";
    "prometheus.io/port" = toString port;
    "prometheus.io/path" = path;
  };

  # Istio sidecar annotations for pod templates
  mkIstioAnnotations = {
    enabled ? false,
    inject ? true,
    excludeOutboundPorts ? null,
    excludeInboundPorts ? null,
  }: if !enabled then {} else
    { "sidecar.istio.io/inject" = if inject then "true" else "false"; }
    // (if excludeOutboundPorts != null then { "traffic.sidecar.istio.io/excludeOutboundPorts" = excludeOutboundPorts; } else {})
    // (if excludeInboundPorts != null then { "traffic.sidecar.istio.io/excludeInboundPorts" = excludeInboundPorts; } else {});

  # Full resource name with 63-char K8s limit
  mkFullname = { name, instance ? name, fullnameOverride ? null, nameOverride ? null }:
    let
      raw = if fullnameOverride != null then fullnameOverride
            else if nameOverride != null then "${instance}-${nameOverride}"
            else name;
    in builtins.substring 0 63 raw;
}
