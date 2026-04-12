# ============================================================================
# CONVERGENCE BRIDGE — How Leptos PWA fits in the convergence DAG
# ============================================================================
# The frontend is not separate from the convergence system. It IS a
# convergence point: the UI converges toward the user's desired state
# through reactive state management, just as infrastructure converges
# through tatara.
#
# This example shows the full convergence chain from user intent to
# running system. Each layer is an independent convergence process
# that composes with its neighbors through verified checkpoints.
#
# Run:
#   nix eval --impure --expr '(import ./examples/convergence-bridge.nix {}).convergence_map'
#   nix eval --json --impure --expr '(import ./examples/convergence-bridge.nix {}).tatara_specs'
{ lib ? (import <nixpkgs> {}).lib }:

let
  archetypes = import ../lib/infra/workload-archetypes.nix;

  # ========================================================================
  # Layer 1: Frontend Convergence (Leptos PWA)
  # ========================================================================
  # The UI is a convergence point. User sees current state, declares desired
  # state (form input), the app converges toward it (validate -> save -> confirm).
  #
  # Convergence points in the frontend:
  # - AuthSession: hydrate -> verify -> authenticate (distance: token validity)
  # - AutoSave: idle -> debounce -> save -> confirm (distance: unsaved changes)
  # - QueryCache: stale -> fetch -> fresh (distance: data freshness)
  # - PWA: online -> cache -> offline-capable (distance: cached resources)
  # - WebSocket: disconnected -> connecting -> subscribed (distance: subscription completeness)
  #
  # Each point is instrumented via convergence_tracing.rs with
  # OpenTelemetry-compatible attributes.
  frontend = archetypes.mkHttpService {
    name = "lilitu-web";
    image = "ghcr.io/pleme-io/lilitu-web:latest";
    ports = [{ name = "http"; port = 3000; protocol = "http"; }];
    health = { path = "/healthz"; port = 3000; };
    resources = { cpu = "200m"; memory = "256Mi"; };
    scaling = { min = 2; max = 10; };
    env = {
      LEPTOS_SITE_ADDR = "0.0.0.0:3000";
      RUST_LOG = "info";
    };
    labels = {
      "convergence.pleme.io/layer" = "frontend";
      "convergence.pleme.io/type" = "http-service";
    };
  };

  # ========================================================================
  # Layer 2: BFF Convergence (Hanabi)
  # ========================================================================
  # GraphQL federation gateway. Converges API requests to backend services.
  # The BFF is a convergence relay: it does not hold state, but translates
  # frontend convergence requests into backend convergence operations.
  bff = archetypes.mkHttpService {
    name = "hanabi";
    image = "ghcr.io/pleme-io/hanabi:latest";
    ports = [
      { name = "http"; port = 8080; protocol = "http"; }
      { name = "health"; port = 8081; protocol = "http"; }
    ];
    health = { path = "/health"; port = 8081; };
    resources = { cpu = "500m"; memory = "512Mi"; };
    scaling = { min = 2; max = 20; };
    network = { egress = [{ to = "lilitu-api"; port = 8080; }]; };
    labels = {
      "convergence.pleme.io/layer" = "bff";
      "convergence.pleme.io/type" = "gateway";
    };
  };

  # ========================================================================
  # Layer 3: Backend Convergence (API)
  # ========================================================================
  # Business logic service. Converges domain state via database mutations.
  # Each API call is a convergence step: the domain moves closer to the
  # user's declared desired state.
  api = archetypes.mkHttpService {
    name = "lilitu-api";
    image = "ghcr.io/pleme-io/lilitu-api:latest";
    ports = [{ name = "grpc"; port = 8080; protocol = "http"; }];
    health = { path = "/health"; port = 8080; };
    resources = { cpu = "500m"; memory = "512Mi"; };
    scaling = { min = 2; max = 20; };
    labels = {
      "convergence.pleme.io/layer" = "backend";
      "convergence.pleme.io/type" = "api";
    };
  };

  # ========================================================================
  # Layer 4: Data Convergence (Database)
  # ========================================================================
  # PostgreSQL. The ultimate convergence target — data at rest is distance=0.
  # WAL, replication, and vacuum are all convergence processes that maintain
  # the invariant: committed data is durable and consistent.
  database = archetypes.mkStatefulService {
    name = "lilitu-db";
    image = "postgres:16";
    ports = [{ name = "pg"; port = 5432; protocol = "tcp"; }];
    health = { path = "/healthz"; port = 5432; };
    resources = { cpu = "1000m"; memory = "2048Mi"; };
    storage = { size = "100Gi"; class = "gp3"; };
    labels = {
      "convergence.pleme.io/layer" = "data";
      "convergence.pleme.io/type" = "stateful";
    };
  };

in {
  # The full convergence stack — each layer independently verified
  layers = {
    inherit frontend bff api database;
  };

  # Each layer's convergence metadata.
  # Maps convergence points to their distance functions.
  # Distance functions return 0.0 when converged, >0 when drifting.
  convergence_map = {
    frontend = {
      points = [
        "auth-session"
        "auto-save"
        "query-cache"
        "pwa-cache"
        "ws-connection"
      ];
      distance_functions = {
        auth = "token_expiry_distance";
        data = "staleness_ratio";
        pwa = "uncached_resources_ratio";
      };
      # Tracing attributes emitted by convergence_tracing.rs
      trace_attributes = [
        "convergence.point"
        "convergence.phase"
        "convergence.distance"
        "machine.name"
        "machine.from"
        "machine.to"
        "cache.operation"
        "graphql.type"
        "graphql.name"
        "pwa.event"
        "ws.event"
      ];
    };
    bff = {
      points = [
        "graphql-federation"
        "session-validation"
        "rate-limiting"
      ];
      distance_functions = {
        federation = "subgraph_health_ratio";
        session = "validation_freshness";
      };
    };
    api = {
      points = [
        "domain-mutation"
        "event-emission"
        "cache-invalidation"
      ];
      distance_functions = {
        mutation = "transaction_completion";
        events = "event_delivery_ratio";
      };
    };
    database = {
      points = [
        "write-ahead-log"
        "replication"
        "vacuum"
      ];
      distance_functions = {
        replication = "replica_lag_seconds";
        wal = "wal_size_bytes";
      };
    };
  };

  # Tatara JobSpec for the full stack.
  # Each spec is independently deployable via tatara's convergence DAG.
  tatara_specs = builtins.mapAttrs (_: svc: svc.tatara) {
    inherit frontend bff api database;
  };

  # Kubernetes manifests for the full stack.
  # Each layer renders to an ordered list of K8s resources.
  kubernetes_manifests = builtins.mapAttrs (_: svc: svc.kubernetes) {
    inherit frontend bff api database;
  };

  # WASI configs for the full stack.
  wasi_configs = builtins.mapAttrs (_: svc: svc.wasi) {
    inherit frontend bff api database;
  };
}
