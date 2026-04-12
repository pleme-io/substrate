# ============================================================================
# RUST TOOL SCAFFOLD — Generate a complete Clap CLI tool
# ============================================================================
# Creates the full project structure for a new Rust CLI tool
# with Clap derive, optional config (shikumi), completions, and MCP.
#
# This implements the convergence computing principle: declare the desired
# state (tool specification), and the scaffold converges it into existence.
#
# Usage:
#   scaffold = import "${substrate}/lib/build/rust/rust-tool-scaffold.nix" { inherit lib; };
#   files = scaffold.generate ({
#     name = "my-tool";
#   } // scaffold.templates.standard);
{ lib }:

{
  # ========================================================================
  # generate — Produce the complete file tree for a new CLI tool
  # ========================================================================
  generate = {
    name,
    description ? "A pleme-io CLI tool",
    features ? [ "config" "completions" ],
    repo ? "pleme-io/${name}",
  }: let
    hasFeature = f: builtins.elem f features;
    kebab = name;
    snake = builtins.replaceStrings ["-"] ["_"] name;

    # ====================================================================
    # File generators
    # ====================================================================

    cargoToml = ''
      [package]
      name = "${kebab}"
      version = "0.1.0"
      edition = "2024"
      rust-version = "1.89.0"
      license = "MIT"
      description = "${description}"

      [dependencies]
      clap = { version = "4", features = ["derive"] }
      serde = { version = "1", features = ["derive"] }
      serde_json = "1"
      tracing = "0.1"
      tracing-subscriber = { version = "0.3", features = ["env-filter"] }
    ''
    + lib.optionalString (hasFeature "config") ''
      shikumi = { git = "https://github.com/pleme-io/shikumi" }
    ''
    + lib.optionalString (hasFeature "completions") ''
      clap_complete = "4"
    ''
    + lib.optionalString (hasFeature "mcp") ''
      kaname = { git = "https://github.com/pleme-io/kaname" }
      rmcp = "0.15"
      tokio = { version = "1", features = ["full"] }
    ''
    + ''

      [profile.release]
      codegen-units = 1
      lto = true
      opt-level = "z"
      strip = true

      [lints.clippy]
      pedantic = "warn"
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
          (import "''${substrate}/lib/build/rust/tool-release-flake.nix" {
            inherit nixpkgs crate2nix flake-utils;
          }) {
            toolName = "${kebab}";
            src = self;
            repo = "${repo}";
          };
      }
    '';

    mainRs = if hasFeature "mcp" then ''
      mod cli;
      mod commands;
    '' + lib.optionalString (hasFeature "config") "mod config;\n" + ''

      use cli::Cli;
      use clap::Parser;

      #[tokio::main]
      async fn main() {
          tracing_subscriber::fmt::init();
          let cli = Cli::parse();
          commands::run(cli).await;
      }
    '' else ''
      mod cli;
      mod commands;
    '' + lib.optionalString (hasFeature "config") "mod config;\n" + ''

      use cli::Cli;
      use clap::Parser;

      fn main() {
          tracing_subscriber::fmt::init();
          let cli = Cli::parse();
          commands::run(cli);
      }
    '';

    libRs = ''
      pub mod cli;
      pub mod commands;
    ''
    + lib.optionalString (hasFeature "config") "pub mod config;\n";

    cliRs = ''
      use clap::{Parser, Subcommand};

      #[derive(Parser)]
      #[command(name = "${kebab}")]
      #[command(about = "${description}")]
      pub struct Cli {
          #[command(subcommand)]
          pub command: Commands,
      }

      #[derive(Subcommand)]
      pub enum Commands {
          /// Run the main operation
          Run,
          /// Show version information
          Version,
    ''
    + lib.optionalString (hasFeature "completions") ''
          /// Generate shell completions
          Completions {
              /// Shell to generate completions for
              #[arg(value_enum)]
              shell: clap_complete::Shell,
          },
    ''
    + lib.optionalString (hasFeature "mcp") ''
          /// Start MCP server
          Serve,
    ''
    + ''
      }
    '';

    commandsModRs = if hasFeature "mcp" then ''
      use crate::cli::{Cli, Commands};

      pub async fn run(cli: Cli) {
          match cli.command {
              Commands::Run => {
                  tracing::info!("running ${kebab}");
              }
              Commands::Version => {
                  println!("${kebab} {}", env!("CARGO_PKG_VERSION"));
              }
    ''
    + lib.optionalString (hasFeature "completions") ''
              Commands::Completions { shell } => {
                  use clap::CommandFactory;
                  clap_complete::generate(
                      shell,
                      &mut Cli::command(),
                      "${kebab}",
                      &mut std::io::stdout(),
                  );
              }
    ''
    + ''
              Commands::Serve => {
                  tracing::info!("starting MCP server");
              }
          }
      }
    '' else ''
      use crate::cli::{Cli, Commands};

      pub fn run(cli: Cli) {
          match cli.command {
              Commands::Run => {
                  tracing::info!("running ${kebab}");
              }
              Commands::Version => {
                  println!("${kebab} {}", env!("CARGO_PKG_VERSION"));
              }
    ''
    + lib.optionalString (hasFeature "completions") ''
              Commands::Completions { shell } => {
                  use clap::CommandFactory;
                  clap_complete::generate(
                      shell,
                      &mut Cli::command(),
                      "${kebab}",
                      &mut std::io::stdout(),
                  );
              }
    ''
    + ''
          }
      }
    '';

    configRs = ''
      use serde::Deserialize;

      #[derive(Debug, Clone, Deserialize)]
      pub struct Config {
          pub verbose: bool,
      }

      impl Default for Config {
          fn default() -> Self {
              Self { verbose: false }
          }
      }

      impl Config {
          pub fn load() -> Self {
              // Uses shikumi discovery: ~/.config/${kebab}/${kebab}.yaml
              Self::default()
          }
      }
    '';

  in {
    files = {
      "Cargo.toml" = cargoToml;
      "flake.nix" = flakeNix;
      ".gitignore" = "/target\n*.swp\n.DS_Store\n";
      "LICENSE" = "MIT License\n\nCopyright (c) 2026 pleme-io\n";
      "src/main.rs" = mainRs;
      "src/lib.rs" = libRs;
      "src/cli.rs" = cliRs;
      "src/commands/mod.rs" = commandsModRs;
    }
    // lib.optionalAttrs (hasFeature "config") {
      "src/config.rs" = configRs;
    };

    meta = {
      inherit name description repo features;
    };

    deployment = {
      inherit name;
      type = "cli-tool";
      targets = [ "aarch64-apple-darwin" "x86_64-apple-darwin" "x86_64-unknown-linux-musl" "aarch64-unknown-linux-musl" ];
    };
  };

  # ========================================================================
  # Predefined tool templates
  # ========================================================================

  templates = {
    minimal = {
      features = [];
    };

    standard = {
      features = [ "config" "completions" ];
    };

    mcp = {
      features = [ "config" "completions" "mcp" ];
    };
  };
}
