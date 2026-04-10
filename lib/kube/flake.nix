# nix-kube flake entry point.
#
# Zero-boilerplate flake builder for Kubernetes resource definitions.
#
# Usage:
#   outputs = (import "${substrate}/lib/kube/flake.nix" {}) {
#     services = {
#       hanabi = { type = "microservice"; namespace = "nexus"; image = "..."; ... };
#       worker = { type = "worker"; namespace = "build"; image = "..."; ... };
#     };
#     clusters = {
#       plo = { modules = [ ./overlays/production.nix ]; };
#       zek = { modules = [ ./overlays/staging.nix ]; };
#     };
#   };
{ }: { services ? {}, clusters ? {}, infrastructure ? {} }:
let
  # Composition builders
  micro = import ./compositions/microservice.nix;
  worker = import ./compositions/worker.nix;
  operator = import ./compositions/operator.nix;
  web = import ./compositions/web.nix;
  cron = import ./compositions/cronjob.nix;
  db = import ./compositions/database.nix;
  cache = import ./compositions/cache.nix;
  nsGov = import ./compositions/namespace-gov.nix;
  bootstrap = import ./compositions/bootstrap.nix;

  eval = import ./eval.nix;
  modules = import ./modules/eval.nix;

  typeMap = {
    microservice = micro.mkMicroservice;
    worker = worker.mkWorker;
    operator = operator.mkOperator;
    web = web.mkWeb;
    cronjob = cron.mkCronjobService;
    database = db.mkDatabase;
    cache = cache.mkCache;
    namespace = nsGov.mkNamespaceGovernance;
    bootstrap = bootstrap.mkBootstrapJob;
  };

  # Build resources for a single service
  buildService = name: cfg:
    let
      type' = cfg.type or "microservice";
      builder = typeMap.${type'} or (throw "nix-kube: unknown service type '${type'}'");
      args = builtins.removeAttrs cfg [ "type" ];
    in builder (args // { inherit name; });

  # Build all clusters
  buildCluster = clusterName: clusterCfg:
    let
      # Apply modules to service definitions
      modResult = modules.evalKubeModules {
        inherit services;
        modules = clusterCfg.modules or [];
        globals = clusterCfg.globals or {};
      };

      builtServices = builtins.mapAttrs buildService modResult.services;
      builtInfra = builtins.mapAttrs buildService (infrastructure // (clusterCfg.infrastructure or {}));
    in eval.mkCluster {
      name = clusterName;
      services = builtServices;
      infrastructure = builtInfra;
    };

  allClusters = if clusters == {}
    then { default = buildCluster "default" {}; }
    else builtins.mapAttrs buildCluster clusters;

in {
  kubeResources.clusters = allClusters;

  # Per-service access for debugging
  kubeServices = builtins.mapAttrs buildService services;
}
