# Istio DestinationRule builder.
#
# Pure function — no pkgs dependency.
let
  meta = import ./metadata.nix;
in rec {
  mkDestinationRule = {
    name,
    namespace,
    labels ? {},
    host,
    trafficPolicy ? {},
  }: {
    apiVersion = "networking.istio.io/v1";
    kind = "DestinationRule";
    metadata = meta.mkMetadata { inherit name namespace labels; };
    spec = {
      inherit host;
    } // (if trafficPolicy != {} then { inherit trafficPolicy; } else {});
  };
}
