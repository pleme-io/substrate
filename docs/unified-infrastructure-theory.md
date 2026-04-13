# Unified Infrastructure Theory

## Abstract

The Unified Infrastructure Theory establishes Nix as the **universal language for describing any system**. Abstract workload archetypes declare intent without binding to any specific backend. Renderers translate intent to any target: Kubernetes, tatara, WASI, Docker Compose, or any future platform. One declaration produces output for all backends simultaneously.

This theory composes with the **Unified Convergence Computing Theory** (tatara) to form a complete platform: the infrastructure theory says WHAT; the convergence theory says HOW. Together: declare any system in Nix, compute it into existence through verified convergence on any substrate, prove every step cryptographically.

## 1. Core Principles

### 1.1 Nix as Universal System Description

Nix is a pure functional language with:
- **Reproducibility**: same input always produces same output
- **Compositionality**: small pieces combine without emergent complexity
- **Laziness**: evaluate only what's needed
- **Fixed-point**: recursive module system converges to coherent configuration

These properties make Nix the ideal language for declaring infrastructure intent — not because it's a good "template language" but because it's a **correct specification language**.

### 1.2 Abstract Workload Archetypes

An archetype is a pure function from intent to description:

```nix
mkHttpService { name = "auth"; source = self; ports = [...]; health = {...}; }
→ { spec, kubernetes, tatara, wasi, compose }
```

The `spec` is the abstract truth. The backend renderings are translations. New backends can be added without changing the spec.

Seven archetypes cover all workload patterns:

| Archetype | Abstract Meaning |
|-----------|-----------------|
| `mkHttpService` | Serves HTTP requests |
| `mkWorker` | Processes background work |
| `mkCronJob` | Runs on schedule |
| `mkGateway` | Routes traffic |
| `mkStatefulService` | Manages persistent state |
| `mkFunction` | Serverless / scale-to-zero |
| `mkFrontend` | Browser application |

### 1.3 Backend Renderers

Each renderer is a pure function that translates an abstract spec to backend-specific resources:

| Renderer | Output | Delegates To |
|----------|--------|-------------|
| `kubernetes.nix` | K8s manifests (JSON) | nix-kube compositions |
| `tatara.nix` | Tatara JobSpec (JSON) | tatara's normalizeJob |
| `wasi.nix` | WASI component config | wasmtime capabilities |
| `compose.nix` | docker-compose.yml | (planned) |

Adding a new backend requires only a new renderer file — no changes to archetypes or existing renderers.

### 1.4 Auto-Detection

The system detects available backends from flake outputs:
- `packages.<system>.wasi-component` → WASI driver
- `packages.<system>.default` → Nix driver
- `packages.<system>.dockerImage` → OCI driver
- If none found → error (not silent fallback)

### 1.5 Composition

Applications are multi-archetype compositions:

```nix
mkMultiTierApp {
  name = "lilitu";
  tiers = {
    api = mkHttpService { ... };
    db = mkStatefulService { ... };
    cache = mkStatefulService { ... };
  };
}
```

Auto-inferred:
- **Network policies**: egress rules derived from tier connections
- **Deployment ordering**: stateful → workers → services → gateways → frontends
- **Labels**: `app.pleme.io/part-of`, `tier`, `environment`

### 1.6 Policy

Governance at declaration time:

```nix
mkPolicy {
  name = "production-standards";
  rules = [
    { match = { archetype = "*"; env = "production"; };
      require = { "scaling.min" = 2; }; }
    { match = { archetype = "http-service"; };
      require = { "health" = "!null"; }; }
  ];
}
```

Policies evaluate at render time. Violations are errors, not warnings.

## 2. Composition with Convergence Computing Theory

When the infrastructure theory renders an archetype to a target, the convergence computing theory takes over:

1. Each rendered resource becomes a **convergence point** in a DAG
2. Each point has **atomic verified boundaries** (prepare → execute → verify → attest)
3. The DAG is traversed by distributed tatara nodes
4. The computation terminates when all points converge to distance = 0
5. Every step is cryptographically attested via tameshi BLAKE3

### Migration as Re-Rendering

Because archetypes are backend-independent:
- Migration = re-render(same archetypes, new target) + re-converge(same DAG, new substrate)
- K8s → tatara: same convergence DAG, different driver
- AWS → GCP: same convergence DAG, different Pangea rendering
- Docker → WASI: same convergence DAG, OCI driver → WASI driver

The convergence DAG IS the program. The substrate IS the hardware.

## 3. Implementation in Substrate

### Files

| File | Purpose |
|------|---------|
| `lib/infra/workload-archetypes.nix` | 7 abstract archetypes + auto-detection |
| `lib/infra/compositions.nix` | mkMultiTierApp, mkPipeline |
| `lib/infra/policies.nix` | mkPolicy, evaluateAll, assertPolicies |
| `lib/infra/policy-presets/` | production.nix, development.nix |
| `lib/infra/renderers/kubernetes.nix` | → nix-kube compositions |
| `lib/infra/renderers/tatara.nix` | → tatara JobSpec |
| `lib/infra/renderers/wasi.nix` | → WASI component config |
| `lib/kube/` | 31 K8s primitives, 9 compositions, eval, modules |

### Nix-Kube Library

31 pure K8s resource builders (no pkgs dependency):
- deployment, service, statefulset, daemonset, cronjob, job
- service-account, config-map, secret, namespace, rbac (4 types)
- network-policy (3-policy deny-all set), ingress
- service-monitor, pod-monitor, hpa, pdb, prometheus-rule
- scaled-object, peer-auth, destination-rule
- limit-range, resource-quota, priority-class
- shinka (migration CRD), delivery (NATS), breathability (KEDA)

9 compositions: mkMicroservice, mkWorker, mkOperator, mkWeb, mkCronjobService, mkDatabase, mkCache, mkNamespaceGovernance, mkBootstrapJob

### Formal Methods Properties (Implemented)

8 properties grounded in academic research are enforced in the archetype system:

1. **Information flow enforcement** (Denning 1976): `assertNoSecretLeaks` prevents secret names from appearing in plain `env` attrsets. Violations throw at Nix evaluation time.

2. **Bilateral promise bindings** (Burgess Promise Theory 2005): Archetypes declare `exports` (what protocols they serve) and `imports` (what they consume). `mkMultiTierApp` validates every import has a matching export.

3. **Intrinsic attestation** (Necula PCC 1996): `mkSpecAttestation` computes SHA-256 hash from the spec fields. The hash IS the proof that the spec was well-typed at declaration time. Renderers embed it in pod annotations (K8s), job metadata (tatara), and component config (WASI).

4. **Recursive lattice merge** (CUE lattice theory): `recursiveMerge` replaces flat `//` — overriding `network.policies` preserves `network.egress` from defaults instead of silently dropping it.

5. **Extensible renderer interface** (Mokhov categorical functors 2018): `mkArchetypeWith` accepts arbitrary renderers: `mkHttpServiceWith { compose = { render = ...; }; }`. New backends implement `{ render = spec: ...; }` without touching core archetype code.

6. **Monotonicity guard** (Knaster-Tarski theorem): `evalKubeModules` asserts that module fold cannot remove services — the precondition for convergence to a fixed point.

7. **Convergence stage typestate** (Brady dependent types 2021): `lib/types/convergence.nix` defines `declared` → `resolved` → `converged` → `verified`. Functions requiring a specific stage reject specs at the wrong stage.

8. **Property-based test generation** (ProTI/QuickCheck): Deterministic edge-case generators verify idempotence, determinism, name preservation, and resource preservation across all archetypes.

### Testing

- 362+ pure Nix eval tests across 9 suites
- Type system: 79 tests for every type, coercion path, enum validation
- Assertion library: 47 tests for every assertion function
- Convergence improvements: 26 integration tests covering all 8 formal properties
- Archetype rendering verified: same input → correct K8s + tatara + WASI output
- Policy evaluation verified: violations produce clear error messages
- Property tests: information flow (8), convergence stages (10)
