# Kubernetes Service builder.
#
# Pure function — no pkgs dependency.
let
  meta = import ./metadata.nix;
in rec {
  mkService = {
    name,
    namespace,
    labels ? {},
    annotations ? {},
    selectorLabels ? {},
    type ? "ClusterIP",
    ports ? [],
    clusterIP ? null,
    attestation ? {},
  }: {
    apiVersion = "v1";
    kind = "Service";
    metadata = meta.mkMetadata {
      inherit name namespace labels;
      annotations = annotations // (meta.mkAttestationAnnotations attestation);
    };
    spec = {
      inherit type;
      ports = map (p: {
        inherit (p) name port targetPort;
        protocol = p.protocol or "TCP";
      }) ports;
      selector = selectorLabels;
    } // (if clusterIP != null then { inherit clusterIP; } else {});
  };

  mkHeadlessService = args: mkService (args // { clusterIP = "None"; });
}
