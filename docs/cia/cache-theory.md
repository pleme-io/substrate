# Nix Cache Optimization Theory

## Version 1.0 — Companion to CIA Theory v1.0

---

## 1. Scope

This document formalizes the caching model for Nix-built artifacts across
the pleme-io organization (~387 flakes). It defines the axioms that govern
when Nix rebuilds, the invariants pleme-io enforces to maximize cache hits,
the metrics used to measure cache health, and a convergence proof showing
that automated enforcement drives violations to zero.

**Relationship to CIA Theory:**
CIA theory.md (Section 2) defines the Build domain as "Nix → reproducible
artifacts." This document specifies the *efficiency* dimension of that
domain — not *what* Nix builds, but *when* it rebuilds and why.

**Enforcement chain:**
```
Axiom → Invariant → nix-audit checker → flake-hygiene.nix primitive
```

Every invariant traces back to an axiom (the physics of Nix caching) and
forward to a mechanistic enforcement (the tool that checks/prevents violations).

---

## 2. Axioms

These are properties of the Nix store model. They are not pleme-io choices —
they are facts about how Nix works. Understanding them is prerequisite to
optimizing for cache hits.

### Axiom C1: Intensional Store Model

A derivation's store path hash is computed from:

```
hash(builder, args, env, inputDrvs, inputSrcs, system)
```

Any change in any transitive input — even a single byte in a dependency's
source — produces a new hash, which forces a rebuild of the derivation and
everything downstream. This is the **cascade property**: a single upstream
change propagates through the entire dependency graph.

**Consequence:** If repo A and repo B use different nixpkgs revisions, they
share zero cached derivations — even for packages whose source code is
identical between revisions.

*Reference: Dolstra, "The Purely Functional Software Deployment Model" (2006), Chapter 5*

### Axiom C2: Fixed-Output Derivations (FODs)

FODs (fetchurl, fetchgit, fetchFromGitHub) declare their output hash in
advance. The store path is computed from the output hash, not the input
hash. This means:

- FODs are **content-addressed**: same content = same store path, regardless
  of how it was fetched
- FODs are always cached if the output exists in any substituter
- FODs are the **only** exception to the cascade property in C1

**Consequence:** Changing how a fetch is configured (e.g., updating a URL
but not the hash) does not trigger a rebuild if the content is unchanged.

### Axiom C3: Content-Addressed Derivations (Experimental)

RFC 0092 introduces content-addressed (CA) derivations, where the output
store path is computed from the output content rather than the input
derivation. This stops cascading rebuilds when the output is bitwise
identical despite input changes.

**Status:** Experimental. Not enforced in pleme-io. Enabled via
`__contentAddressed = true` on individual derivations.

**Consequence (future):** When CA stabilizes, a nixpkgs bump that doesn't
change a package's binary output will not cascade to dependents.

### Axiom C4: Binary Cache Key Identity

Binary cache lookup uses the tuple:

```
(system, storeHash, name)
```

Where `storeHash` is derived from the derivation hash (per C1). Therefore:

- **Same nixpkgs rev + same system + same source → cache hit**
- **Different nixpkgs rev → different storeHash → cache miss**
  (even if the output would be bitwise identical)

This is why pinning all repos to the same nixpkgs revision is the
highest-impact optimization: it maximizes the probability that a
derivation's storeHash matches what's already in the binary cache.

**Binary cache priority:**
```
Attic (pleme-io private) → priority 10 (checked first)
cache.nixos.org (public)  → priority 30 (fallback)
```

### Axiom C5: The follows Mechanism

When a flake input declares:

```nix
inputs.X.inputs.nixpkgs.follows = "nixpkgs";
```

it forces input X to use the top-level nixpkgs instead of its own. Without
follows, X brings its own nixpkgs, creating two independent nixpkgs
instances in the closure.

**Closure duplication cost:**
- 2× narStore size (glibc, coreutils, etc. appear twice)
- 2× evaluation time (Nix evaluates both nixpkgs instances)
- 0% cache sharing between the two graphs (per C1)

**Consequence:** A single missing follows directive can double the closure
size and halve the cache hit rate for everything downstream of that input.

### Axiom C6: Import-from-Derivation (IFD) Breaks Laziness

IFD occurs when Nix must **build** a derivation during **evaluation** to
determine the value of an expression. Common examples:

```nix
# IFD: must build generatedCargoNix before evaluation can continue
import (crate2nixTools.generatedCargoNix { inherit name src; })
```

IFD has three costs:

1. **Evaluation serialization:** In a CI fleet with M evaluators, IFD
   reduces throughput to 1 because evaluation blocks on a single build
2. **Breaks `nix flake show`:** Metadata queries require a builder
3. **Non-hermetic evaluation:** The result depends on builder availability

**Mitigation:** Commit the generated file (e.g., `Cargo.nix`) to the repo.
The import then reads a file, not a derivation.

### Axiom C7: Source Filtering Determines Build Identity

The source tree is an input to the derivation (per C1). If the source
includes files irrelevant to the build, any change to those files triggers
a rebuild:

```nix
src = ./.;          # Includes .git/, README.md, flake.lock → rebuilds on every commit
src = cleanSource;  # Excludes .git, result, target, flake.lock → stable hash
```

**Consequence:** Source filtering is not optional hygiene — it directly
determines derivation identity and cache hit probability.

---

## 3. Invariants

These are the rules pleme-io enforces. Each invariant is justified by one
or more axioms and enforced by both a static checker (nix-audit) and a
runtime guard (flake-hygiene.nix).

### INV-1: Single Nixpkgs Pin

**Rule:** All flakes pin nixpkgs to `nixos-25.11` (the current stable branch).

| Axiom | C1 (cascade), C4 (cache key) |
|-------|------------------------------|
| **nix-audit checker** | `nixpkgs_pin` |
| **flake-hygiene primitive** | `assertStablePin` |
| **Source of truth** | `substrate/lib/util/versions.nix` |

**Why:** Different nixpkgs branches have different revisions. Per C4,
different revisions produce different store hashes. A single org-wide pin
ensures all repos share the same derivation graph.

### INV-2: Complete follows Chains

**Rule:** Every flake input that transitively depends on nixpkgs must
declare `inputs.X.inputs.nixpkgs.follows = "nixpkgs"`.

| Axiom | C5 (follows), C1 (cascade) |
|-------|----------------------------|
| **nix-audit checker** | `follows_chain` |
| **flake-hygiene primitive** | `assertSingleNixpkgs` |

**Why:** A single missing follows creates an orphaned nixpkgs instance,
doubling closure size and eliminating cache sharing (per C5).

### INV-3: Filtered Source

**Rule:** All flakes use `cleanSource`, `cleanCargoSource`, `fileset`, or
equivalent source filtering. No bare `src = ./.` or `src = self`.

| Axiom | C7 (source identity) |
|-------|----------------------|
| **nix-audit checker** | `source_filter` |
| **flake-hygiene primitive** | `enforceSourceFilter` (rustSource, cleanSource) |

**Why:** Unfiltered source includes irrelevant files. Per C7, any change
to those files (README edit, flake.lock update) triggers a full rebuild.

### INV-4: No Import-from-Derivation

**Rule:** Generated files (Cargo.nix, node-packages.nix) must be committed
to the repo, not generated at evaluation time.

| Axiom | C6 (IFD) |
|-------|----------|
| **nix-audit checker** | `ifd_avoidance` |
| **flake-hygiene primitive** | (manual — detected by nix-audit) |

**Why:** IFD serializes evaluation (per C6) and breaks offline/sandboxed
evaluation. Committing the generated file eliminates IFD entirely.

### INV-5: Stable Version Strings

**Rule:** No `builtins.currentTime` or `builtins.getEnv "GIT_SHA"` in
derivation inputs.

| Axiom | C1 (cascade) |
|-------|--------------|
| **nix-audit checker** | `version_stability` |
| **flake-hygiene primitive** | (manual — detected by nix-audit) |

**Why:** `currentTime` changes every second. `getEnv "GIT_SHA"` changes
every commit. Either makes the derivation hash unique per evaluation,
guaranteeing a cache miss every time (per C1).

### INV-6: Layered Docker Images

**Rule:** Use `buildLayeredImage` with `maxLayers = 120`, not `buildImage`.

| Axiom | (Docker-specific, not Nix store) |
|-------|----------------------------------|
| **nix-audit checker** | `docker_layers` |
| **flake-hygiene primitive** | (convention — detected by nix-audit) |

**Why:** `buildImage` produces a single layer. Any change rebuilds the
entire image (~200MB). `buildLayeredImage` produces N layers sorted by
frequency-of-change: glibc/cacert in bottom layers (permanent), the
application binary in the top layer (changes on each release). Layer
reuse reduces push/pull time by ~95%.

### INV-7: Binary Cache Alignment

**Rule:** All repos resolve to the same nixpkgs revision in flake.lock.

| Axiom | C4 (cache key) |
|-------|----------------|
| **nix-audit checker** | `cache_alignment` |
| **flake-hygiene primitive** | (cross-repo — detected by nix-audit lock-analysis) |

**Why:** Even with INV-1 (same branch), repos can lock to different
commits of that branch if `nix flake update` runs at different times.
Per C4, different revisions = different store hashes = cache misses.
The `tend flake-update` propagation mechanism ensures all repos lock
to the same revision.

---

## 4. Metrics

These are quantitative measures of cache health, computed by nix-audit
and stored in the convergence database.

### M1: Nixpkgs Convergence Ratio

```
M1 = 1 / unique_nixpkgs_revs_across_all_flake_locks
```

Perfect (1.0): all repos share exactly one nixpkgs revision.
Degraded (< 1.0): some repos have divergent locks.

### M2: Follows Coverage

```
M2 = inputs_with_follows / total_non_nixpkgs_inputs
```

Perfect (1.0): every input follows the top-level nixpkgs.

### M3: Source Filter Coverage

```
M3 = flakes_with_filtered_source / total_flakes
```

Perfect (1.0): no bare `src = ./.` anywhere.

### M4: IFD Count

```
M4 = flakes_using_generated_cargo_nix_without_committed_file
```

Perfect (0): all generated files committed.

### M5: Closure Size Variance

```
M5 = stddev(closure_sizes) / mean(closure_sizes)
```

Low variance indicates consistent dependency graphs. High variance
suggests orphaned nixpkgs instances inflating some closures.

### M6: Cache Hit Rate

```
M6 = attic_cache_hits / (attic_cache_hits + attic_cache_misses)
```

Measured at the Attic substituter. Approaches 1.0 when all invariants hold.

---

## 5. Docker Layer Caching Model

### buildLayeredImage Internals

`pkgs.dockerTools.buildLayeredImage` sorts store paths into layers using a
**popularity-contest** algorithm:

1. Compute the reference graph of all store paths in the image
2. Sort paths by number of reverse references (most-referenced first)
3. Pack paths into `maxLayers` layers, bottom-up
4. Bottom layers: glibc, coreutils, cacert (shared by everything, never change)
5. Top layers: application binary (changes on each release)

Layer identity = hash of sorted store paths in that layer. Since bottom
layers contain stable, widely-shared paths, they are identical across
services — a single `docker pull` caches them for all pleme-io services.

### maxLayers = 120

Empirically optimal for Rust services: ~95% layer reuse across releases.
Increasing beyond 120 has diminishing returns and increases manifest size.

### Per-Crate vs Per-Tree Caching

| Strategy | Granularity | Cache unit | Rebuild scope |
|----------|-------------|------------|---------------|
| **crate2nix** | Per crate | Individual crate derivation | Changed crate + dependents |
| **crane** | Per tree | Entire cargo build | All crates on any source change |
| **naersk** | Per tree | Entire cargo build | All crates on any source change |

pleme-io uses **crate2nix** for all Rust projects: each crate is a separate
Nix derivation cached in Attic. Changing one `.rs` file rebuilds only the
affected crate and its direct dependents — not the entire workspace.

**Trade-off:** crate2nix requires a committed `Cargo.nix` (IFD avoidance
per INV-4), but this is a one-time setup cost paid once per `Cargo.lock`
change.

---

## 6. Convergence Model

### Definition

The enforcement loop is a fixed-point iteration:

```
State(t+1) = Verify(Enforce(Propagate(Fix(Observe(State(t))))))
```

Where:
- **Observe:** `nix-audit check --all` → produces findings
- **Fix:** `nix-audit fix --all --commit` → auto-repairs fixable violations
- **Propagate:** `tend flake-update` → propagates locked revisions across repos
- **Enforce:** `flake-hygiene.nix` → prevents regressions at eval-time
- **Verify:** `nix-audit check --all` → confirms convergence

### Formal Definitions

Let:
- R = set of all repositories
- C = {NixpkgsPin, FollowsChain, SourceFilter, IfdAvoidance, VersionStability, DockerLayers, CacheAlignment}
- v(r, c, t) = 1 if repo r has a violation in category c at time t, 0 otherwise
- V(t) = Σ v(r, c, t) over all (r, c) = total violations at time t

```
compliance_ratio(t) = 1 - V(t) / (|R| × |C|)
convergence_velocity(t) = compliance_ratio(t) - compliance_ratio(t-1)
stubborn_categories(t) = { c ∈ C : ∃ r ∈ R, v(r, c, t-2) = v(r, c, t-1) = v(r, c, t) = 1 }
```

### Monotonicity Invariant

```
compliance_ratio(t+1) ≥ compliance_ratio(t)
```

This holds because:

1. **Fix** only reduces violations (a fix either succeeds or is a no-op)
2. **Enforce** prevents new violations (flake-hygiene.nix throws at eval-time)
3. **Propagate** only propagates verified states (tend pushes after fix)

External events (new repos, upstream updates) can temporarily decrease the
ratio, but the next enforcement cycle immediately corrects them.

### Bounded Convergence Theorem

Let V_auto(t) = auto-fixable violations at time t, V_manual(t) = manually-fixable violations.

**Claim:** V_auto converges to zero in at most 2 iterations.

**Proof sketch:**
- Iteration 1: `nix-audit fix --all` addresses all auto-fixable violations in a single pass
- Iteration 2: `tend flake-update` propagates the fixes, which may reveal new follows violations
  in repos that previously had correct locks but now need to follow the updated input
- Iteration 3 onward: no new auto-fixable violations appear (enforce prevents them)

V_manual creates **stubborn categories** — violations that persist across
3+ runs because they require human intervention (e.g., restructuring a
flake to avoid IFD, or migrating from buildImage to buildLayeredImage in
a complex Nix expression). These are tracked and reported separately.

### Convergence Tracking

nix-audit stores results in a SQLite database (`~/.local/share/nix-audit/convergence.db`):

```sql
audit_runs:   (id, timestamp, total_repos, passing_repos, compliance_ratio)
findings:     (id, run_id, repo, category, severity, message, fixed)
```

The `nix-audit converge` command queries this database and displays:
- Per-category finding counts over the last N runs
- Org-wide compliance percentage with trend arrows
- Stubborn categories flagged for manual intervention
- Projected convergence date (linear extrapolation)

---

## 7. Integration with CIA Theory

This cache theory extends CIA theory.md Section 7 (Invariants) with a
seventh invariant:

> **Invariant 7 (extended): Pinned Dependencies with Cache Convergence**
>
> All flake inputs resolve to the same nixpkgs revision (INV-1 + INV-7),
> all transitive inputs follow the top-level pin (INV-2), and an automated
> enforcement loop (nix-audit + tend + flake-hygiene) continuously drives
> violations to zero with monotonically non-decreasing compliance.

The cache theory also contributes to CIA's Observation axiom (Axiom 4):
cache health metrics (M1–M6) are observable quantities that flow through
the transport layer (Vector → Loki/VictoriaMetrics → Grafana) alongside
the existing infrastructure metrics.

---

## Appendix A: Enforcement Traceability Matrix

| Invariant | Axiom(s) | nix-audit checker | flake-hygiene primitive | Auto-fixable? |
|-----------|----------|-------------------|------------------------|---------------|
| INV-1: Single Pin | C1, C4 | nixpkgs_pin | assertStablePin | Yes |
| INV-2: follows | C1, C5 | follows_chain | assertSingleNixpkgs | Yes |
| INV-3: Source Filter | C7 | source_filter | enforceSourceFilter | Partial |
| INV-4: No IFD | C6 | ifd_avoidance | — | No (manual) |
| INV-5: Stable Versions | C1 | version_stability | — | No (manual) |
| INV-6: Layered Docker | — | docker_layers | — | Partial |
| INV-7: Cache Alignment | C4 | cache_alignment | — | Yes (via tend) |

## Appendix B: Tool Responsibility Matrix

| Concern | nix-audit (Rust) | flake-hygiene.nix | tend daemon | versions.nix |
|---------|-----------------|-------------------|-------------|--------------|
| Detect violations | ✓ (check) | — | — | — |
| Fix violations | ✓ (fix) | — | — | — |
| Prevent regressions | — | ✓ (eval-time) | — | — |
| Propagate fixes | — | — | ✓ (flake-update) | — |
| Define standards | — | — | — | ✓ (source of truth) |
| Track convergence | ✓ (converge) | — | ✓ (audit log) | — |
