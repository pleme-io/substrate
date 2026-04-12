# Example: Generate Helm values for a Leptos PWA deployment.
#
# Integrates with the substrate Helm chart SDLC (lib/service/helm-build.nix).
#
# Usage:
#   nix eval --json -f examples/leptos-helm-values.nix
#   nix eval --json --expr '(import ./examples/leptos-helm-values.nix {}).mkLeptosHelmValues { name = "lilitu-web"; image = "ghcr.io/pleme-io/lilitu-web"; }'
{ lib ? (import <nixpkgs> {}).lib }:

{
  # Standard Helm values for a Leptos SSR service
  mkLeptosHelmValues = {
    name,
    image,
    tag ? "latest",
    replicas ? 2,
    port ? 3000,
    healthPort ? 3000,
    healthPath ? "/healthz",
    resources ? {
      requests = { cpu = "200m"; memory = "256Mi"; };
      limits = { cpu = "1000m"; memory = "512Mi"; };
    },
    env ? {},
    # Ingress
    host ? null,
    tlsSecretName ? null,
    # Monitoring
    metricsPort ? null,
    metricsPath ? "/metrics",
  }: {
    replicaCount = replicas;

    image = {
      repository = image;
      inherit tag;
      pullPolicy = "IfNotPresent";
    };

    service = {
      type = "ClusterIP";
      inherit port;
    };

    livenessProbe = {
      httpGet = {
        path = healthPath;
        port = healthPort;
      };
      initialDelaySeconds = 5;
      periodSeconds = 10;
      failureThreshold = 3;
    };

    readinessProbe = {
      httpGet = {
        path = healthPath;
        port = healthPort;
      };
      initialDelaySeconds = 3;
      periodSeconds = 5;
    };

    inherit resources;

    env = lib.mapAttrsToList (k: v: { name = k; value = v; }) ({
      LEPTOS_SITE_ADDR = "0.0.0.0:${toString port}";
      LEPTOS_SITE_ROOT = "/static";
      RUST_LOG = "info";
    } // env);

    autoscaling = {
      enabled = true;
      minReplicas = replicas;
      maxReplicas = replicas * 5;
      targetCPUUtilizationPercentage = 70;
    };

    podDisruptionBudget = {
      enabled = true;
      minAvailable = 1;
    };

    serviceMonitor = lib.optionalAttrs (metricsPort != null) {
      enabled = true;
      port = metricsPort;
      path = metricsPath;
    };

    ingress = lib.optionalAttrs (host != null) {
      enabled = true;
      className = "nginx";
      hosts = [{
        inherit host;
        paths = [{ path = "/"; pathType = "Prefix"; }];
      }];
      tls = lib.optional (tlsSecretName != null) {
        secretName = tlsSecretName;
        hosts = [ host ];
      };
    };

    networkPolicy = {
      enabled = true;
      # Allow ingress from nginx-ingress-controller
      ingress = [{
        from = [{
          namespaceSelector = {
            matchLabels = {
              "kubernetes.io/metadata.name" = "ingress-nginx";
            };
          };
        }];
        ports = [{ port = port; protocol = "TCP"; }];
      }];
      # Allow egress to Hanabi BFF
      egress = [{
        to = [{
          podSelector = {
            matchLabels = {
              "app.kubernetes.io/name" = "hanabi";
            };
          };
        }];
        ports = [{ port = 8080; protocol = "TCP"; }];
      }];
    };
  };
}
