# Kubernetes LimitRange builder.
#
# Pure function — no pkgs dependency.
let
  meta = import ./metadata.nix;
in rec {
  mkLimitRange = {
    name,
    namespace,
    labels ? {},
    container ? null,
    pod ? null,
    pvc ? null,
  }: let
    limits =
      (if container != null then [({ type = "Container"; } // container)] else [])
      ++ (if pod != null then [({ type = "Pod"; } // pod)] else [])
      ++ (if pvc != null then [({ type = "PersistentVolumeClaim"; } // pvc)] else []);
  in {
    apiVersion = "v1";
    kind = "LimitRange";
    metadata = meta.mkMetadata { inherit name namespace labels; };
    spec = { inherit limits; };
  };
}
