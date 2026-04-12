# ============================================================================
# DIOXUS APP SCAFFOLD — Generate a complete Dioxus desktop/mobile app
# ============================================================================
# Creates the full project structure for a new Dioxus application
# with desktop and/or mobile targets, routing, sidebar, and theme.
#
# This implements the convergence computing principle: declare the desired
# state (app specification), and the scaffold converges it into existence.
#
# Usage:
#   scaffold = import "${substrate}/lib/build/rust/dioxus-app-scaffold.nix" { inherit lib; };
#   files = scaffold.generate ({
#     name = "my-app";
#   } // scaffold.templates.desktop);
{ lib }:

{
  # ========================================================================
  # generate — Produce the complete file tree for a new Dioxus app
  # ========================================================================
  generate = {
    name,
    description ? "A pleme-io desktop application",
    features ? [ "desktop" "config" ],
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
      dioxus = { version = "0.7", features = [
    ''
    + lib.optionalString (hasFeature "desktop") ''
          "desktop",
    ''
    + lib.optionalString (hasFeature "mobile") ''
          "mobile",
    ''
    + ''
      ] }
      serde = { version = "1", features = ["derive"] }
      serde_json = "1"
      tracing = "0.1"
      tracing-subscriber = { version = "0.3", features = ["env-filter"] }
    ''
    + lib.optionalString (hasFeature "hotkeys") ''
      awase = { git = "https://github.com/pleme-io/awase" }
    ''
    + lib.optionalString (hasFeature "config") ''
      shikumi = { git = "https://github.com/pleme-io/shikumi" }
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
      use dioxus::prelude::*;

      mod app;
      mod router;
      mod theme;
    ''
    + lib.optionalString (hasFeature "config") "mod config;\n"
    + lib.optionalString (hasFeature "hotkeys") "mod keybindings;\n"
    + ''
      mod components;

      fn main() {
          tracing_subscriber::fmt::init();
          dioxus::launch(app::${pascal}App);
      }
    '';

    appRs = ''
      use dioxus::prelude::*;
      use crate::router::AppRouter;

      #[component]
      pub fn ${pascal}App() -> Element {
          rsx! {
              AppRouter {}
          }
      }
    '';

    routerRs = ''
      use dioxus::prelude::*;

      #[derive(Clone, Routable, Debug, PartialEq)]
      pub enum Route {
          #[route("/")]
          Home {},
      }

      #[component]
      pub fn AppRouter() -> Element {
          rsx! {
              Router::<Route> {}
          }
      }

      #[component]
      fn Home() -> Element {
          rsx! {
              main {
                  h1 { "Welcome to ${pascal}" }
              }
          }
      }
    '';

    themeRs = ''
      /// Theme constants for ${pascal}.
      pub const PRIMARY: &str = "#88C0D0";
      pub const SECONDARY: &str = "#81A1C1";
      pub const BACKGROUND: &str = "#2E3440";
      pub const SURFACE: &str = "#3B4252";
      pub const TEXT: &str = "#ECEFF4";
    '';

    componentsModRs = ''
      pub mod sidebar;
    '';

    componentsSidebarRs = ''
      use dioxus::prelude::*;

      #[derive(Props, Clone, PartialEq)]
      pub struct NavItem {
          pub label: String,
          pub href: String,
      }

      #[component]
      pub fn Sidebar() -> Element {
          let items = vec![
              NavItem { label: "Home".to_string(), href: "/".to_string() },
          ];

          rsx! {
              nav {
                  class: "sidebar",
                  ul {
                      for item in items {
                          li {
                              a { href: "{item.href}", "{item.label}" }
                          }
                      }
                  }
              }
          }
      }
    '';

    configRs = ''
      use serde::Deserialize;

      #[derive(Debug, Clone, Deserialize)]
      pub struct Config {
          pub window_width: u32,
          pub window_height: u32,
      }

      impl Default for Config {
          fn default() -> Self {
              Self {
                  window_width: 1280,
                  window_height: 720,
              }
          }
      }
    '';

    keybindingsRs = ''
      /// Keybinding definitions for ${pascal}.
      pub const QUIT: &str = "Cmd+Q";
      pub const FIND: &str = "Cmd+F";
    '';

  in {
    files = {
      "Cargo.toml" = cargoToml;
      "flake.nix" = flakeNix;
      ".gitignore" = "/target\n*.swp\n.DS_Store\n";
      "LICENSE" = "MIT License\n\nCopyright (c) 2026 pleme-io\n";
      "src/main.rs" = mainRs;
      "src/app.rs" = appRs;
      "src/router.rs" = routerRs;
      "src/theme.rs" = themeRs;
      "src/components/mod.rs" = componentsModRs;
      "src/components/sidebar.rs" = componentsSidebarRs;
    }
    // lib.optionalAttrs (hasFeature "config") {
      "src/config.rs" = configRs;
    }
    // lib.optionalAttrs (hasFeature "hotkeys") {
      "src/keybindings.rs" = keybindingsRs;
    };

    meta = {
      inherit name description repo features;
    };

    deployment = {
      inherit name;
      type = "desktop-app";
      platforms = (lib.optional (hasFeature "desktop") "desktop")
                ++ (lib.optional (hasFeature "mobile") "mobile");
    };
  };

  # ========================================================================
  # Predefined app templates
  # ========================================================================

  templates = {
    desktop = {
      features = [ "desktop" "config" ];
    };

    mobile = {
      features = [ "mobile" "config" ];
    };

    full = {
      features = [ "desktop" "mobile" "hotkeys" "config" ];
    };
  };
}
