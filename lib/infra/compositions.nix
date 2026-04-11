# Unified Infrastructure Theory — Composition Layer
#
# Cross-archetype wiring: combine multiple archetypes into a coherent
# multi-tier application with auto-inferred network policies and
# deployment ordering.
#
# A real application is NOT a single archetype — it's a graph:
#   frontend → gateway → api → database + cache
#
# This layer composes archetypes into that graph.
#
# Pure functions — no pkgs dependency.
let
  archetypes = import ./workload-archetypes.nix;
in rec {
  # ── Multi-Tier Application ────────────────────────────────────
  #
  # Composes multiple archetypes into a single application with:
  # - Auto-inferred network policies (egress from connection graph)
  # - Deployment ordering (stateful → stateless → frontends)
  # - Unified rendering to all backends
  #
  mkMultiTierApp = {
    name,
    tiers,
    # Explicit connections (if not auto-inferred from tier names)
    connections ? {},
    # Shared labels/annotations applied to all tiers
    sharedLabels ? {},
    sharedAnnotations ? {},
    # Global policy overrides
    policies ? [],
    # Environment (production, staging, development)
    environment ? "development",
  }: let
    tierNames = builtins.attrNames tiers;

    # Auto-infer connections from tier specs
    # If a tier's egress mentions another tier name, it's a connection
    inferConnections = builtins.foldl' (acc: tierName:
      let
        tier = tiers.${tierName};
        egress = (tier.network or {}).egress or [];
        egressServices = map (e: e.service or "") egress;
        # Filter to only connections that reference other tiers
        tierConnections = builtins.filter (s: builtins.elem s tierNames) egressServices;
      in acc // { ${tierName} = tierConnections; }
    ) {} tierNames;

    allConnections = connections // inferConnections;

    # Compute deployment order (stateful first, frontends last)
    tierPriority = tier:
      if (tier.archetype or "http-service") == "stateful-service" then 0
      else if (tier.archetype or "") == "worker" then 1
      else if (tier.archetype or "") == "http-service" then 2
      else if (tier.archetype or "") == "gateway" then 3
      else if (tier.archetype or "") == "frontend" then 4
      else 2;

    orderedTierNames = builtins.sort
      (a: b: tierPriority tiers.${a} < tierPriority tiers.${b})
      tierNames;

    # Enrich each tier with auto-inferred network policies
    enrichTier = tierName: tier: let
      deps = allConnections.${tierName} or [];
      egressPolicies = map (dep: { service = dep; }) deps;
      existingEgress = (tier.network or {}).egress or [];
    in tier // {
      serviceName = tier.serviceName or tierName;
      labels = (tier.labels or {}) // sharedLabels // {
        "app.pleme.io/part-of" = name;
        "app.pleme.io/tier" = tierName;
        "app.pleme.io/environment" = environment;
      };
      annotations = (tier.annotations or {}) // sharedAnnotations;
      network = (tier.network or {}) // {
        egress = existingEgress ++ egressPolicies;
      };
    };

    enrichedTiers = builtins.mapAttrs enrichTier tiers;

    # Render each tier through the archetype system
    renderedTiers = builtins.mapAttrs (tierName: tier:
      let
        archetype = tier.archetype or "http-service";
        builder = {
          "http-service" = archetypes.mkHttpService;
          "worker" = archetypes.mkWorker;
          "cron-job" = archetypes.mkCronJob;
          "gateway" = archetypes.mkGateway;
          "stateful-service" = archetypes.mkStatefulService;
          "function" = archetypes.mkFunction;
          "frontend" = archetypes.mkFrontend;
        }.${archetype} or archetypes.mkHttpService;
      in builder (builtins.removeAttrs tier [ "archetype" ])
    ) enrichedTiers;

  in {
    inherit name environment;
    tiers = renderedTiers;
    deploymentOrder = orderedTierNames;
    connections = allConnections;

    # Aggregate all K8s resources across tiers (in deployment order)
    kubernetes = builtins.concatMap
      (tierName: renderedTiers.${tierName}.kubernetes)
      orderedTierNames;

    # Aggregate all tatara jobs
    tatara = builtins.listToAttrs (map (tierName: {
      name = tierName;
      value = renderedTiers.${tierName}.tatara;
    }) tierNames);

    # Aggregate all WASI configs
    wasi = builtins.listToAttrs (builtins.filter (x: x.value.wasm_path != null) (map (tierName: {
      name = tierName;
      value = renderedTiers.${tierName}.wasi;
    }) tierNames));
  };

  # ── Pipeline ──────────────────────────────────────────────────
  #
  # A sequential pipeline of jobs (build → test → deploy).
  #
  mkPipeline = {
    name,
    stages,
    # Each stage is { name, archetype, ... }
    # Stages execute in order. Each stage depends on the previous.
  }: let
    stageNames = map (s: s.name) stages;
    stageSpecs = builtins.listToAttrs (map (s: {
      name = s.name;
      value = s;
    }) stages);
  in {
    inherit name;
    inherit stageNames;
    stages = stageSpecs;
    # Pipeline produces a tatara DAG (each stage depends on previous)
    tataraDag = builtins.foldl' (acc: i:
      let
        stage = builtins.elemAt stages i;
        prev = if i == 0 then [] else [ (builtins.elemAt stages (i - 1)).name ];
      in acc // {
        ${stage.name} = {
          dependencies = prev;
          job = (archetypes.mkCronJob (stage // { schedule = stage.schedule or ""; })).tatara;
        };
      }
    ) {} (builtins.genList (i: i) (builtins.length stages));
  };
}
