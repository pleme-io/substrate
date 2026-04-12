# ============================================================================
# GPU APP SCAFFOLD — Generate a complete garasu+egaku+madori GPU application
# ============================================================================
# Creates the full project structure for a new GPU-rendered application
# using the pleme-io GPU stack: garasu (GPU primitives), egaku (widgets),
# madori (app framework), irodzuki (GPU theming), shikumi (config).
#
# This implements the convergence computing principle: declare the desired
# state (app specification), and the scaffold converges it into existence.
#
# Usage:
#   scaffold = import "${substrate}/lib/build/rust/gpu-app-scaffold.nix" { inherit lib; };
#   files = scaffold.generate ({
#     name = "my-gpu-app";
#   } // scaffold.templates.minimal);
{ lib }:

{
  # ========================================================================
  # generate — Produce the complete file tree for a new GPU app
  # ========================================================================
  generate = {
    name,
    description ? "A pleme-io GPU application",
    features ? [ "text" "config" ],
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

    cargoToml = ''
      [package]
      name = "${kebab}"
      version = "0.1.0"
      edition = "2024"
      rust-version = "1.89.0"
      license = "MIT"
      description = "${description}"

      [dependencies]
      garasu = { git = "https://github.com/pleme-io/garasu" }
      egaku = { git = "https://github.com/pleme-io/egaku" }
      madori = { git = "https://github.com/pleme-io/madori" }
      irodzuki = { git = "https://github.com/pleme-io/irodzuki" }
      shikumi = { git = "https://github.com/pleme-io/shikumi" }
      wgpu = "25"
      winit = "0.30"
      tracing = "0.1"
      tracing-subscriber = { version = "0.3", features = ["env-filter"] }
      serde = { version = "1", features = ["derive"] }
      serde_json = "1"
    ''
    + lib.optionalString (hasFeature "clipboard") ''
      hasami = { git = "https://github.com/pleme-io/hasami" }
    ''
    + lib.optionalString (hasFeature "audio") ''
      oto = { git = "https://github.com/pleme-io/oto" }
    ''
    + lib.optionalString (hasFeature "scripting") ''
      soushi = { git = "https://github.com/pleme-io/soushi" }
    ''
    + lib.optionalString (hasFeature "mcp") ''
      kaname = { git = "https://github.com/pleme-io/kaname" }
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
          flake-utils.lib.eachDefaultSystem (system: let
            pkgs = import nixpkgs { inherit system; };
          in {
            packages.default = pkgs.rustPlatform.buildRustPackage {
              pname = "${kebab}";
              version = "0.1.0";
              src = self;
              cargoLock.lockFile = ./Cargo.lock;
            };
            devShells.default = pkgs.mkShellNoCC {
              packages = with pkgs; [ rustc cargo rust-analyzer clippy ];
            };
          });
      }
    '';

    mainRs = ''
      use tracing_subscriber;

      mod app;
      mod render;
      mod theme;
    ''
    + lib.optionalString (hasFeature "config") "mod config;\n"
    + ''

      fn main() {
          tracing_subscriber::fmt::init();
          tracing::info!("starting ${pascal}");
          madori::App::builder()
              .title("${pascal}")
              .size(1280, 720)
              .on_render(render::render)
              .run();
      }
    '';

    libRs = ''
      pub mod app;
      pub mod render;
      pub mod theme;
    ''
    + lib.optionalString (hasFeature "config") "pub mod config;\n";

    appRs = ''
      /// Application state for ${pascal}.
      pub struct AppState {
          pub running: bool,
      }

      impl AppState {
          pub fn new() -> Self {
              Self { running: true }
          }
      }

      impl Default for AppState {
          fn default() -> Self {
              Self::new()
          }
      }
    '';

    renderRs = ''
      /// Render callback for ${pascal}.
      /// Implements the madori RenderCallback interface.
      pub fn render() {
          // GPU rendering logic using garasu + egaku
          tracing::trace!("render frame");
      }
    '';

    themeRs = ''
      /// Theme configuration using irodzuki color schemes.
      /// Loads a Base16 color scheme and converts to GPU uniforms.
      pub fn load_theme() {
          // irodzuki::ColorScheme::from_base16(...)
          tracing::info!("loading theme");
      }
    '';

    configRs = ''
      use serde::Deserialize;

      /// Configuration for ${pascal}.
      /// Loaded via shikumi discovery: ~/.config/${kebab}/${kebab}.yaml
      #[derive(Debug, Clone, Deserialize)]
      pub struct Config {
          pub window_width: u32,
          pub window_height: u32,
          pub font_size: f32,
      }

      impl Default for Config {
          fn default() -> Self {
              Self {
                  window_width: 1280,
                  window_height: 720,
                  font_size: 14.0,
              }
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
      "src/app.rs" = appRs;
      "src/render.rs" = renderRs;
      "src/theme.rs" = themeRs;
    }
    // lib.optionalAttrs (hasFeature "config") {
      "src/config.rs" = configRs;
    };

    meta = {
      inherit name description repo features;
    };

    deployment = {
      inherit name;
      type = "desktop-app";
      gpu = true;
    };
  };

  # ========================================================================
  # Predefined app templates
  # ========================================================================

  templates = {
    minimal = {
      features = [ "text" "config" ];
    };

    editor = {
      features = [ "text" "config" "clipboard" ];
    };

    media = {
      features = [ "text" "config" "audio" ];
    };

    full = {
      features = [ "text" "shaders" "config" "scripting" "clipboard" "audio" "mcp" ];
    };
  };
}
