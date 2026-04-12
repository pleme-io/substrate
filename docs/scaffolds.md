# Substrate Scaffolds

Generate complete project structures from declarations. Each scaffold
implements the convergence principle: declare intent, scaffold converges
into existence.

## Available Scaffolds

| Scaffold | Command | What it generates |
|----------|---------|-------------------|
| Leptos PWA | `leptosAppScaffold` | 22-file web app with providers, hooks, PWA |
| Rust Service | `rustServiceScaffold` | Axum backend with GraphQL/REST, DB, health |
| Rust CLI Tool | `rustToolScaffold` | Clap CLI with config, completions |
| Dioxus Desktop | `dioxusAppScaffold` | Desktop/mobile app with routing, theme |
| GPU Application | `gpuAppScaffold` | garasu+egaku+madori GPU-rendered app |
| Ruby Gem | `rubyGemScaffold` | Pangea IaC gem with RSpec |

## Usage Pattern

All scaffolds follow the same API:

```nix
scaffold = import "${substrate}/lib/{scaffold-name}.nix" { inherit lib; };

app = scaffold.generate ({
  name = "my-project";
  # project-specific options...
} // scaffold.templates.standard);

# app.files — attrset of path -> content
# app.meta — project metadata
# app.deployment — deployment spec for substrate archetypes
```

## Templates

Each scaffold provides preset feature combinations:

### Leptos PWA
- `minimal` — routing + theme
- `standard` — auth + PWA + i18n + observability
- `product` — standard + admin + search + payments
- `internal` — auth + admin (no PWA)

### Rust Service
- `minimal` — HTTP + health
- `api` — REST + auth + observability
- `graphql` — GraphQL + auth + DB + observability
- `full` — everything

### CLI Tool
- `minimal` — clap only
- `standard` — clap + config + completions
- `mcp` — MCP server tool

### Dioxus Desktop
- `desktop` — desktop with sidebar + routing
- `mobile` — mobile scaffold
- `full` — both

### GPU Application
- `minimal` — window + basic rendering
- `editor` — text editing
- `media` — audio/video
- `full` — everything

### Ruby Gem
- `library` — standard gem
- `pangea` — Pangea provider with resources + RSpec
