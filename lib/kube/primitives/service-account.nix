# Kubernetes ServiceAccount builder.
#
# Pure function — no pkgs dependency.
let
  meta = import ./metadata.nix;
in rec {
  mkServiceAccount = {
    name,
    namespace,
    labels ? {},
    annotations ? {},
    automountServiceAccountToken ? null,
  }: {
    apiVersion = "v1";
    kind = "ServiceAccount";
    metadata = meta.mkMetadata { inherit name namespace labels annotations; };
  } // (if automountServiceAccountToken != null then { inherit automountServiceAccountToken; } else {});
}
