# Substrate Infrastructure Spec Types
#
# Typed specifications for the Unified Infrastructure Theory.
# Formalizes the abstract workload archetypes from
# lib/infra/workload-archetypes.nix into a strict type contract.
#
# Every field in the archetype spec is now typed — invalid specs
# fail at declaration time, not deep in renderer evaluation.
#
# Pure — depends only on nixpkgs lib.
{ lib }:

let
  inherit (lib) types mkOption;
  foundation = import ./foundation.nix { inherit lib; };
  portTypes = import ./ports.nix { inherit lib; };
  serviceTypes = import ./service-spec.nix { inherit lib; };
in rec {
  # ── Workload Spec ─────────────────────────────────────────────────
  # The source-of-truth for all workload declarations. Renderers
  # (kubernetes.nix, tatara.nix, wasi.nix) consume this typed spec.
  workloadSpec = types.submodule {
    options = {
      name = mkOption {
        type = types.nonEmptyStr;
        description = "Workload name.";
      };
      archetype = mkOption {
        type = foundation.workloadArchetype;
        description = "Abstract workload type.";
      };
      ports = mkOption {
        type = types.listOf portTypes.portEntry;
        default = [];
        description = "Named port list for the workload.";
      };
      replicas = mkOption {
        type = types.ints.positive;
        default = 1;
      };
      resources = mkOption {
        type = serviceTypes.resourceSpec;
        default = {};
      };
      health = mkOption {
        type = types.nullOr serviceTypes.healthCheck;
        default = null;
      };
      scaling = mkOption {
        type = types.nullOr serviceTypes.scalingSpec;
        default = null;
      };
      secrets = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Secret names to mount.";
      };
      network = mkOption {
        type = serviceTypes.networkSpec;
        default = {};
      };
      env = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Environment variables.";
      };
      volumes = mkOption {
        type = types.listOf types.attrs;
        default = [];
      };
      meta = mkOption {
        type = types.attrsOf types.raw;
        default = {};
        description = "Arbitrary metadata (environment, namespace, etc.).";
      };
      annotations = mkOption {
        type = types.attrsOf types.str;
        default = {};
      };
      labels = mkOption {
        type = types.attrsOf types.str;
        default = {};
      };

      # ── Source detection hints ────────────────────────────────────
      source = mkOption {
        type = types.nullOr types.raw;
        default = null;
        description = "Flake self reference.";
      };
      image = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Container image reference.";
      };
      wasmPath = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "WASM component path.";
      };
      flakeRef = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Nix flake reference.";
      };
      command = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Direct exec command.";
      };
      args = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Command arguments.";
      };
      schedule = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Cron schedule (required for cron-job archetype).";
      };
      serviceName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Override service name (defaults to name).";
      };
    };
  };

  # ── Policy Rule ───────────────────────────────────────────────────
  policyRule = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        default = "unnamed";
        description = "Rule name for error reporting.";
      };
      match = mkOption {
        type = types.submodule {
          options = {
            archetype = mkOption {
              type = types.str;
              default = "*";
              description = "Archetype to match (* = all).";
            };
            env = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Environment to match.";
            };
            driver = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Driver to match.";
            };
          };
        };
        default = {};
      };
      require = mkOption {
        type = types.attrsOf types.raw;
        default = {};
        description = "Required field values (dotted paths supported).";
      };
      limit = mkOption {
        type = types.attrsOf types.raw;
        default = {};
        description = "Field upper bounds (resource limits).";
      };
    };
  };

  # ── Policy Spec ───────────────────────────────────────────────────
  policySpec = types.submodule {
    options = {
      name = mkOption {
        type = types.nonEmptyStr;
        description = "Policy name.";
      };
      description = mkOption {
        type = types.str;
        default = "";
      };
      rules = mkOption {
        type = types.listOf policyRule;
        default = [];
      };
    };
  };

  # ── Multi-Tier App Spec ───────────────────────────────────────────
  tierSpec = types.submodule {
    options = {
      archetype = mkOption {
        type = foundation.workloadArchetype;
        description = "Tier workload type.";
      };
      name = mkOption {
        type = types.nullOr types.nonEmptyStr;
        default = null;
        description = "Tier name (defaults to attrset key).";
      };
      ports = mkOption {
        type = types.listOf portTypes.portEntry;
        default = [];
      };
      replicas = mkOption {
        type = types.ints.positive;
        default = 1;
      };
      resources = mkOption {
        type = serviceTypes.resourceSpec;
        default = {};
      };
      health = mkOption {
        type = types.nullOr serviceTypes.healthCheck;
        default = null;
      };
      scaling = mkOption {
        type = types.nullOr serviceTypes.scalingSpec;
        default = null;
      };
      network = mkOption {
        type = serviceTypes.networkSpec;
        default = {};
      };
      image = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
    };
  };

  multiTierAppSpec = types.submodule {
    options = {
      name = mkOption {
        type = types.nonEmptyStr;
        description = "Application name.";
      };
      environment = mkOption {
        type = types.str;
        default = "staging";
      };
      tiers = mkOption {
        type = types.attrsOf tierSpec;
        description = "Named tiers (frontend, api, database, etc.).";
      };
    };
  };
}
