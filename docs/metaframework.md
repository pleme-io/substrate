# Pleme-io Metaframework

The pleme-io application stack is a convergence computing metaframework:
declare application state once, render through any backend, deploy to any
platform. This document describes the architecture, what exists, and how
the pieces connect.

## The Insight

Every pleme-io application is a convergence machine. The UI converges
toward the user's desired state through reactive state management, just
as infrastructure converges through tatara. The widget IS the convergence
point. The renderer is the target-specific materialization.

## Architecture

```
                    pleme-app-core
                    Pure Rust (no platform deps)
                    State machines, cache, sanitize, convergence types
                    Feature "web": Leptos providers, hooks, sync
                          |
              +-----------+-----------+
              |                       |
         egaku                   pleme-mui
    Widget state machines      Material Web + MUI islands
    TextInput, ScrollView      92 Leptos web components
    ListView, TabBar, Modal    Theme: irodori → MD3 tokens
    FocusManager, KeyMap
    PURE RUST — zero GPU deps
              |                       |
    +----+----+----+          +-------+
    |    |         |          |
 garasu  irodzuki  madori   Leptos
  wgpu   GPU theme  Event    DOM/HTML
  winit  bytemuck   loop     CSS
  glyphon           glue
    |                         |
    +--- GPU RENDERER ---+    +--- WEB RENDERER ---+
    |  Metal (macOS/iOS) |    |  wasm32-unknown    |
    |  Vulkan (Linux/And)|    |  Browser DOM       |
    |  DX12 (Windows)    |    |  HTML accessibility|
    |  WebGPU (Web)      |    +--------------------+
    +--------------------+
```

## What Exists Today

### Pure Rust (platform-agnostic, compiles everywhere)

| Crate | Purpose | WASM-safe |
|-------|---------|-----------|
| `egaku` | Widget state machines (TextInput, ScrollView, ListView, TabBar, SplitPane, Modal, FocusManager, KeyMap) | YES |
| `irodori` | Color system (Nord palette, sRGB/linear, semantic colors) | YES |
| `irodzuki` | GPU theme data (Base16→ColorScheme, ThemeUniforms as bytemuck POD) | YES |
| `shikumi` | Config discovery + hot-reload (XDG paths, Figment, ArcSwap) | Desktop only |
| `kenshou` | Auth (JWT Claims, TokenValidator, AuthProvider trait) | YES |
| `hayai` | Fast pattern matching (Normalizer→Prefilter→RegexSet DFA) | YES |
| `tsuuchi` | Notifications (Notification, Urgency, NotificationBackend trait) | YES |
| `awase` | Hotkeys (Hotkey, Key, Modifiers, BindingMap, KeyChord) | YES |
| `sekkei` | OpenAPI 3.0 serde types | YES |
| `pleme-app-core` | Framework infra: auto-save machine, retry config, cache tiers, sanitization, convergence tracing. Feature `web`: Leptos providers, hooks, sync, query cache, observability | YES |

### GPU Renderer (desktop, mobile with lifecycle changes, web via WebGPU)

| Crate | Purpose | Platforms |
|-------|---------|-----------|
| `garasu` | GPU primitives (GpuContext, TextRenderer, ShaderPipeline, AppWindow) | wgpu: macOS/Linux/Windows/Android/iOS/Web |
| `madori` | App framework (event loop, render callback, input dispatch) | winit: macOS/Linux/Windows/Android/iOS |
| `glyphon` | GPU text rasterization | wgpu (all platforms) |

### Web Renderer (browser only)

| Crate | Purpose |
|-------|---------|
| `pleme-mui` | 92 Leptos components (Material Web wrappers, MUI React islands, layout, feedback, data, form, navigation, overlay, PWA, schedule, motion) |
| `leptos` | Reactive web framework (CSR + SSR) |

### Framework Infrastructure

| Crate | Purpose |
|-------|---------|
| `pleme-app-core` (pure) | State machines, cache config, sanitization, convergence types |
| `pleme-app-core` (web) | Leptos providers (Auth, GraphQL, PWA, FeatureFlags, Theme), hooks (debounce, countdown, version check, push, online status), sync (cross-tab, session hygiene), WebSocket reconnect, query cache, observability (Sentry bridge, Web Vitals) |
| `substrate` | Nix build patterns: `leptos-build.nix` (SSR+CSR), `leptos-build-flake.nix`, `leptos-app-scaffold.nix` (app generator), workload archetypes → K8s/Tatara/WASI renderers |

## The Key Architectural Fact

**Egaku is already platform-agnostic.** Its widget state machines (TextInput,
ScrollView, ListView, TabBar, Modal, FocusManager) depend only on `serde`,
`tracing`, `unicode-segmentation`, and `unicode-width`. Zero GPU, zero
windowing, zero platform code. Egaku compiles to `wasm32-unknown-unknown`.

This means egaku can drive BOTH renderers:
- garasu reads egaku state → draws with wgpu
- pleme-mui could read egaku state → renders with Leptos/HTML

The widget logic is shared. Only the rendering differs.

## Platform Support Matrix

| Platform | GPU Renderer (garasu) | Web Renderer (pleme-mui) | Status |
|----------|----------------------|--------------------------|--------|
| macOS | wgpu → Metal | — | Working (mado, hibikine, etc.) |
| Linux | wgpu → Vulkan | — | Working |
| Windows | wgpu → DX12/Vulkan | — | Supported by wgpu |
| Android | wgpu → Vulkan | — | Needs lifecycle work |
| iOS | wgpu → Metal | — | Needs lifecycle work |
| Web (WASM) | wgpu → WebGPU | Leptos → DOM | pleme-mui working, WebGPU experimental |

## What's Needed for Mobile

garasu+wgpu already runs on Android (Vulkan) and iOS (Metal) via winit.
The actual work:

1. **Lifecycle awareness** — handle winit `Suspended`/`Resumed` events
   (defer wgpu surface creation, recreate on resume)
2. **Touch input** — map winit `Touch` events to egaku's pointer model
3. **Soft keyboard** — detect virtual keyboard, adjust viewport
4. **Accessibility** — AccessKit generates platform accessibility trees
   from egaku widget state
5. **Packaging** — cargo-ndk (Android/Gradle), cargo-xcode (iOS)

## What's Needed for Unified UI

The bridge between egaku (state) and pleme-mui (web rendering):

```rust
// egaku provides the state
let text_input = egaku::TextInput::new();
text_input.insert('a');
text_input.cursor_right();

// GPU renderer reads it
garasu_renderer.draw_text_input(&text_input, &theme);

// Web renderer could also read it
pleme_mui_renderer.render_text_input(&text_input); // → <md-outlined-text-field>
```

This is NOT implemented yet. Currently:
- GPU apps use egaku directly
- Web apps use pleme-mui directly (separate widget state)

The unification would share egaku's pure state machines across both
renderers, achieving true write-once render-anywhere.

## Academic Grounding

The metaframework embodies these formal results:

| Concept | Theorem | Realization |
|---------|---------|-------------|
| Widget as convergence point | Banach contraction | Each user action reduces distance to desired state |
| Egaku state machines | Knaster-Tarski fixed point | Widget state converges to stable configuration |
| Dual renderer | Abstract interpretation (Cousot) | egaku = abstract domain, garasu/pleme-mui = concretization |
| Platform-agnostic state | CALM theorem | Monotone widget operations need no coordination |
| Content-addressed builds | Dolstra (Nix) | substrate store paths = convergence proofs |
| Typed DAG rendering | Session types (Honda) | Archetype → renderer edges are typed protocols |

## Spawning a New Application

### Web PWA
```nix
scaffold = import "${substrate}/lib/leptos-app-scaffold.nix" { inherit lib; };
app = scaffold.generate ({
  name = "my-product";
  primaryColor = "#3b82f6";
} // scaffold.templates.standard);
# → pleme-app-core + pleme-mui pre-wired, all providers included
```

### GPU Desktop App
```rust
// Uses the existing garasu+egaku+madori pattern
fn main() {
    let app = madori::App::builder(MyRenderer)
        .title("My App")
        .size(1200, 800)
        .run();
}
```

### Future: Universal App (both renderers from one codebase)
```rust
// Declare state with egaku (platform-agnostic)
let ui_state = MyAppState::new();

// Build for GPU desktop/mobile
#[cfg(feature = "gpu")]
madori::App::builder(GarasuRenderer::new(&ui_state)).run();

// Build for web
#[cfg(feature = "web")]
leptos::mount_to_body(|| view! { <PleMuiApp state=ui_state /> });
```

## Convergence Computing Connection

The metaframework IS convergence computing applied to application development.
Every layer follows the same pattern: declare, resolve, converge, checkpoint, verify.

### The Application as Convergence Machine

```
User Intent (desired state)
    | declare
Widget State (egaku -- platform-agnostic state machines)
    | resolve (choose renderer)
Rendering Backend (garasu GPU or pleme-mui web)
    | converge (render to screen)
Visible UI (actual state)
    | checkpoint
User Interaction (event)
    | verify (validation, auth checks)
State Transition (convergence step)
    | distance reduced
Loop until distance = 0 (user's intent realized)
```

Each UI interaction is a convergence step:
- **Auth flow**: Unauthenticated, token, verified, authenticated (distance: session validity)
- **Auto-save**: Changed, debouncing, saving, saved (distance: unsaved changes)
- **Search**: Query, filter, results (distance: information gap)
- **Payment**: Selected, processing, confirmed (distance: transaction completion)

### Manufacturing Intent into Computational Reality

The full convergence chain from thought to running software:

```
Layer 0: Human Intent
  "I want a dating classifieds platform"
        | declare (scaffold)
Layer 1: Nix Expression (substrate)
  scaffold.generate { name = "lilitu"; features = ["auth" "pwa"]; }
        | resolve (scaffold generates files)
Layer 2: Rust Source Code
  pleme-app-core providers + pleme-mui components + app features
        | converge (cargo build / nix build)
Layer 3: Artifacts
  SSR binary + CSR WASM bundle + Docker image
        | checkpoint (content-addressed Nix store path)
Layer 4: Deployment Spec (substrate archetype)
  mkHttpService { name = "lilitu-web"; ... }
        | render (K8s / Tatara / WASI)
Layer 5: Running System
  Pod on K8s cluster OR Tatara convergence job OR WASI component
        | verify (health checks, attestation)
Layer 6: Proven Convergence
  tameshi BLAKE3 Merkle attestation of the deployed state
```

Each layer IS a convergence point in the larger DAG:
- Layer 0 to 1: Intent converges to specification (Nix expression)
- Layer 1 to 2: Specification converges to source (code generation)
- Layer 2 to 3: Source converges to artifact (compilation -- Banach contraction)
- Layer 3 to 4: Artifact converges to deployment spec (archetype rendering -- abstract interpretation)
- Layer 4 to 5: Spec converges to running system (K8s reconciliation -- Lyapunov stability)
- Layer 5 to 6: Running system converges to proven state (tameshi attestation -- Merkle composition)

### The Tatara / WASI Connection

Tatara is the convergence execution engine. The metaframework feeds it:

1. **Nix evaluation** produces deployment specs (substrate archetypes)
2. **Tatara renderer** translates specs to JobSpecs
3. **Tatara engine** drives convergence via 7 drivers:
   - `exec`: Direct process (dev/test)
   - `oci`: Docker/Podman (standard deployment)
   - `nix`: `nix run` (Nix-native)
   - `nix_build`: Build + cache to Attic
   - `kasou`: Apple VMs (macOS testing)
   - `kube`: Kubernetes Server-Side Apply
   - `wasi`: wasmtime WASI Preview 2 (edge/serverless)

4. **WASI specifically** enables:
   - Sub-millisecond cold starts (Spin/wasmtime)
   - Capability-based security (no filesystem unless granted)
   - Content-addressed components (hash of WASM = convergence proof)
   - Platform-independent execution (same .wasm runs everywhere)

### The Kubernetes / FluxCD Connection

For K8s deployments, the convergence chain continues:

```
substrate archetype -> kubernetes.nix renderer -> nix-kube compositions
    | (Nix evaluation)
K8s manifests (Deployment, Service, NetworkPolicy, HPA, ...)
    | (git commit)
FluxCD Kustomization (GitOps reconciliation)
    | (continuous convergence)
Running pods (actual state = desired state)
    | (health checks)
Convergence distance = 0
```

FluxCD IS a convergence engine: it continuously reconciles git state
(desired) with cluster state (actual). The distance function is the
diff between declared manifests and running resources. When distance = 0,
the cluster has converged.

Helm values generated by `mkLeptosHelmValues` flow through this chain:
```
Nix archetype -> Helm values -> FluxCD HelmRelease -> K8s -> Running app
```

Each step preserves the convergence invariant: the output is closer to
the declared intent than the input was.

## Related Documents

- [Adding a Leptos App](adding-a-leptos-app.md) — scaffold + build + deploy
- [Unified Infrastructure Theory](unified-infrastructure-theory.md) — archetypes + renderers
- [Testing](testing.md) — three-layer test pyramid
- [Security](security.md) — supply chain + attestation
