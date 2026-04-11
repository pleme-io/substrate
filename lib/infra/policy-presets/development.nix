# Development policy preset — relaxed rules for local development.
#
# Allows single replicas, no health checks, minimal resources.
let
  policies = import ../policies.nix;
in policies.mkPolicy {
  name = "development-standards";
  description = "Relaxed requirements for development environments";
  rules = [
    # Even in dev, resources should be defined (prevent unbounded consumption)
    {
      name = "resources-defined";
      match = { archetype = "*"; };
      require = { "resources" = "!null"; };
    }
  ];
}
