# Convergence Application Theory

How the pleme-io metaframework implements convergence computing from human
intent to running software across all platforms.

## The Fundamental Claim

**An application IS a convergence machine.** Every user interaction reduces
the distance between actual state and desired state. When distance = 0,
the user's intent is realized. The framework's job is to make this
convergence fast, correct, and provable.

## Manufacturing Intent into Computational Reality

```
Layer 0: Human Intent
  "I need a product for my users"
        ↓ declare (scaffold)

Layer 1: Nix Expression (substrate)
  scaffold.generate { name = "my-app"; features = ["auth" "pwa"]; }
        ↓ resolve (evaluation)

Layer 2: Source Code (pleme-app-core + pleme-mui + app features)
  Pure Rust state machines + typed components + domain logic
        ↓ converge (cargo build / nix build)

Layer 3: Artifacts
  Native binary + WASM bundle + Docker image
  Each is a content-addressed Nix store path (convergence proof)
        ↓ render (substrate archetype)

Layer 4: Deployment Specification
  mkHttpService → simultaneous K8s + Tatara + WASI specs
        ↓ deploy (FluxCD / tatara engine)

Layer 5: Running System
  Pod on K8s ∨ Tatara job ∨ WASI component ∨ native process
        ↓ verify (health checks + tameshi attestation)

Layer 6: Proven Convergence
  BLAKE3 Merkle tree: source hash → build hash → deploy hash → runtime hash
  The complete chain is a mathematical proof of convergence.
```

### Each Layer is a Convergence Point

| Layer | Distance Function | Convergence Mechanism |
|-------|------------------|----------------------|
| 0→1 | Information gap | Human → Nix declaration |
| 1→2 | Template completeness | Scaffold generates all files |
| 2→3 | Compilation errors | Cargo resolves deps, type-checks |
| 3→4 | Spec completeness | Archetype validates ports, health, resources |
| 4→5 | Deployment delta | FluxCD/tatara reconcile actual vs desired |
| 5→6 | Attestation coverage | tameshi signs each verified layer |

## The Application Runtime as Convergence

Inside the running application, every feature follows the convergence
pattern. The framework provides the convergence machinery:

### Authentication Convergence

```
Unauthenticated (distance = 1.0)
    ↓ hydrate from localStorage
    ↓ check grace period (15 min)
    ↓ verify with server
Authenticated (distance = 0.0)
```

Framework provides: `pleme_app_core::web::providers::auth::AuthProvider`
Convergence mechanism: session machine (hydrate → grace check → verify → authenticated)
Formal basis: Lyapunov stability (session validity is the Lyapunov function)

### Data Freshness Convergence

```
Stale (distance = staleness_ratio)
    ↓ check cache tier (REALTIME..REFERENCE)
    ↓ fetch if stale
    ↓ update cache
Fresh (distance = 0.0)
```

Framework provides: `pleme_app_core::web::query_cache::QueryCache`
Convergence mechanism: stale-while-revalidate with tiered cache times
Formal basis: Banach contraction (each fetch strictly reduces staleness)

### Auto-Save Convergence

```
Unsaved changes (distance = edit_count)
    ↓ debounce (coalesce rapid edits)
    ↓ save (reduce distance by batch)
    ↓ queue during save (no lost edits)
    ↓ retry with backoff on failure
Saved (distance = 0.0)
```

Framework provides: `pleme_app_core::machines::auto_save`
Convergence mechanism: debounce → save → queue → retry
Formal basis: Banach contraction with bounded retry (convergence rate = c^n)

### Offline Convergence (PWA)

```
Uncached (distance = uncached_resources / total_resources)
    ↓ service worker precaches app shell
    ↓ cache-first for images/fonts
    ↓ background sync for mutations
Fully cached (distance = 0.0)
```

Framework provides: `pleme_app_core::web::providers::pwa::PwaProvider`
Convergence mechanism: Workbox strategies (CacheFirst, NetworkFirst, BackgroundSync)
Formal basis: Monotone convergence (cached resources only grow, never shrink)

### Cross-Tab Convergence

```
Inconsistent (distance = tabs_out_of_sync / total_tabs)
    ↓ BroadcastChannel (fast path)
    ↓ StorageEvent (fallback)
    ↓ visibility change (safety net)
Consistent (distance = 0.0)
```

Framework provides: `pleme_app_core::web::sync::cross_tab`
Convergence mechanism: multi-mechanism sync with deduplication
Formal basis: CALM theorem (auth state sync is monotone → no coordination needed)

## The Deployment Stack as Convergence

### Kubernetes Path

```
Nix archetype (desired) ← pure function
    ↓ kubernetes.nix renderer
K8s manifests (8+ resources)
    ↓ git commit
FluxCD Kustomization
    ↓ continuous reconciliation
Running pods (actual)
    ↓ health probes
distance(desired, actual) → 0
```

FluxCD IS a convergence engine. It continuously measures the distance
between git state and cluster state, applying transformations until
distance = 0. The reconciliation loop is a discrete Lyapunov system.

### Tatara Path

```
Nix archetype (desired) ← pure function
    ↓ tatara.nix renderer
JobSpec JSON
    ↓ tatara submit
Convergence DAG
    ↓ 4-pass reconciler: health → liveness → count → spec-drift
    ↓ 7 drivers: exec | oci | nix | nix_build | kasou | kube | wasi
Running allocation (actual)
    ↓ ConvergenceDistance metric
distance(desired, actual) → 0
```

Tatara adds typed convergence semantics ON TOP of raw orchestration.
Each convergence point has a `ConvergenceDistance` that is monitored,
and a `ConvergenceBoundary` that ensures atomic prepare→execute→verify→attest.

### WASI Path

```
Nix archetype (desired)
    ↓ wasi.nix renderer
WASI component config
    ↓ wasmtime / Spin runtime
WASI component (sandboxed)
    ↓ capability-based security
    ↓ sub-millisecond cold start
Running (actual)
```

WASI adds: capability-based security (network/filesystem granted explicitly),
content-addressed identity (hash of .wasm = convergence proof), and
platform independence (same .wasm runs on any conformant runtime).

## The Dual Renderer as Abstract Interpretation

The metaframework's dual renderer (garasu GPU + pleme-mui web) is
formalized as abstract interpretation (Cousot & Cousot, 1977):

```
egaku widget state = abstract domain A
garasu rendering   = concretization γ₁: A → GPU pixels
pleme-mui rendering = concretization γ₂: A → DOM nodes

For any widget state s ∈ A:
  γ₁(s) and γ₂(s) are semantically equivalent
  (same visual output, different representation)
```

Properties proved at the egaku level (focus management, selection state,
scroll position) hold in BOTH renderers by construction. This is exactly
the Galois connection guarantee of abstract interpretation.

## The CALM Classification

Framework operations are classified by the CALM theorem:

### Monotone (coordination-free, can use gossip/CRDTs)

- Cache population (entries only added, never removed mid-operation)
- Feature flag evaluation (flags only become enabled)
- Notification history (notifications only appended)
- Cross-tab sync (state only grows — new token replaces null)
- PWA cache (resources only added)

### Non-Monotone (requires coordination/Raft)

- Auto-save conflict resolution (external update can override local)
- Auth logout (token deletion, cache purge)
- Session hygiene (state removal)
- Cache invalidation (entries removed)
- Payment state transitions (can fail/expire, not just progress)

This classification directly maps to Tatara's coordination model:
monotone points use gossip (eventually consistent), non-monotone
points use Raft (linearizable).

## Formal Grounding

| Claim | Theorem | Reference |
|-------|---------|-----------|
| Framework converges | Banach contraction mapping (1922) | Every operation strictly reduces distance |
| Module system terminates | Knaster-Tarski (1955) | Nix `lib.fix` computes least fixed point |
| Convergence is measurable | Lyapunov stability (1892) | Distance function is a Lyapunov function |
| Monotone ops need no coordination | CALM theorem (2020) | Hellerstein & Alvaro |
| Composition is coordination-free | Bloom^L (2012) | Conway et al. — lattice morphisms |
| Archetypes → renderers preserves properties | Abstract interpretation (1977) | Cousot — Galois connection |
| Content-addressed store is tamper-evident | Merkle trees (1979) | Hash chains preserve integrity |
| Store paths are convergence proofs | Dolstra PhD (2006) | Content-addressed functional deployment |
| Typed DAG edges ensure protocol correctness | Session types (1998) | Honda et al. |
| Global DAG compiles to deadlock-free endpoints | Choreographic programming (2013) | Montesi |
