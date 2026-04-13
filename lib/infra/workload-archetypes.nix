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

  # ── Built-in renderers (extensible via mkArchetypeWith) ───────
  builtinRenderers = {
    kubernetes = kubeRenderers;
    tatara = tataraRenderers;
    wasi = wasiRenderers;
  };

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
    # Bilateral promise bindings (Promise Theory — Burgess 2005)
    exports = [];   # [{ protocol = "http"; port = 8080; }]
    imports = [];   # [{ service = "db"; protocol = "pg"; port = 5432; }]
  };

  # ── Recursive lattice merge (CUE/lattice theory) ─────────────
  # Preserves nested defaults instead of flat // override.
  # { network = { egress = []; } } // { network = { policies = [...] } }
  # Flat: loses egress. Recursive: preserves both.
  recursiveMerge = a: b:
    let
      allKeys = builtins.attrNames (a // b);
    in builtins.listToAttrs (map (key:
      let
        aVal = a.${key} or null;
        bVal = b.${key} or null;
      in {
        name = key;
        value =
          if bVal == null then aVal
          else if aVal == null then bVal
          else if builtins.isAttrs aVal && builtins.isAttrs bVal
            then recursiveMerge aVal bVal
          else bVal;  # user value overrides default at leaf
      }
    ) allKeys);

  # ── Type assertions (eliminate undesired invariants at declaration time)
  assertNonEmpty = field: value:
    assert builtins.isString value && value != ""
      || throw "workload-archetypes: '${field}' must be a non-empty string, got: ${builtins.typeOf value}";
    value;

  assertPositiveInt = field: value:
    assert builtins.isInt value && value > 0
      || throw "workload-archetypes: '${field}' must be a positive integer, got: ${toString value}";
    value;

  assertResourceQuantity = field: value:
    assert builtins.isString value
      && builtins.match "[0-9]+(m|Mi|Gi|Ki|Ti)?" value != null
      || throw "workload-archetypes: '${field}' must be a resource quantity (e.g. '100m', '128Mi'), got: ${value}";
    value;

  assertList = field: value:
    assert builtins.isList value
      || throw "workload-archetypes: '${field}' must be a list, got: ${builtins.typeOf value}";
    value;

  assertAttrs = field: value:
    assert builtins.isAttrs value
      || throw "workload-archetypes: '${field}' must be an attrset, got: ${builtins.typeOf value}";
    value;

  # Validate resources subfields
  validateResources = res: let
    r = assertAttrs "resources" res;
  in {
    cpu = assertResourceQuantity "resources.cpu" (r.cpu or "100m");
    memory = assertResourceQuantity "resources.memory" (r.memory or "128Mi");
  };

  # Validate scaling subfields if present
  validateScaling = scaling:
    if scaling == null then null
    else let
      s = assertAttrs "scaling" scaling;
    in s // {
      min = if s ? min then assertPositiveInt "scaling.min" s.min
            else if scaling ? min then scaling.min else 1;
    };

  # ── Information flow enforcement (Denning 1976) ────────────────
  # Secrets must not leak into plain env. Non-interference check.
  assertNoSecretLeaks = env: secrets:
    let
      secretNames = map (s:
        if builtins.isAttrs s then (s.name or s.key or "") else toString s
      ) secrets;
      envKeys = builtins.attrNames env;
      leaked = builtins.filter (k: builtins.elem k secretNames) envKeys;
    in assert leaked == []
      || throw "Information flow violation: secret(s) [${builtins.concatStringsSep ", " leaked}] appear in plain env. Use the 'secrets' field for secret values, not 'env'.";
    true;

  # ── Intrinsic attestation (PCC — Necula 1996) ─────────────────
  # Compute attestation hash from the spec itself. The hash IS the
  # proof that the spec was well-typed at declaration time.
  mkSpecAttestation = spec: {
    enabled = true;
    signature = builtins.hashString "sha256" (builtins.toJSON {
      inherit (spec) name archetype ports resources replicas;
      secretCount = builtins.length spec.secrets;
      envKeys = builtins.sort builtins.lessThan (builtins.attrNames spec.env);
      hasHealth = spec.health != null;
      hasScaling = spec.scaling != null;
    });
    specVersion = "v1";
  };

  # Build the unified result: abstract spec + all renderings
  # Supports extensible renderers via mkArchetypeWith.
  mkArchetypeWith = renderers: archetype: userArgs: let
    # Recursive lattice merge preserves nested defaults
    args = recursiveMerge defaults (userArgs // { inherit archetype; });
    # Validate required fields (force all assertions via builtins.seq chain)
    _v1 = assertNonEmpty "name" (args.name or "");
    _v2 = builtins.seq _v1 (assertPositiveInt "replicas" args.replicas);
    _v3 = builtins.seq _v2 (assertList "secrets" args.secrets);
    _v4 = builtins.seq _v3 (assertAttrs "env" args.env);
    _v5 = builtins.seq _v4 (assertList "volumes" args.volumes);
    # Information flow: secrets must not leak into env
    _v6 = builtins.seq _v5 (assertNoSecretLeaks args.env args.secrets);
    validatedResources = builtins.seq _v6 (validateResources args.resources);
    validatedScaling = validateScaling args.scaling;
    spec = builtins.seq validatedResources {
      inherit (args) name archetype;
      ports = args.ports or [];
      health = args.health;
      scaling = validatedScaling;
      resources = validatedResources;
      replicas = args.replicas;
      secrets = args.secrets;
      network = args.network;
      env = args.env;
      volumes = args.volumes;
      meta = args.meta;
      annotations = args.annotations;
      labels = args.labels;
      # Bilateral promise bindings (Promise Theory)
      exports = args.exports or [];
      imports = args.imports or [];
      # Source detection hints (set by consumer flake)
      source = args.source or null;
      image = args.image or null;
      wasmPath = args.wasmPath or null;
      flakeRef = args.flakeRef or null;
      command = args.command or null;
      args' = args.args or [];
      schedule = args.schedule or null;
      serviceName = args.serviceName or args.name;
      # Intrinsic attestation — proof-carrying spec
      attestation = mkSpecAttestation spec;
    };
  in {
    inherit spec;
  } // builtins.mapAttrs (_: r: r.render spec) renderers;

  # Default mkArchetype uses built-in renderers
  mkArchetype = mkArchetypeWith builtinRenderers;

in rec {
  # ── Extensible Renderer Interface (Category Theory — Mokhov 2018) ─
  # New backends implement { render = spec: ...; } and pass to mkArchetypeWith.
  # Usage:
  #   composeRenderer = { render = spec: { ... }; };
  #   result = mkHttpServiceWith { compose = composeRenderer; } { name = "auth"; ... };
  mkHttpServiceWith = renderers: args: mkArchetypeWith (builtinRenderers // renderers) "http-service" args;
  mkWorkerWith = renderers: args: mkArchetypeWith (builtinRenderers // renderers) "worker" args;
  mkCronJobWith = renderers: args: mkArchetypeWith (builtinRenderers // renderers) "cron-job" (args // { replicas = args.replicas or 1; });
  mkGatewayWith = renderers: args: mkArchetypeWith (builtinRenderers // renderers) "gateway" args;
  mkStatefulServiceWith = renderers: args: mkArchetypeWith (builtinRenderers // renderers) "stateful-service" args;
  mkFunctionWith = renderers: args: mkArchetypeWith (builtinRenderers // renderers) "function" (args // { scaling = (args.scaling or {}) // { min = args.scaling.min or 0; }; });
  mkFrontendWith = renderers: args: mkArchetypeWith (builtinRenderers // renderers) "frontend" args;

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
    else builtins.throw "autoDriver: no suitable driver detected — flake must export wasi-component, default, or dockerImage in packages.${system}";
}
