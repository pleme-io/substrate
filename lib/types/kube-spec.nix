# Substrate Kubernetes Spec Types
#
# Typed specifications for Kubernetes resource primitives. These types
# formalize the arguments that kube/primitives/*.nix and
# kube/compositions/*.nix accept.
#
# Pure — depends only on nixpkgs lib.
{ lib }:

let
  inherit (lib) types mkOption;
  foundation = import ./foundation.nix { inherit lib; };
  serviceTypes = import ./service-spec.nix { inherit lib; };
in rec {
  # ── Kubernetes Metadata ───────────────────────────────────────────
  kubeMetadata = types.submodule {
    options = {
      name = mkOption {
        type = types.nonEmptyStr;
        description = "Resource name.";
      };
      namespace = mkOption {
        type = types.nullOr types.nonEmptyStr;
        default = null;
        description = "Namespace (null for cluster-scoped resources).";
      };
      labels = mkOption {
        type = types.attrsOf types.str;
        default = {};
      };
      annotations = mkOption {
        type = types.attrsOf types.str;
        default = {};
      };
    };
  };

  # ── Container Port ────────────────────────────────────────────────
  containerPort = types.submodule {
    options = {
      name = mkOption {
        type = types.nonEmptyStr;
        description = "Port name (e.g. 'http', 'grpc').";
      };
      containerPort = mkOption {
        type = types.port;
        description = "Port number inside the container.";
      };
      protocol = mkOption {
        type = foundation.networkProtocol;
        default = "TCP";
      };
    };
  };

  # ── Probe Spec ────────────────────────────────────────────────────
  probeSpec = types.submodule {
    options = {
      path = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "HTTP path (for httpGet probes).";
      };
      port = mkOption {
        type = types.either types.port types.nonEmptyStr;
        default = "http";
        description = "Port name or number.";
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
      successThreshold = mkOption {
        type = types.ints.positive;
        default = 1;
      };
      timeoutSeconds = mkOption {
        type = types.ints.positive;
        default = 1;
      };
    };
  };

  # ── Security Context ──────────────────────────────────────────────
  podSecurityContext = types.submodule {
    options = {
      runAsNonRoot = mkOption {
        type = types.bool;
        default = true;
      };
      runAsUser = mkOption {
        type = types.ints.unsigned;
        default = 1000;
      };
      runAsGroup = mkOption {
        type = types.ints.unsigned;
        default = 1000;
      };
      fsGroup = mkOption {
        type = types.ints.unsigned;
        default = 1000;
      };
    };
  };

  containerSecurityContext = types.submodule {
    options = {
      allowPrivilegeEscalation = mkOption {
        type = types.bool;
        default = false;
      };
      readOnlyRootFilesystem = mkOption {
        type = types.bool;
        default = true;
      };
      capabilities = mkOption {
        type = types.submodule {
          options = {
            drop = mkOption {
              type = types.listOf types.str;
              default = [ "ALL" ];
            };
            add = mkOption {
              type = types.listOf types.str;
              default = [];
            };
          };
        };
        default = {};
      };
    };
  };

  # ── Deployment Strategy ───────────────────────────────────────────
  deploymentStrategy = types.submodule {
    options = {
      type = mkOption {
        type = types.enum [ "RollingUpdate" "Recreate" ];
        default = "RollingUpdate";
      };
      maxUnavailable = mkOption {
        type = types.nullOr (types.either types.ints.unsigned types.str);
        default = null;
        description = "Max unavailable pods (int or percentage string).";
      };
      maxSurge = mkOption {
        type = types.nullOr (types.either types.ints.unsigned types.str);
        default = null;
        description = "Max surge pods (int or percentage string).";
      };
    };
  };

  # ── Composition Args (shared by all kube compositions) ────────────
  compositionArgs = types.submodule {
    options = {
      name = mkOption {
        type = types.nonEmptyStr;
      };
      namespace = mkOption {
        type = types.nonEmptyStr;
        default = "default";
      };
      image = mkOption {
        type = types.nonEmptyStr;
        description = "Container image reference.";
      };
      replicas = mkOption {
        type = types.ints.positive;
        default = 1;
      };
      ports = mkOption {
        type = types.listOf containerPort;
        default = [];
      };
      resources = mkOption {
        type = serviceTypes.resourceBounds;
        default = {};
      };
      env = mkOption {
        type = types.listOf (types.submodule {
          options = {
            name = mkOption { type = types.nonEmptyStr; };
            value = mkOption { type = types.str; };
          };
        });
        default = [];
      };
      monitoring = mkOption {
        type = serviceTypes.monitoringSpec;
        default = {};
      };
      networkPolicy = mkOption {
        type = types.submodule {
          options = {
            enabled = mkOption { type = types.bool; default = true; };
          };
        };
        default = {};
      };
      additionalLabels = mkOption {
        type = types.attrsOf types.str;
        default = {};
      };
    };
  };

  # ── RBAC Types ────────────────────────────────────────────────────
  rbacRule = types.submodule {
    options = {
      apiGroups = mkOption {
        type = types.listOf types.str;
        default = [ "" ];
      };
      resources = mkOption {
        type = types.listOf types.str;
      };
      verbs = mkOption {
        type = types.listOf (types.enum [
          "get" "list" "watch" "create" "update" "patch" "delete" "deletecollection"
        ]);
      };
    };
  };

  # ── Network Policy Types ──────────────────────────────────────────
  networkPolicyPeer = types.submodule {
    options = {
      podSelector = mkOption {
        type = types.nullOr types.attrs;
        default = null;
      };
      namespaceSelector = mkOption {
        type = types.nullOr types.attrs;
        default = null;
      };
      ipBlock = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            cidr = mkOption { type = types.str; };
            except = mkOption {
              type = types.listOf types.str;
              default = [];
            };
          };
        });
        default = null;
      };
    };
  };
}
