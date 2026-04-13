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
    # ── Type assertions ─────────────────────────────────────────
    _ = assert builtins.isString name && name != ""
      || throw "mkMultiTierApp: 'name' must be a non-empty string"; true;
    __ = assert builtins.isAttrs tiers && tiers != {}
      || throw "mkMultiTierApp: 'tiers' must be a non-empty attrset"; true;
    ___ = assert builtins.elem environment [ "production" "staging" "development" ]
      || throw "mkMultiTierApp: 'environment' must be 'production', 'staging', or 'development', got: ${environment}"; true;
    ____ = assert builtins.isAttrs sharedLabels
      || throw "mkMultiTierApp: 'sharedLabels' must be an attrset"; true;
    _____ = assert builtins.isAttrs sharedAnnotations
      || throw "mkMultiTierApp: 'sharedAnnotations' must be an attrset"; true;
    ______ = assert builtins.isList policies
      || throw "mkMultiTierApp: 'policies' must be a list"; true;

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
      labels = {
        "app.pleme.io/part-of" = name;
        "app.pleme.io/tier" = tierName;
        "app.pleme.io/environment" = environment;
      } // sharedLabels // (tier.labels or {});  # user labels override system
      annotations = sharedAnnotations // (tier.annotations or {});  # user annotations override shared
      network = (tier.network or {}) // {
        egress = existingEgress ++ egressPolicies;
      };
    };

    enrichedTiers = builtins.mapAttrs enrichTier tiers;

    # ── Bilateral promise validation (Promise Theory — Burgess 2005) ──
    # Every import must be matched by an export from the referenced tier.
    # This catches wiring errors at Nix evaluation time, not deploy time.
    promiseViolations = builtins.concatMap (tierName:
      let
        tier = enrichedTiers.${tierName};
        tierImports = tier.imports or [];
      in builtins.concatMap (imp:
        let
          provider = imp.service or "";
          requiredProtocol = imp.protocol or "any";
          providerTier = enrichedTiers.${provider} or null;
          providerExports = if providerTier != null then (providerTier.exports or []) else [];
          hasMatch = requiredProtocol == "any"
            || builtins.any (exp: (exp.protocol or "any") == requiredProtocol) providerExports;
        in
          if provider == "" || !(builtins.hasAttr provider enrichedTiers) then []  # external dep, skip
          else if providerExports == [] then []  # provider has no exports declared, skip (backward compat)
          else if hasMatch then []
          else [{ tier = tierName; import' = imp; provider = provider; }]
      ) tierImports
    ) tierNames;

    # Valid archetype names
    validArchetypes = [ "http-service" "worker" "cron-job" "gateway" "stateful-service" "function" "frontend" ];

    # Render each tier through the archetype system
    renderedTiers = builtins.mapAttrs (tierName: tier:
      let
        archetype = tier.archetype or "http-service";
        _archetypeCheck = assert builtins.elem archetype validArchetypes
          || throw "mkMultiTierApp: tier '${tierName}' has invalid archetype '${archetype}'. Valid: ${builtins.concatStringsSep ", " validArchetypes}";
          true;
        builder = {
          "http-service" = archetypes.mkHttpService;
          "worker" = archetypes.mkWorker;
          "cron-job" = archetypes.mkCronJob;
          "gateway" = archetypes.mkGateway;
          "stateful-service" = archetypes.mkStatefulService;
          "function" = archetypes.mkFunction;
          "frontend" = archetypes.mkFrontend;
        }.${archetype};
      in builder (builtins.removeAttrs tier [ "archetype" ])
    ) enrichedTiers;

    # Force promise validation (lazy eval requires explicit seq)
    _promiseCheck =
      if promiseViolations == [] then true
      else throw "Promise binding violations in '${name}':\n${builtins.concatStringsSep "\n" (map (v:
        "  ${v.tier} imports '${v.import'.protocol or "?"}' from ${v.provider}, but ${v.provider} does not export it"
      ) promiseViolations)}";

  in builtins.seq _promiseCheck {
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
