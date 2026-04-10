# Kubernetes Namespace builder.
#
# Pure function — no pkgs dependency.
let
  meta = import ./metadata.nix;
in rec {
  mkNamespace = {
    name,
    labels ? {},
    annotations ? {},
  }: {
    apiVersion = "v1";
    kind = "Namespace";
    metadata = meta.mkMetadata { inherit name labels annotations; };
  };
}
