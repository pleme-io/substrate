# ============================================================================
# RUST SERVICE SCAFFOLD — Generate a complete Axum backend service
# ============================================================================
# Creates the full project structure for a new Rust backend service
# with Axum, optional GraphQL (async-graphql), database (sea-orm),
# authentication, observability, and health checks.
#
# This implements the convergence computing principle: declare the desired
# state (service specification), and the scaffold converges it into existence.
#
# Usage:
#   scaffold = import "${substrate}/lib/build/rust/rust-service-scaffold.nix" { inherit lib; };
#   files = scaffold.generate ({
#     name = "my-service";
#   } // scaffold.templates.graphql);
{ lib }:

{
  # ========================================================================
  # generate — Produce the complete file tree for a new Axum service
  # ========================================================================
  generate = {
    name,
    description ? "A pleme-io backend service",
    features ? [ "rest" "health" "observability" ],
    port ? 8080,
    healthPort ? 8080,
    repo ? "pleme-io/${name}",
  }: let
    hasFeature = f: builtins.elem f features;
    kebab = name;
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
      members = ["crates/${kebab}-server"]
      resolver = "2"

      [workspace.package]
      version = "0.1.0"
      edition = "2024"
      rust-version = "1.89.0"
      license = "MIT"

      [workspace.dependencies]
      axum = "0.8"
      tokio = { version = "1", features = ["full"] }
      tracing = "0.1"
      tracing-subscriber = { version = "0.3", features = ["env-filter"] }
      serde = { version = "1", features = ["derive"] }
      serde_json = "1"
    ''
    + lib.optionalString (hasFeature "graphql") ''
      async-graphql = "7"
      async-graphql-axum = "7"
    ''
    + lib.optionalString (hasFeature "db") ''
      sea-orm = { version = "1", features = ["sqlx-postgres", "runtime-tokio-rustls"] }
    ''
    + lib.optionalString (hasFeature "auth") ''
      jsonwebtoken = "9"
    ''
    + lib.optionalString (hasFeature "grpc") ''
      tonic = "0.12"
      prost = "0.13"
    ''
    + ''

      [workspace.lints.clippy]
      pedantic = "warn"
    '';

    serverCargo = ''
      [package]
      name = "${kebab}-server"
      version.workspace = true
      edition.workspace = true
      rust-version.workspace = true
      license.workspace = true
      description = "${description}"

      [dependencies]
      axum.workspace = true
      tokio.workspace = true
      tracing.workspace = true
      tracing-subscriber.workspace = true
      serde.workspace = true
      serde_json.workspace = true
    ''
    + lib.optionalString (hasFeature "graphql") ''
      async-graphql.workspace = true
      async-graphql-axum.workspace = true
    ''
    + lib.optionalString (hasFeature "db") ''
      sea-orm.workspace = true
    ''
    + lib.optionalString (hasFeature "auth") ''
      jsonwebtoken.workspace = true
    ''
    + lib.optionalString (hasFeature "grpc") ''
      tonic.workspace = true
      prost.workspace = true
    ''
    + ''

      [lints]
      workspace = true
    '';

    flakeNix = ''
      {
        inputs = {
          nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
          crate2nix.url = "github:nix-community/crate2nix";
          flake-utils.url = "github:numtide/flake-utils";
          substrate = {
            url = "github:pleme-io/substrate";
            inputs.nixpkgs.follows = "nixpkgs";
          };
        };

        outputs = { self, nixpkgs, crate2nix, flake-utils, substrate, ... }:
          (import "''${substrate}/lib/build/rust/service-flake.nix" {
            inherit nixpkgs crate2nix flake-utils;
          }) {
            serviceName = "${kebab}";
            src = self;
            repo = "${repo}";
          };
      }
    '';

    mainRs = ''
      use ${snake}_server::config::Config;
      use axum::Router;
      use tokio::net::TcpListener;

      #[tokio::main]
      async fn main() {
          tracing_subscriber::fmt::init();
          let config = Config::from_env();
          let app = ${snake}_server::router(&config).await;
          let listener = TcpListener::bind(&config.bind_addr).await.unwrap();
          tracing::info!("listening on {}", config.bind_addr);
          axum::serve(listener, app).await.unwrap();
      }
    '';

    libRs = ''
      pub mod config;
      pub mod error;
      pub mod health;
    ''
    + lib.optionalString (hasFeature "rest" || hasFeature "graphql") "pub mod api;\n"
    + lib.optionalString (hasFeature "db") "pub mod db;\n"
    + ''

      use axum::Router;
      use config::Config;

      pub async fn router(_config: &Config) -> Router {
          let app = Router::new()
              .merge(health::routes());
    ''
    + lib.optionalString (hasFeature "rest") ''
              // .merge(api::rest_routes())
    ''
    + lib.optionalString (hasFeature "graphql") ''
              // .merge(api::graphql_routes())
    ''
    + ''
          ;
          app
      }
    '';

    configRs = ''
      use serde::Deserialize;

      #[derive(Debug, Clone, Deserialize)]
      pub struct Config {
          pub bind_addr: String,
    ''
    + lib.optionalString (hasFeature "db") ''
          pub database_url: String,
    ''
    + ''
      }

      impl Config {
          pub fn from_env() -> Self {
              Self {
                  bind_addr: std::env::var("BIND_ADDR")
                      .unwrap_or_else(|_| "0.0.0.0:${toString port}".to_string()),
    ''
    + lib.optionalString (hasFeature "db") ''
                  database_url: std::env::var("DATABASE_URL")
                      .unwrap_or_else(|_| "postgres://localhost/${snake}".to_string()),
    ''
    + ''
              }
          }
      }
    '';

    healthRs = ''
      use axum::{Router, routing::get, Json};
      use serde_json::{json, Value};

      pub fn routes() -> Router {
          Router::new()
              .route("/healthz", get(healthz))
              .route("/readyz", get(readyz))
      }

      async fn healthz() -> Json<Value> {
          Json(json!({ "status": "ok" }))
      }

      async fn readyz() -> Json<Value> {
          Json(json!({ "status": "ready" }))
      }
    '';

    errorRs = ''
      use axum::http::StatusCode;
      use axum::response::{IntoResponse, Response};

      #[derive(Debug)]
      pub enum AppError {
          Internal(String),
          NotFound(String),
          BadRequest(String),
      }

      impl IntoResponse for AppError {
          fn into_response(self) -> Response {
              let (status, message) = match self {
                  Self::Internal(msg) => (StatusCode::INTERNAL_SERVER_ERROR, msg),
                  Self::NotFound(msg) => (StatusCode::NOT_FOUND, msg),
                  Self::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg),
              };
              let body = serde_json::json!({ "error": message });
              (status, axum::Json(body)).into_response()
          }
      }
    '';

    apiModRs = ''
      // API routes module.
    ''
    + lib.optionalString (hasFeature "graphql") "pub mod graphql;\n"
    + lib.optionalString (hasFeature "rest") "// pub mod rest;\n";

    apiGraphqlRs = ''
      use async_graphql::{EmptyMutation, EmptySubscription, Object, Schema};

      pub struct QueryRoot;

      #[Object]
      impl QueryRoot {
          async fn hello(&self) -> &str {
              "Hello from ${pascal}!"
          }
      }

      pub type ${pascal}Schema = Schema<QueryRoot, EmptyMutation, EmptySubscription>;

      pub fn build_schema() -> ${pascal}Schema {
          Schema::build(QueryRoot, EmptyMutation, EmptySubscription)
              .finish()
      }
    '';

    dbModRs = ''
      // Database connection and entity modules.
    '';

    dockerfile = ''
      FROM scratch
      COPY ${kebab}-server /
      EXPOSE ${toString port}
      ENTRYPOINT ["/${kebab}-server"]
    '';

  in {
    files = {
      "Cargo.toml" = workspaceCargo;
      "flake.nix" = flakeNix;
      ".gitignore" = "/target\n*.swp\n.DS_Store\n";
      "LICENSE" = "MIT License\n\nCopyright (c) 2026 pleme-io\n";
      "crates/${kebab}-server/Cargo.toml" = serverCargo;
      "crates/${kebab}-server/src/main.rs" = mainRs;
      "crates/${kebab}-server/src/lib.rs" = libRs;
      "crates/${kebab}-server/src/config.rs" = configRs;
      "crates/${kebab}-server/src/health.rs" = healthRs;
      "crates/${kebab}-server/src/error.rs" = errorRs;
    }
    // lib.optionalAttrs (hasFeature "rest" || hasFeature "graphql") {
      "crates/${kebab}-server/src/api/mod.rs" = apiModRs;
    }
    // lib.optionalAttrs (hasFeature "graphql") {
      "crates/${kebab}-server/src/api/graphql.rs" = apiGraphqlRs;
    }
    // lib.optionalAttrs (hasFeature "db") {
      "crates/${kebab}-server/src/db/mod.rs" = dbModRs;
    }
    // lib.optionalAttrs (hasFeature "rest" || hasFeature "graphql" || hasFeature "grpc") {
      "Dockerfile" = dockerfile;
    };

    meta = {
      inherit name description port healthPort repo features;
    };

    deployment = {
      inherit name port healthPort;
      image = "ghcr.io/${repo}:latest";
      health = { path = "/healthz"; inherit port; };
      resources = { cpu = "500m"; memory = "512Mi"; };
      scaling = { min = 2; max = 20; };
    };
  };

  # ========================================================================
  # Predefined service templates
  # ========================================================================

  templates = {
    minimal = {
      features = [ "health" ];
    };

    api = {
      features = [ "rest" "auth" "observability" "health" ];
    };

    graphql = {
      features = [ "graphql" "auth" "db" "observability" "health" ];
    };

    full = {
      features = [ "graphql" "rest" "db" "auth" "observability" "health" "grpc" ];
    };
  };
}
