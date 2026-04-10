# NATS JetStream delivery config builder.
#
# Pure function — no pkgs dependency.
# Produces a ConfigMap with delivery semantics matching pleme-lib.delivery.
let
  meta = import ./metadata.nix;
in rec {
  # Pre-built tier configurations
  tiers = {
    best_effort = {
      ack = false;
      maxRetries = 0;
      dlq = false;
    };
    durable = {
      ack = true;
      maxRetries = 3;
      retryDelay = "1s";
      dlq = true;
    };
    guaranteed = {
      ack = true;
      maxRetries = 10;
      retryDelay = "500ms";
      retryBackoff = "exponential";
      dlq = true;
      deduplication = true;
    };
  };

  mkDeliveryConfig = {
    name,
    namespace,
    labels ? {},
    tier ? "durable",
    nats ? {},
    buffer ? null,
    retry ? null,
    dlq ? null,
  }: let
    tierConfig = tiers.${tier} or tiers.durable;
    config = tierConfig // nats
      // (if buffer != null then { inherit buffer; } else {})
      // (if retry != null then { inherit retry; } else {})
      // (if dlq != null then { dlq = dlq; } else {});
  in {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = meta.mkMetadata { name = "${name}-delivery"; inherit namespace labels; };
    data."delivery.yaml" = builtins.toJSON config;
  };
}
