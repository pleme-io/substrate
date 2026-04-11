# Kubernetes Ingress builder.
#
# Pure function — no pkgs dependency.
let
  meta = import ./metadata.nix;
in rec {
  mkIngress = {
    name,
    namespace,
    labels ? {},
    annotations ? {},
    ingressClassName ? null,
    tls ? [],
    rules ? [],
    attestation ? {},
  }: {
    apiVersion = "networking.k8s.io/v1";
    kind = "Ingress";
    metadata = meta.mkMetadata {
      inherit name namespace labels;
      annotations = annotations // (meta.mkAttestationAnnotations attestation);
    };
    spec = {}
    // (if ingressClassName != null then { inherit ingressClassName; } else {})
    // (if tls != [] then { inherit tls; } else {})
    // (if rules != [] then { inherit rules; } else {});
  };

  # Convenience: single-host Ingress with TLS
  mkSimpleIngress = {
    name,
    namespace,
    labels ? {},
    host,
    serviceName,
    servicePort ? 80,
    ingressClassName ? "nginx",
    tlsSecretName ? null,
    pathType ? "Prefix",
    path ? "/",
  }: mkIngress {
    inherit name namespace labels ingressClassName;
    tls = if tlsSecretName != null then [{
      hosts = [ host ];
      secretName = tlsSecretName;
    }] else [];
    rules = [{
      inherit host;
      http.paths = [{
        inherit path pathType;
        backend.service = {
          name = serviceName;
          port.number = servicePort;
        };
      }];
    }];
  };
}
