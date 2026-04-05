# WASI Overlay - Fenix stable toolchain with wasm32-wasip2 target + WASI tools
#
# Provides a Nix overlay that adds:
#   wasiRustToolchain: fenix stable (cargo, rustc) + wasm32-wasip2 rust-std
#   wasiTools: { wasmtime, wasm-tools, wasmer } from nixpkgs
#
# Usage:
#   pkgs = import nixpkgs {
#     inherit system;
#     overlays = [ (import "${substrate}/lib/wasi-overlay.nix" { inherit fenix; }) ];
#   };
#   # Then: pkgs.wasiRustToolchain, pkgs.wasiTools.wasmtime, etc.
{ fenix }:
final: prev: {
  wasiRustToolchain = fenix.combine [
    fenix.stable.cargo
    fenix.stable.rustc
    fenix.targets.wasm32-wasip2.stable.rust-std
  ];
  wasiTools = {
    wasmtime = prev.wasmtime;
    wasm-tools = prev.wasm-tools;
    wasmer = prev.wasmer;
  };
}
