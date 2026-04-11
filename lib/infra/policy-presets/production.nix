# Production policy preset — enforces production-grade requirements.
#
# Apply via: policies.assertPolicies [ (import ./production.nix) ] spec
let
  policies = import ../policies.nix;
in policies.mkPolicy {
  name = "production-standards";
  description = "Minimum requirements for production deployments";
  rules = [
    {
      name = "min-replicas";
      match = { archetype = "*"; env = "production"; };
      require = { "scaling.min" = 2; };
    }
    {
      name = "health-check-required";
      match = { archetype = "http-service"; };
      require = { "health" = "!null"; };
    }
    {
      name = "health-check-gateway";
      match = { archetype = "gateway"; };
      require = { "health" = "!null"; };
    }
    {
      name = "resources-defined";
      match = { archetype = "*"; };
      require = { "resources" = "!null"; };
    }
  ];
}
