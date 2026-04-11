# Kubernetes Secret builder.
#
# Pure function — no pkgs dependency.
# Parallel to config-map.nix but for sensitive data.
# NOTE: Secret values should come from ExternalSecret CRDs or SOPS,
# not hardcoded in Nix (which would put them in the Nix store).
let
  meta = import ./metadata.nix;
in rec {
  mkSecret = {
    name,
    namespace,
    labels ? {},
    annotations ? {},
    data ? {},
    stringData ? {},
    type ? "Opaque",
  }: {
    apiVersion = "v1";
    kind = "Secret";
    metadata = meta.mkMetadata { inherit name namespace labels annotations; };
    inherit type;
  }
  // (if data != {} then { inherit data; } else {})
  // (if stringData != {} then { inherit stringData; } else {});

  # TLS Secret helper
  mkTlsSecret = {
    name,
    namespace,
    labels ? {},
    certData,
    keyData,
  }: mkSecret {
    inherit name namespace labels;
    type = "kubernetes.io/tls";
    data = {
      "tls.crt" = certData;
      "tls.key" = keyData;
    };
  };

  # Docker registry auth Secret helper
  mkDockerConfigSecret = {
    name,
    namespace,
    labels ? {},
    dockerConfigJson,
  }: mkSecret {
    inherit name namespace labels;
    type = "kubernetes.io/dockerconfigjson";
    data = {
      ".dockerconfigjson" = dockerConfigJson;
    };
  };
}
