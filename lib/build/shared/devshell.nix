# Shared Development Shell Factory
#
# Typed factory for creating development shells across all languages.
# Reduces the 6+ devShell construction patterns to a single entry point
# with language-specific tool presets.
#
# Depends on: pkgs
#
# Usage:
#   shared = import ./devshell.nix { inherit pkgs; };
#   shell = shared.mkTypedDevShell {
#     name = "auth-service";
#     tools = [ pkgs.cargo pkgs.rustc ];
#     env = { RUST_LOG = "debug"; DATABASE_URL = "postgres://localhost/auth"; };
#   };
{ pkgs }:

let
  inherit (pkgs) lib;
  darwinHelper = import ../../util/darwin.nix;
in rec {
  # ── Universal DevShell Builder ────────────────────────────────────
  # Creates a mkShellNoCC with:
  # - Named tool packages
  # - Environment variables
  # - Shell hook
  # - Darwin SDK deps (automatically added on macOS)
  mkTypedDevShell = {
    name,
    tools ? [],
    buildInputs ? [],
    env ? {},
    shellHook ? "",
    extraPackages ? [],
  }: let
    darwinInputs = darwinHelper.mkDarwinBuildInputs pkgs;
    envHook = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") env
    );
  in pkgs.mkShellNoCC {
    inherit name;
    buildInputs = tools ++ buildInputs ++ extraPackages ++ darwinInputs;
    shellHook = ''
      ${envHook}
      ${shellHook}
    '';
  };

  # ── Language-Specific Presets ──────────────────────────────────────
  # Pre-configured tool sets for common languages. Compose with
  # mkTypedDevShell by spreading into the tools parameter.

  rustTools = with pkgs; [
    (pkgs.fenixRustToolchain or pkgs.rustc)
    (pkgs.fenixCargo or pkgs.cargo)
    rust-analyzer
    cargo-watch
    pkg-config
    openssl
    protobuf
  ];

  goTools = with pkgs; [
    go
    gopls
    gotools
    go-tools
  ];

  goGrpcTools = with pkgs; [
    protobuf
    protoc-gen-go
    protoc-gen-go-grpc
    grpcurl
    buf
  ];

  typescriptTools = with pkgs; [
    nodejs_22
    nodePackages.npm
    nodePackages.typescript
    nodePackages.typescript-language-server
  ];

  pythonTools = with pkgs; [
    python3
    uv
  ];

  zigTools = with pkgs; [
    (pkgs.zigToolchain or pkgs.zig)
    (pkgs.zlsPackage or pkgs.zls)
  ];

  webTools = with pkgs; [
    nodejs_22
    nodePackages.npm
    nodePackages.pnpm
    nodePackages.typescript
  ];

  # ── Rust Service DevShell ─────────────────────────────────────────
  # Specialized preset for Rust services with DB + proto support.
  mkRustServiceDevShell = { name, extraTools ? [], env ? {}, shellHook ? "" }:
    mkTypedDevShell {
      inherit name shellHook;
      tools = rustTools ++ (with pkgs; [
        postgresql
        sqlx-cli
        cmake
        perl
      ]) ++ extraTools;
      env = {
        RUST_LOG = "info";
        RUST_BACKTRACE = "1";
        DATABASE_URL = "postgres://localhost:5432/${name}";
      } // env;
    };

  # ── Go gRPC DevShell ──────────────────────────────────────────────
  mkGoGrpcDevShell = { name, extraTools ? [], env ? {}, shellHook ? "" }:
    mkTypedDevShell {
      inherit name shellHook;
      tools = goTools ++ goGrpcTools ++ extraTools;
      inherit env;
    };

  # ── Rust DevShell (CC-enabled, devenv-aware) ──────────────────────
  # Shared factory for the Rust builders (tool-release, workspace-release,
  # library, service, tool-image). Uses `pkgs.mkShell` (not mkShellNoCC) —
  # Rust `-sys` crates (openssl-sys, ring, …) need the C toolchain on PATH.
  #
  # Automatically injects Darwin SDK on macOS. When a devenv input is
  # passed, delegates to `devenv.lib.mkShell` with an optional per-kind
  # devenv module (../devenv/rust-tool.nix, rust-library.nix, rust-service.nix).
  #
  # Args:
  #   pkgs:              target pkgs (may include fenix overlay)
  #   devenv:            optional devenv flake input (null = plain mkShell)
  #   nixpkgs:           required only when devenv != null
  #   devenvModule:      path to devenv module (optional)
  #   tools:             toolchain + dev tools — NON-DEVENV path only
  #                      (devenv expects toolchain via its module)
  #   buildInputs:       C/system libs — NON-DEVENV path only
  #   nativeBuildInputs: native build inputs — NON-DEVENV path only
  #   extraPackages:     extras included in BOTH paths (e.g. crate2nix)
  #   env:               environment variables for both paths
  mkRustDevShell = {
    pkgs,
    devenv ? null,
    nixpkgs ? null,
    devenvModule ? null,
    tools ? [],
    buildInputs ? [],
    nativeBuildInputs ? [],
    extraPackages ? [],
    env ? {},
  }: let
    darwinInputs = darwinHelper.mkDarwinBuildInputs pkgs;
  in
    if devenv != null then
      assert (nixpkgs != null) || (throw "mkRustDevShell: nixpkgs is required when devenv is non-null");
      devenv.lib.mkShell {
        inputs = { inherit nixpkgs devenv; };
        inherit pkgs;
        modules = (if devenvModule != null then [ (import devenvModule) ] else [])
          ++ [ ({ lib, ... }: {
            env = builtins.mapAttrs (_: v: lib.mkDefault v) env;
            packages = extraPackages;
          }) ];
      }
    else
      pkgs.mkShell ({
        buildInputs = tools ++ buildInputs ++ extraPackages ++ darwinInputs;
        inherit nativeBuildInputs;
      } // env);
}
