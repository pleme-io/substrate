# Istio PeerAuthentication builder.
#
# Pure function — no pkgs dependency.
let
  meta = import ./metadata.nix;
in rec {
  mkPeerAuthentication = {
    name,
    namespace,
    labels ? {},
    selectorLabels ? {},
    mode ? "STRICT",
    portLevelMtls ? null,
  }: {
    apiVersion = "security.istio.io/v1";
    kind = "PeerAuthentication";
    metadata = meta.mkMetadata { inherit name namespace labels; };
    spec = {
      selector.matchLabels = selectorLabels;
      mtls = { inherit mode; };
    } // (if portLevelMtls != null then { inherit portLevelMtls; } else {});
  };
}
