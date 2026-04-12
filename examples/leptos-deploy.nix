# Example: Deploy a Leptos PWA through substrate's unified infrastructure theory.
#
# This file demonstrates how a single declaration renders to Kubernetes,
# Tatara, and WASI simultaneously.
#
# Usage:
#   nix eval --json -f examples/leptos-deploy.nix
{ lib ? (import <nixpkgs> {}).lib }:

let
  archetypes = import ../lib/infra/workload-archetypes.nix;
  policies = import ../lib/infra/policies.nix;
  presets = import ../lib/infra/policy-presets/production.nix;

  # ============================================================================
  # DECLARE: A Leptos PWA as an HTTP service archetype
  # ============================================================================
  # The SSR binary serves CSR WASM + static assets on port 3000.
  # Health check at /healthz. Scaling 2-10 replicas.
  lilituWeb = archetypes.mkHttpService {
    name = "lilitu-web";

    # Container image (built by leptos-build-flake.nix)
    image = "ghcr.io/pleme-io/lilitu-web:latest";

    # Port configuration
    ports = [{
      name = "http";
      port = 3000;
      protocol = "http";
    }];

    # Health check -- Leptos SSR binary exposes /healthz
    health = {
      path = "/healthz";
      port = 3000;
      initialDelaySeconds = 5;
      periodSeconds = 10;
    };

    # Resource requests/limits
    resources = {
      cpu = "200m";
      memory = "256Mi";
    };

    # Autoscaling
    scaling = {
      min = 2;
      max = 10;
      targetCPU = 70;
    };

    # Environment variables
    env = {
      LEPTOS_SITE_ADDR = "0.0.0.0:3000";
      LEPTOS_SITE_ROOT = "/static";
      RUST_LOG = "info";
    };

    # Network egress (to Hanabi BFF)
    network = {
      egress = [{
        to = "hanabi";
        port = 8080;
      }];
    };

    # Metadata -- namespace lives here for K8s renderer
    meta = {
      namespace = "lilitu";
      team = "product";
      environment = "production";
    };

    # Labels for service mesh
    labels = {
      "app.pleme.io/product" = "lilitu";
      "app.pleme.io/component" = "web";
    };
  };

  # ============================================================================
  # GATE: Apply production policies (example)
  # ============================================================================
  # Production policies enforce: min 2 replicas, health checks, defined resources.
  #
  # The preset rules check:
  #   - min-replicas: scaling.min >= 2 (when env matches "production")
  #   - health-check-required: health != null (for http-service archetype)
  #   - resources-defined: resources != null (for all archetypes)
  #
  # To gate a deployment:
  #   policies.assertPolicies [ presets ] spec
  # This throws on violation, preventing the pipeline from proceeding.

in {
  # The archetype renders to all three backends simultaneously
  inherit (lilituWeb) spec;

  # Kubernetes manifests (via nix-kube)
  kubernetes = lilituWeb.kubernetes;

  # Tatara JobSpec (convergence engine)
  tatara = lilituWeb.tatara;

  # WASI component config -- note: wasmPath is null so this is a stub config.
  # When building with wasm32-wasip2 target, set wasmPath to enable full WASI rendering.
  wasi = lilituWeb.wasi;

  # Policy system (evaluate at pipeline time via assertPolicies)
  policyPreset = presets;

  # Human-readable summary
  summary = {
    name = lilituWeb.spec.name;
    archetype = lilituWeb.spec.archetype;
    ports = map (p: "${p.name}:${toString p.port}") lilituWeb.spec.ports;
    replicas = "${toString lilituWeb.spec.scaling.min}-${toString lilituWeb.spec.scaling.max}";
    health = "${lilituWeb.spec.health.path}:${toString lilituWeb.spec.health.port}";
  };
}
