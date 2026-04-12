# Substrate Type Foundation
#
# Domain-specific enumeration types and refined primitives for the
# substrate build system. These form the leaves of the type lattice —
# every builder input and output references types defined here.
#
# Pure — depends only on nixpkgs lib.
#
# Usage:
#   foundation = import ./foundation.nix { inherit lib; };
#   assert foundation.nixSystem.check "aarch64-darwin";
{ lib }:

let
  inherit (lib) types mkOption;
in rec {
  # ── Target Systems ────────────────────────────────────────────────
  # The four Nix systems substrate supports.
  nixSystem = types.enum [
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
  ];

  # Container/OCI architecture identifiers.
  architecture = types.enum [ "amd64" "arm64" ];

  # Rust cross-compilation targets (4-target matrix).
  rustTarget = types.enum [
    "aarch64-apple-darwin"
    "x86_64-apple-darwin"
    "x86_64-unknown-linux-musl"
    "aarch64-unknown-linux-musl"
  ];

  # Zig cross-compilation targets.
  zigTarget = types.enum [
    "aarch64-macos"
    "x86_64-macos"
    "x86_64-linux-musl"
    "aarch64-linux-musl"
  ];

  # ── Language & Artifact Taxonomy ──────────────────────────────────
  # Every builder function operates on exactly one language.
  language = types.enum [
    "rust"
    "go"
    "zig"
    "swift"
    "typescript"
    "ruby"
    "python"
    "dotnet"
    "java"
    "wasm"
    "web"
    "leptos"
    "nix"
  ];

  # What the builder produces.
  artifactKind = types.enum [
    "binary"
    "library"
    "service"
    "docker-image"
    "wasm-component"
    "wasi-service"
    "helm-chart"
    "npm-package"
    "gem"
    "scaffold"
    "overlay"
  ];

  # ── Service Protocol Types ────────────────────────────────────────
  serviceType = types.enum [ "graphql" "rest" "grpc" ];

  # ── Kubernetes Resource Kinds ─────────────────────────────────────
  # Every kind that appears in the kube/eval.nix dependency order.
  kubeResourceKind = types.enum [
    "Namespace"
    "CustomResourceDefinition"
    "PriorityClass"
    "StorageClass"
    "ClusterRole"
    "ClusterRoleBinding"
    "ServiceAccount"
    "Role"
    "RoleBinding"
    "ConfigMap"
    "Secret"
    "ExternalSecret"
    "PersistentVolume"
    "PersistentVolumeClaim"
    "LimitRange"
    "ResourceQuota"
    "NetworkPolicy"
    "Service"
    "DatabaseMigration"
    "Deployment"
    "StatefulSet"
    "DaemonSet"
    "CronJob"
    "Job"
    "HorizontalPodAutoscaler"
    "PodDisruptionBudget"
    "ScaledObject"
    "IngressClass"
    "Ingress"
    "VirtualService"
    "Gateway"
    "HTTPRoute"
    "GRPCRoute"
    "ServiceMonitor"
    "PodMonitor"
    "PrometheusRule"
    "PeerAuthentication"
    "DestinationRule"
    "MutatingWebhookConfiguration"
    "ValidatingWebhookConfiguration"
  ];

  # ── Workload Archetypes ───────────────────────────────────────────
  # Abstract workload intents from the Unified Infrastructure Theory.
  workloadArchetype = types.enum [
    "http-service"
    "worker"
    "cron-job"
    "gateway"
    "stateful-service"
    "function"
    "frontend"
  ];

  # ── Tatara Driver Types ───────────────────────────────────────────
  tataraDriver = types.enum [ "wasi" "nix" "oci" "exec" ];

  # ── Refined Primitives ────────────────────────────────────────────
  # A TCP/UDP port number (0-65535). Alias for types.port.
  port = types.port;

  # A non-empty string — rejects "" and whitespace-only.
  nonEmptyStr = types.nonEmptyStr;

  # Kubernetes resource quantity: CPU (e.g. "100m", "2") or memory (e.g. "128Mi", "4Gi").
  cpuQuantity = types.strMatching "[0-9]+m?";
  memoryQuantity = types.strMatching "[0-9]+(Mi|Gi|Ki|Ti)";

  # Docker image reference.
  imageRef = types.strMatching "[a-zA-Z0-9._/-]+(:[a-zA-Z0-9._-]+)?(@sha256:[a-f0-9]+)?";

  # Git repository reference (org/repo format).
  repoRef = types.strMatching "[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+";

  # Cron schedule (5-field or @keyword).
  cronSchedule = types.addCheck types.str (s:
    builtins.match "(@(annually|yearly|monthly|weekly|daily|hourly|reboot))|([0-9*,/-]+ [0-9*,/-]+ [0-9*,/-]+ [0-9*,/-]+ [0-9*,/-]+)" s != null
  );

  # Nix flake app entry — the standard { type = "app"; program = "..."; } shape.
  appEntry = types.submodule {
    options = {
      type = mkOption {
        type = types.enum [ "app" ];
        default = "app";
        description = "Must be 'app' per Nix flake convention.";
      };
      program = mkOption {
        type = types.str;
        description = "Absolute store path to the executable.";
      };
    };
  };

  # ── Network Protocol ──────────────────────────────────────────────
  networkProtocol = types.enum [ "TCP" "UDP" "SCTP" ];
}
