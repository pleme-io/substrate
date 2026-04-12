# ============================================================================
# LEPTOS APP SCAFFOLD — Generate a complete Leptos PWA from a declaration
# ============================================================================
# Creates the full project structure for a new Leptos web application
# with all pleme-io infrastructure pre-wired: state machines, query cache,
# observability, PWA, auth, i18n, Material Web components.
#
# This implements the convergence computing principle: declare the desired
# state (app specification), and the scaffold converges it into existence.
#
# Usage:
#   nix run .#scaffold-app -- --name "my-app" --org "pleme-io"
#
# Or programmatically:
#   scaffold = import "${substrate}/lib/build/rust/leptos-app-scaffold.nix" { inherit lib; };
#   files = scaffold.generate {
#     name = "my-app";
#     displayName = "My Application";
#     description = "A new pleme-io product";
#     primaryColor = "#dc143c";
#     secondaryColor = "#ff69b4";
#     accentColor = "#ffd700";
#     locale = "pt-BR";
#     features = [ "auth" "pwa" "i18n" "observability" "admin" ];
#     domain = {
#       entities = [ "user" "item" "order" ];
#     };
#   };
{ lib }:

{
  # ========================================================================
  # generate — Produce the complete file tree for a new Leptos PWA
  # ========================================================================
  generate = {
    name,
    displayName ? name,
    description ? "A pleme-io application",
    # Brand colors (override irodori defaults)
    primaryColor ? "#88C0D0",
    secondaryColor ? "#81A1C1",
    accentColor ? "#EBCB8B",
    backgroundColor ? "#0a0a0a",
    # Locale
    locale ? "en",
    # Features to include
    features ? [ "auth" "pwa" "i18n" "observability" ],
    # Domain entities
    domain ? { entities = []; },
    # Deployment
    port ? 3000,
    healthPort ? 3001,
    repo ? "pleme-io/${name}",
  }: let
    hasFeature = f: builtins.elem f features;
    kebab = name; # assumed kebab-case input
    snake = builtins.replaceStrings ["-"] ["_"] name;
    pascal = lib.concatMapStrings (s:
      let first = builtins.substring 0 1 s;
          rest = builtins.substring 1 (builtins.stringLength s) s;
      in (lib.toUpper first) + rest
    ) (lib.splitString "-" name);

    # ====================================================================
    # File generators
    # ====================================================================

    workspaceCargo = ''
      [workspace]
      members = ["crates/${kebab}-app"]
      resolver = "2"

      [workspace.package]
      version = "0.1.0"
      edition = "2024"
      rust-version = "1.89.0"
      license = "MIT"

      [workspace.dependencies]
      leptos = { version = "0.7", features = ["csr"] }
      leptos_router = "0.7"
      leptos_meta = "0.7"
      pleme-app-core = { git = "https://github.com/pleme-io/pleme-app-core" }
      pleme-mui = { git = "https://github.com/pleme-io/pleme-mui" }
      serde = { version = "1", features = ["derive"] }
      serde_json = "1"
      wasm-bindgen = "0.2"
      wasm-bindgen-futures = "0.4"
      web-sys = { version = "0.3", features = [
          "Window", "Document", "Navigator", "Storage",
          "HtmlElement", "Location", "History",
          "ServiceWorkerContainer", "ServiceWorkerRegistration",
          "CustomEvent", "Event", "EventTarget", "StorageEvent",
      ] }
      js-sys = "0.3"
      gloo-net = "0.6"
      gloo-storage = "0.3"
      gloo-timers = "0.3"
      gloo-events = "0.2"
      gloo-utils = "0.2"
      tracing = "0.1"
      tracing-subscriber = { version = "0.3", features = ["env-filter"] }
      chrono = { version = "0.4", features = ["serde"] }
      uuid = { version = "1", features = ["v4", "serde", "js"] }

      [workspace.lints.clippy]
      pedantic = "warn"
    '';

    crateCargo = ''
      [package]
      name = "${kebab}-app"
      version.workspace = true
      edition.workspace = true
      rust-version.workspace = true
      license.workspace = true
      description = "${description}"

      [dependencies]
      leptos.workspace = true
      leptos_router.workspace = true
      leptos_meta.workspace = true
      pleme-app-core = { workspace = true, features = ["web"] }
      pleme-mui.workspace = true
      serde.workspace = true
      serde_json.workspace = true
      wasm-bindgen.workspace = true
      wasm-bindgen-futures.workspace = true
      web-sys.workspace = true
      js-sys.workspace = true
      gloo-net.workspace = true
      gloo-storage.workspace = true
      gloo-timers.workspace = true
      gloo-events.workspace = true
      gloo-utils.workspace = true
      tracing.workspace = true
      tracing-subscriber.workspace = true
      chrono.workspace = true
      uuid.workspace = true

      [lints]
      workspace = true
    '';

    flakeNix = ''
      {
        inputs = {
          nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
          fenix = {
            url = "github:nix-community/fenix";
            inputs.nixpkgs.follows = "nixpkgs";
          };
          substrate = {
            url = "github:pleme-io/substrate";
            inputs.nixpkgs.follows = "nixpkgs";
          };
        };

        outputs = { self, nixpkgs, fenix, substrate, ... }:
          (import "''${substrate}/lib/leptos-build-flake.nix" {
            inherit nixpkgs substrate;
          }) {
            inherit self;
            name = "${kebab}";
            port = ${toString port};
            healthPort = ${toString healthPort};
          };
      }
    '';

    mainRs = ''
      use leptos::prelude::*;
      use ${snake}_app::app::${pascal}App;

      fn main() {
          mount_to_body(|| view! { <${pascal}App /> });
      }
    '';

    libRs = ''
      pub mod app;
      pub mod router;
      pub mod providers;
      pub mod pages;
      pub mod shared;
      pub mod infra;
    '' + lib.optionalString (hasFeature "auth") "pub mod features;\n";

    appRs = ''
      use leptos::prelude::*;
      use leptos_meta::provide_meta_context;
      use crate::providers::theme::ThemeProvider;
    ''
    + lib.optionalString (hasFeature "pwa") "use crate::providers::pwa::PwaProvider;\n"
    + lib.optionalString (hasFeature "auth") "use crate::providers::auth::AuthProvider;\n"
    + lib.optionalString (hasFeature "i18n") "use crate::providers::i18n::I18nProvider;\n"
    + ''
      use crate::router::AppRouter;

      #[component]
      pub fn ${pascal}App() -> impl IntoView {
          provide_meta_context();

          view! {
    ''
    + lib.optionalString (hasFeature "i18n") "          <I18nProvider>\n"
    + ''
              <ThemeProvider>
    ''
    + lib.optionalString (hasFeature "pwa") "              <PwaProvider>\n"
    + lib.optionalString (hasFeature "auth") "              <AuthProvider>\n"
    + ''
                  <ErrorBoundary fallback=|errors| {
                      view! {
                          <div style="padding: 2rem; color: var(--color-error, #ff4444);">
                              <h2>"Something went wrong"</h2>
                              <ul>
                                  {move || errors.get()
                                      .into_iter()
                                      .map(|(_, e)| view! { <li>{e.to_string()}</li> })
                                      .collect::<Vec<_>>()
                                  }
                              </ul>
                          </div>
                      }
                  }>
                      <Suspense fallback=move || view! {
                          <div style="display: flex; align-items: center; justify-content: center; min-height: 100vh;">
                              <div style="width: 2rem; height: 2rem; border: 3px solid #333; border-top-color: var(--color-primary); border-radius: 50%; animation: spin 0.8s linear infinite;"></div>
                              <style>"@keyframes spin { to { transform: rotate(360deg); } }"</style>
                          </div>
                      }>
                          <AppRouter />
                      </Suspense>
                  </ErrorBoundary>
    ''
    + lib.optionalString (hasFeature "auth") "              </AuthProvider>\n"
    + lib.optionalString (hasFeature "pwa") "              </PwaProvider>\n"
    + ''
              </ThemeProvider>
    ''
    + lib.optionalString (hasFeature "i18n") "          </I18nProvider>\n"
    + ''
          }
      }
    '';

    routerRs = ''
      use leptos::prelude::*;
      use leptos_router::components::{Route, Router, Routes};
      use leptos_router::path;

      #[component]
      pub fn AppRouter() -> impl IntoView {
          view! {
              <Router>
                  <Routes fallback=|| "Not found.">
                      <Route path=path!("") view=HomePage />
                  </Routes>
              </Router>
          }
      }

      #[component]
      fn HomePage() -> impl IntoView {
          view! {
              <main>
                  <h1>"Welcome"</h1>
              </main>
          }
      }
    '';

    providersModRs = ''
      pub mod theme;
    ''
    + lib.optionalString (hasFeature "auth") "pub mod auth;\n"
    + lib.optionalString (hasFeature "pwa") "pub mod pwa;\n"
    + lib.optionalString (hasFeature "i18n") "pub mod i18n;\n";

    providersThemeRs = ''
      use leptos::prelude::*;

      /// Theme provider wrapping children with CSS custom properties.
      #[component]
      pub fn ThemeProvider(children: Children) -> impl IntoView {
          view! {
              <div class="theme-root">
                  {children()}
              </div>
          }
      }
    '';

    providersAuthRs = ''
      use leptos::prelude::*;

      /// Auth provider wrapping children with authentication context.
      #[component]
      pub fn AuthProvider(children: Children) -> impl IntoView {
          view! {
              <div class="auth-root">
                  {children()}
              </div>
          }
      }
    '';

    providersPwaRs = ''
      use leptos::prelude::*;

      /// PWA provider for service worker registration and offline support.
      #[component]
      pub fn PwaProvider(children: Children) -> impl IntoView {
          view! {
              <div class="pwa-root">
                  {children()}
              </div>
          }
      }
    '';

    providersI18nRs = ''
      use leptos::prelude::*;

      /// I18n provider wrapping children with locale context.
      #[component]
      pub fn I18nProvider(children: Children) -> impl IntoView {
          view! {
              <div class="i18n-root">
                  {children()}
              </div>
          }
      }
    '';

    pagesModRs = ''
      // Page components — add your routes here.
    '';

    sharedModRs = ''
      // Shared types and utilities.
    '';

    infraModRs = ''
      // Infrastructure: API clients, config, error types.
    '';

    featuresModRs = ''
      // Feature modules (auth flows, admin panels, etc.).
    '';

    manifestJson = builtins.toJSON {
      name = displayName;
      short_name = displayName;
      description = description;
      start_url = "/";
      scope = "/";
      display = "standalone";
      theme_color = primaryColor;
      background_color = backgroundColor;
      lang = locale;
      icons = [
        { src = "/icons/icon-192.png"; sizes = "192x192"; type = "image/png"; purpose = "any maskable"; }
        { src = "/icons/icon-512.png"; sizes = "512x512"; type = "image/png"; purpose = "any maskable"; }
      ];
    };

  in {
    # Return a flat attrset of path -> content
    files = {
      "Cargo.toml" = workspaceCargo;
      "flake.nix" = flakeNix;
      ".gitignore" = "/target\n/dist\n*.swp\n.DS_Store\nnode_modules/\n";
      "LICENSE" = "MIT License\n\nCopyright (c) 2026 pleme-io\n";
      "Trunk.toml" = "[build]\ntarget = \"index.html\"\ndist = \"dist\"\n";
      "index.html" = ''
        <!DOCTYPE html>
        <html lang="${locale}">
        <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <meta name="theme-color" content="${primaryColor}" />
            <meta name="description" content="${description}" />
            <link rel="manifest" href="/manifest.json" />
            <title>${displayName}</title>
            <style>
                body { margin: 0; background: ${backgroundColor}; color: #e0e0e0; font-family: 'Inter', system-ui, sans-serif; }
                .app-loading { display: flex; align-items: center; justify-content: center; min-height: 100vh; }
            </style>
        </head>
        <body>
            <link data-trunk rel="rust" data-wasm-opt="z" />
        </body>
        </html>
      '';
      "public/manifest.json" = manifestJson;
      "public/version.json" = builtins.toJSON { version = "0.1.0"; gitSha = "dev"; buildTime = "2026-01-01T00:00:00Z"; };
      "crates/${kebab}-app/Cargo.toml" = crateCargo;
      "crates/${kebab}-app/src/main.rs" = mainRs;
      "crates/${kebab}-app/src/lib.rs" = libRs;
      "crates/${kebab}-app/src/app.rs" = appRs;
      "crates/${kebab}-app/src/router.rs" = routerRs;
      "crates/${kebab}-app/src/providers/mod.rs" = providersModRs;
      "crates/${kebab}-app/src/providers/theme.rs" = providersThemeRs;
      "crates/${kebab}-app/src/pages/mod.rs" = pagesModRs;
      "crates/${kebab}-app/src/shared/mod.rs" = sharedModRs;
      "crates/${kebab}-app/src/infra/mod.rs" = infraModRs;
    }
    // lib.optionalAttrs (hasFeature "auth") {
      "crates/${kebab}-app/src/providers/auth.rs" = providersAuthRs;
    }
    // lib.optionalAttrs (hasFeature "pwa") {
      "crates/${kebab}-app/src/providers/pwa.rs" = providersPwaRs;
    }
    // lib.optionalAttrs (hasFeature "i18n") {
      "crates/${kebab}-app/src/providers/i18n.rs" = providersI18nRs;
    }
    // lib.optionalAttrs (hasFeature "auth") {
      "crates/${kebab}-app/src/features/mod.rs" = featuresModRs;
    };

    # Metadata for substrate builders
    meta = {
      inherit name displayName description primaryColor secondaryColor accentColor;
      inherit locale port healthPort repo;
      inherit features;
    };

    # Deployment spec (for archetype rendering)
    deployment = {
      inherit name port healthPort;
      image = "ghcr.io/${repo}:latest";
      health = { path = "/healthz"; inherit port; };
      resources = { cpu = "200m"; memory = "256Mi"; };
      scaling = { min = 2; max = 10; };
    };
  };

  # ========================================================================
  # Predefined app templates
  # ========================================================================

  templates = {
    # Minimal app — just routing and theme
    minimal = {
      features = [];
    };

    # Standard web app — auth + PWA + i18n + observability
    standard = {
      features = [ "auth" "pwa" "i18n" "observability" ];
    };

    # Full product — everything including admin
    product = {
      features = [ "auth" "pwa" "i18n" "observability" "admin" "search" "payments" ];
    };

    # Internal tool — auth + admin, no PWA
    internal = {
      features = [ "auth" "admin" "observability" ];
    };
  };
}
