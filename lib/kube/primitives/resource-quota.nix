# Kubernetes ResourceQuota builder.
#
# Pure function — no pkgs dependency.
let
  meta = import ./metadata.nix;
in rec {
  mkResourceQuota = {
    name,
    namespace,
    labels ? {},
    hard ? {},
  }: {
    apiVersion = "v1";
    kind = "ResourceQuota";
    metadata = meta.mkMetadata { inherit name namespace labels; };
    spec = { inherit hard; };
  };
}
