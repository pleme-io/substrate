# Unified Infrastructure Theory — Abstract Workload Archetypes
#
# Pure Nix functions that describe workload INTENT, not implementation.
# Each archetype returns an abstract spec + backend-specific renderings.
# The spec is the source of truth. Renderers translate to any target.
#
# No pkgs dependency — these are pure data transformations.
#
# Usage:
#   arch = import "${substrate}/lib/infra/workload-archetypes.nix";
#   result = arch.mkHttpService {
#     name = "auth";
#     source = self;
#     ports = [{ name = "http"; port = 8080; }];
#     health = { path = "/healthz"; };
#   };
#   # result.spec       — abstract intent
#   # result.kubernetes  — K8s manifests
#   # result.tatara      — tatara job spec
#   # result.wasi        — WASI component config
let
  kubeRenderers = import ./renderers/kubernetes.nix;
  tataraRenderers = import ./renderers/tatara.nix;
  wasiRenderers = import ./renderers/wasi.nix;

  # Common defaults applied to all archetypes
  defaults = {
    replicas = 1;
    resources = { cpu = "100m"; memory = "128Mi"; };
    health = null;
    scaling = null;
    secrets = [];
    network = { ingress = []; egress = []; policies = []; };
    env = {};
    volumes = [];
    meta = {};
    annotations = {};
    labels = {};
  };

  # Build the unified result: abstract spec + all renderings
  mkArchetype = archetype: userArgs: let
    args = defaults // userArgs // { inherit archetype; };
    spec = {
      inherit (args) name archetype;
      ports = args.ports or [];
      health = args.health;
      scaling = args.scaling;
      resources = args.resources;
      replicas = args.replicas;
      secrets = args.secrets;
      network = args.network;
      env = args.env;
      volumes = args.volumes;
      meta = args.meta;
      annotations = args.annotations;
      labels = args.labels;
      # Source detection hints (set by consumer flake)
      source = args.source or null;
      image = args.image or null;
      wasmPath = args.wasmPath or null;
      flakeRef = args.flakeRef or null;
      command = args.command or null;
      args' = args.args or [];
      schedule = args.schedule or null;
      serviceName = args.serviceName or args.name;
    };
  in {
    inherit spec;
    kubernetes = kubeRenderers.render spec;
    tatara = tataraRenderers.render spec;
    wasi = wasiRenderers.render spec;
  };

in rec {
  # ── HTTP Service ──────────────────────────────────────────────
  # Serves HTTP requests. Maps to: Deployment+Service (K8s), Service job (tatara),
  # wasi:http handler (WASI).
  mkHttpService = args: mkArchetype "http-service" args;

  # ── Worker ────────────────────────────────────────────────────
  # Background processor. Maps to: Deployment no Service (K8s), Service job (tatara),
  # wasi:messaging consumer (WASI).
  mkWorker = args: mkArchetype "worker" args;

  # ── Cron Job ──────────────────────────────────────────────────
  # Scheduled task. Maps to: CronJob (K8s), Batch job (tatara),
  # timed trigger (WASI).
  mkCronJob = args: mkArchetype "cron-job" (args // {
    replicas = args.replicas or 1;
  });

  # ── Gateway ───────────────────────────────────────────────────
  # Reverse proxy / load balancer. Maps to: Ingress+Service (K8s),
  # Hanabi config (tatara), wasi:http proxy (WASI).
  mkGateway = args: mkArchetype "gateway" args;

  # ── Stateful Service ──────────────────────────────────────────
  # Manages persistent state. Maps to: StatefulSet+PVC (K8s),
  # job with volumes (tatara). WASI not applicable (falls back to OCI).
  mkStatefulService = args: mkArchetype "stateful-service" args;

  # ── Function ──────────────────────────────────────────────────
  # Serverless / scale-to-zero. Maps to: KEDA+ScaledObject (K8s),
  # breathability (tatara), wasi:http sub-ms start (WASI).
  mkFunction = args: mkArchetype "function" (args // {
    scaling = (args.scaling or {}) // { min = args.scaling.min or 0; };
  });

  # ── Frontend ──────────────────────────────────────────────────
  # Browser application. Maps to: static serve (K8s/Hanabi),
  # Nix+Hanabi (tatara), wasm32-unknown-unknown (browser WASM).
  mkFrontend = args: mkArchetype "frontend" args;

  # ── Utility: detect available backends from flake outputs ─────
  detectBackends = flake: system: {
    wasi = flake ? packages.${system}.wasi-component;
    oci = flake ? packages.${system}.dockerImage;
    nix = flake ? packages.${system}.default;
    frontend = flake ? packages.${system}.web;
  };

  # ── Utility: auto-select driver from flake outputs ────────────
  autoDriver = flake: system:
    if flake ? packages.${system}.wasi-component then "wasi"
    else if flake ? packages.${system}.default then "nix"
    else if flake ? packages.${system}.dockerImage then "oci"
    else "exec";
}
