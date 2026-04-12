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
}
