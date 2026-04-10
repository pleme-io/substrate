# Kubernetes ConfigMap builders.
#
# Pure functions — no pkgs dependency.
let
  meta = import ./metadata.nix;
in rec {
  mkConfigMap = {
    name,
    namespace,
    labels ? {},
    annotations ? {},
    data ? {},
    binaryData ? {},
  }: {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = meta.mkMetadata { inherit name namespace labels annotations; };
  }
  // (if data != {} then { inherit data; } else {})
  // (if binaryData != {} then { inherit binaryData; } else {});

  # Build multiple ConfigMaps from a list of configs
  mkConfigMaps = {
    namespace,
    labels ? {},
    configs ? [],
  }: map (c: mkConfigMap {
    name = c.name;
    inherit namespace labels;
    data = c.data or {};
  }) configs;
}
