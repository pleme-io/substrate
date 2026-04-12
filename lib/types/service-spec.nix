# Substrate Service Spec Types
#
# Typed specifications for service health checks, scaling policies,
# and runtime configuration. Used by both build-time service builders
# and deploy-time infrastructure archetypes.
#
# Pure — depends only on nixpkgs lib.
{ lib }:

let
  inherit (lib) types mkOption;
  foundation = import ./foundation.nix { inherit lib; };
in rec {
  # ── Health Check Spec ─────────────────────────────────────────────
  healthCheck = types.submodule {
    options = {
      path = mkOption {
        type = types.str;
        default = "/healthz";
        description = "HTTP path for health check.";
      };
      port = mkOption {
        type = types.either types.port (types.enum [ "http" "grpc" "health" "metrics" ]);
        default = "http";
        description = "Port name or number for health check.";
      };
      initialDelaySeconds = mkOption {
        type = types.ints.unsigned;
        default = 5;
      };
      periodSeconds = mkOption {
        type = types.ints.positive;
        default = 10;
      };
      failureThreshold = mkOption {
        type = types.ints.positive;
        default = 3;
      };
    };
  };

  # ── Scaling Spec ──────────────────────────────────────────────────
  scalingSpec = types.submodule {
    options = {
      min = mkOption {
        type = types.ints.unsigned;
        default = 1;
        description = "Minimum replicas (0 enables scale-to-zero via KEDA).";
      };
      max = mkOption {
        type = types.ints.positive;
        default = 10;
        description = "Maximum replicas.";
      };
      targetCpuPercent = mkOption {
        type = types.ints.between 1 100;
        default = 80;
        description = "CPU utilization target for HPA.";
      };
      targetMemoryPercent = mkOption {
        type = types.nullOr (types.ints.between 1 100);
        default = null;
        description = "Memory utilization target for HPA (null = disabled).";
      };
    };
  };

  # ── Resource Spec ─────────────────────────────────────────────────
  resourceSpec = types.submodule {
    options = {
      cpu = mkOption {
        type = foundation.cpuQuantity;
        default = "100m";
        description = "CPU request/limit (e.g. '100m', '2').";
      };
      memory = mkOption {
        type = foundation.memoryQuantity;
        default = "128Mi";
        description = "Memory request/limit (e.g. '128Mi', '4Gi').";
      };
    };
  };

  # ── Resource Requests + Limits ────────────────────────────────────
  resourceBounds = types.submodule {
    options = {
      requests = mkOption {
        type = resourceSpec;
        default = {};
        description = "Resource requests (scheduler hint).";
      };
      limits = mkOption {
        type = resourceSpec;
        default = {};
        description = "Resource limits (hard cap).";
      };
    };
  };

  # ── Network Spec ──────────────────────────────────────────────────
  networkSpec = types.submodule {
    options = {
      ingress = mkOption {
        type = types.listOf types.attrs;
        default = [];
        description = "Ingress rules (from which sources traffic is allowed).";
      };
      egress = mkOption {
        type = types.listOf types.attrs;
        default = [];
        description = "Egress rules (to which destinations traffic is allowed).";
      };
      policies = mkOption {
        type = types.listOf types.attrs;
        default = [];
        description = "Additional network policies.";
      };
    };
  };

  # ── Monitoring Spec ───────────────────────────────────────────────
  monitoringSpec = types.submodule {
    options = {
      enabled = mkOption {
        type = types.bool;
        default = true;
      };
      port = mkOption {
        type = types.either types.port (types.enum [ "http" "metrics" ]);
        default = "http";
      };
      path = mkOption {
        type = types.str;
        default = "/metrics";
      };
      interval = mkOption {
        type = types.str;
        default = "30s";
      };
    };
  };
}
