# Complete multi-system flake outputs for a WASI service deployable via FluxCD.
#
# Layers:
#   1. wasi-service-flake.nix  → wasm + Docker image + wasmtime apps
#   2. wasi-service-flux-flake (this file) → adds:
#        - Helm values rendering (vanilla bjw-s/app-template OR lareira-fleet-programs entry)
#        - HelmRelease + kustomization rendering
#        - `nix run .#render-deploy` app to dump artifacts into pleme-io/k8s
#        - `nix run .#deploy-<cluster>` app to commit + push them
#
# Per the Compounding Directive: this primitive lets a tatara-lisp service
# (or any wasi crate) declare ONE typed `deploy = { cluster, namespace, ... }`
# block and produce every artifact FluxCD needs to schedule it on the target
# cluster — no hand-written HelmRelease YAML, no per-service kustomize plumbing.
#
# Two modes:
#   mode = "standalone"  (default) — emits a self-contained HelmRelease using
#                                    bjw-s/app-template (works today, no
#                                    operator/engine prerequisites).
#   mode = "lareira"               — emits a `programs:` entry contribution
#                                    to lareira-fleet-programs (Phase B; requires
#                                    wasm-operator + wasm-engine deployed).
#
# Usage in a flake:
#
#   outputs = { self, nixpkgs, fenix, substrate, ... }:
#     (import "${substrate}/lib/wasi-service-flux-flake.nix" {
#       inherit nixpkgs substrate fenix;
#     }) {
#       inherit self;
#       serviceName = "hello-rio";
#       wasiCapabilities = [ "network" "env" ];
#       module = {
#         description = "Hello-rio WASI HTTP service";
#       };
#       deploy = {
#         cluster = "rio";
#         namespace = "tatara-system";
#         imageRepo = "ghcr.io/pleme-io";
#         imageTag = "latest";
#         port = 8080;
#         healthPath = "/healthz";
#         ingress = {
#           enabled = true;
#           host = "hello.quero.cloud";
#         };
#         k8sRepoPath = "/Users/drzzln/code/github/pleme-io/k8s";
#         mode = "standalone";   # or "lareira"
#       };
#     };
#
# Produces (in addition to wasi-service-flake outputs):
#   - packages.<sys>.helmRelease     — rendered HelmRelease YAML (single file)
#   - packages.<sys>.kustomization   — rendered kustomization.yaml
#   - packages.<sys>.deployBundle    — directory derivation with both files
#   - apps.<sys>.render-deploy       — write the bundle to <k8sRepoPath>/clusters/<cluster>/services/<name>/
#   - apps.<sys>.deploy-<cluster>    — render + git add + git commit + git push (still requires GHCR image push out-of-band)
{
  nixpkgs,
  substrate,
  fenix,
}:
{
  self,
  serviceName,
  systems ? [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ],
  module ? null,
  deploy ? null,
  # All remaining args forwarded to wasi-service-flake.nix
  ...
} @ args:
let
  upstreamArgs = builtins.removeAttrs args [ "deploy" ];
  upstream =
    (import ./wasi-service-flake.nix { inherit nixpkgs substrate fenix; }) upstreamArgs;
  pkgsLib = (import nixpkgs { system = "x86_64-linux"; }).lib;

  # ── Default deploy block ─────────────────────────────────────────────
  d = if deploy == null then null else {
    cluster      = deploy.cluster      or (throw "wasi-service-flux: deploy.cluster is required");
    namespace    = deploy.namespace    or "tatara-system";
    imageRepo    = deploy.imageRepo    or "ghcr.io/pleme-io";
    imageTag     = deploy.imageTag     or "latest";
    port         = deploy.port         or 8080;
    healthPath   = deploy.healthPath   or "/healthz";
    ingress      = deploy.ingress      or { enabled = false; };
    resources    = deploy.resources    or {
      requests = { cpu = "50m";  memory = "64Mi"; };
      limits   = { cpu = "500m"; memory = "256Mi"; };
    };
    capabilities = deploy.capabilities or (args.wasiCapabilities or [ "http-in:0.0.0.0:${toString (deploy.port or 8080)}" ]);
    config       = deploy.config       or {};
    k8sRepoPath  = deploy.k8sRepoPath  or "/Users/drzzln/code/github/pleme-io/k8s";
    mode         = deploy.mode         or "standalone";
    chartVersion = deploy.chartVersion or "3.x";
    breathability = deploy.breathability or {
      enabled = true;
      minReplicas = 0;
      maxReplicas = 5;
      cooldownPeriod = 600;
    };
  };

  # ── Helm values renderer (standalone mode, bjw-s/app-template) ──────
  mkAppTemplateValues = pkgs:
    let yamlFormat = pkgs.formats.yaml {}; in
    yamlFormat.generate "${serviceName}-values.yaml" {
      controllers.${serviceName} = {
        type = "deployment";
        replicas = 1;
        containers.main = {
          image = {
            repository = "${d.imageRepo}/${serviceName}";
            tag = d.imageTag;
            pullPolicy = "IfNotPresent";
          };
          env = d.config;
          probes = {
            liveness = {
              enabled = true;
              custom = true;
              spec = {
                httpGet = { path = d.healthPath; port = d.port; };
                initialDelaySeconds = 5;
                periodSeconds = 10;
              };
            };
            readiness = {
              enabled = true;
              custom = true;
              spec = {
                httpGet = { path = d.healthPath; port = d.port; };
                initialDelaySeconds = 2;
                periodSeconds = 5;
              };
            };
          };
          inherit (d) resources;
        };
      };
      service.${serviceName} = {
        controller = serviceName;
        ports.http = { port = d.port; };
      };
    } // pkgsLib.optionalAttrs d.ingress.enable or false {
      ingress.${serviceName} = {
        enabled = true;
        className = d.ingress.className or "nginx";
        hosts = [ {
          host = d.ingress.host;
          paths = [ {
            path = d.ingress.path or "/";
            pathType = "Prefix";
            service = {
              identifier = serviceName;
              port = "http";
            };
          } ];
        } ];
      };
    };

  # ── HelmRelease renderer ─────────────────────────────────────────────
  mkHelmReleaseStandalone = pkgs:
    let yamlFormat = pkgs.formats.yaml {}; in
    yamlFormat.generate "${serviceName}-release.yaml" {
      apiVersion = "helm.toolkit.fluxcd.io/v2";
      kind = "HelmRelease";
      metadata = {
        name = serviceName;
        namespace = d.namespace;
      };
      spec = {
        interval = "10m";
        chart.spec = {
          chart = "app-template";
          version = d.chartVersion;
          sourceRef = {
            kind = "HelmRepository";
            name = "bjw-s";
            namespace = "flux-system";
          };
        };
        install.remediation.retries = 3;
        upgrade.remediation.retries = 3;
        valuesFrom = [];
        # Inline values; consumers may override with valuesFrom in
        # an overlay if they need cluster-specific tweaks.
        values = (pkgsLib.importJSON (mkAppTemplateValues pkgs));
      };
    };

  # ── lareira-fleet-programs entry contribution (Phase B mode) ────────
  # When `mode = "lareira"`, emit a single `programs:` entry that the
  # cluster-level lareira-fleet-programs HelmRelease aggregates. Output
  # path is `clusters/<cluster>/programs/contributions/<name>.yaml` —
  # the parent release.yaml uses kustomize `patches:` to merge them.
  mkLareiraEntry = pkgs:
    let yamlFormat = pkgs.formats.yaml {}; in
    yamlFormat.generate "${serviceName}-program.yaml" {
      name = serviceName;
      module.source = "github:${args.repo or "pleme-io/${serviceName}"}/main.tlisp?ref=${d.imageTag}";
      trigger.service = {
        port = d.port;
        paths = deploy.paths or [ "/" ];
        hosts = (
          if d.ingress.enabled or false
          then [ d.ingress.host ]
          else [ "${serviceName}.${d.namespace}.svc.cluster.local" ]
        );
        breathability = d.breathability;
      };
      capabilities = d.capabilities;
      config = d.config;
    };

  # ── Kustomization renderer ─────────────────────────────────────────
  mkKustomization = pkgs:
    let yamlFormat = pkgs.formats.yaml {}; in
    yamlFormat.generate "kustomization.yaml" {
      apiVersion = "kustomize.config.k8s.io/v1beta1";
      kind = "Kustomization";
      resources = if d.mode == "standalone" then [ "release.yaml" ]
                  else [ "program.yaml" ];
    };

  # ── Deploy bundle derivation ─────────────────────────────────────────
  mkDeployBundle = pkgs:
    let
      release = if d.mode == "standalone"
                then mkHelmReleaseStandalone pkgs
                else mkLareiraEntry pkgs;
      kustom = mkKustomization pkgs;
      releaseFilename = if d.mode == "standalone" then "release.yaml" else "program.yaml";
    in pkgs.runCommand "${serviceName}-deploy-bundle" {} ''
      mkdir -p $out
      cp ${release} $out/${releaseFilename}
      cp ${kustom}  $out/kustomization.yaml
    '';

  # ── Per-system layered outputs ──────────────────────────────────────
  mkPerSystem = system:
    let
      pkgs = import nixpkgs { inherit system; };
      base = upstream.packages.${system} or {};
      apps = upstream.apps.${system} or {};
      devs = upstream.devShells.${system} or {};
      bundle = if d == null then null else mkDeployBundle pkgs;

      renderDeployScript = pkgs.writeShellScript "render-deploy-${serviceName}" ''
        set -euo pipefail
        DEST="${d.k8sRepoPath}/clusters/${d.cluster}/services/${serviceName}"
        echo "rendering deploy bundle to $DEST"
        mkdir -p "$DEST"
        ${pkgs.coreutils}/bin/cp -r ${bundle}/. "$DEST/"
        echo "wrote: $DEST/"
        ls -la "$DEST"
      '';

      deployScript = pkgs.writeShellScript "deploy-${d.cluster or "x"}-${serviceName}" ''
        set -euo pipefail
        K8S=${d.k8sRepoPath}
        ${renderDeployScript}
        cd "$K8S"
        ${pkgs.git}/bin/git add clusters/${d.cluster}/services/${serviceName}/
        ${pkgs.git}/bin/git -c commit.gpgsign=false commit -m "${d.cluster}: deploy ${serviceName} (${d.imageTag})" || true
        ${pkgs.git}/bin/git push origin main || \
          echo "push failed; resolve auth and re-push manually"
      '';

      deployApps = if d == null then {} else {
        render-deploy = {
          type = "app";
          program = toString renderDeployScript;
        };
        "deploy-${d.cluster}" = {
          type = "app";
          program = toString deployScript;
        };
      };
    in {
      packages = base // pkgsLib.optionalAttrs (d != null) {
        inherit bundle;
      };
      apps = apps // deployApps;
      devShells = devs;
    };

  flakeWrapper = import ../../util/flake-wrapper.nix { inherit nixpkgs; };

  # Reuse upstream's overlay + module-trio outputs verbatim.
  upstreamExtras = builtins.removeAttrs upstream [ "packages" "apps" "devShells" ];
in
  flakeWrapper.mkFlakeOutputs {
    inherit systems mkPerSystem;
    extraOutputs = upstreamExtras;
  }
