# Devenv module for Leptos web application development.
#
# Provides: Rust stable toolchain with WASM target, cargo-leptos, trunk,
# wasm-bindgen, wasm-opt, Tailwind CSS, Node.js (for @material/web and
# MUI island JS), and Darwin SDK deps.
#
# Extends the base Rust devenv module with WASM-specific tooling.
#
# Usage (in a devenv shell definition):
#   imports = [ "${substrate}/lib/devenv/leptos.nix" ];
{ pkgs, lib, ... }: {
  imports = [ ./rust.nix ];

  languages.rust.targets = [ "wasm32-unknown-unknown" ];

  packages = with pkgs; [
    # WASM build tooling
    wasm-bindgen-cli
    binaryen
    trunk
    wasm-tools

    # Frontend tooling
    tailwindcss
    nodePackages.npm
    nodejs_22

    # Development
    cargo-watch
  ];

  env = {
    # Leptos dev server defaults
    LEPTOS_SITE_ADDR = lib.mkDefault "127.0.0.1:3000";
    LEPTOS_SITE_ROOT = lib.mkDefault "static";
  };
}
