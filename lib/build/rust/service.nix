# ============================================================================
# RUST SERVICE BUILDER - High-Level Abstraction
# ============================================================================
# Eliminates 95% of boilerplate from service flake.nix files
#
# Usage in service flake.nix:
#   let rustService = import "${substrate}/lib/rust-service.nix" {
#     inherit system nixpkgs;
#     nixLib = substrate;
#     crate2nix = inputs.crate2nix;
#     forge = inputs.forge.packages.${system}.forge;
#   };
#   in rustService {
#     serviceName = "email";
#     src = ./.;
#     enableAwsSdk = true;
#   }
#
# This returns complete flake outputs: packages, devShells, apps
{
  nixpkgs,
  system,  # Host platform (where commands run: aarch64-darwin, x86_64-linux, etc.)
  nixLib,
  crate2nix,
  forge,
  nixHooks ? null,  # Optional: Nix hooks package for post-build-hook support
  devenv ? null,    # Optional: devenv flake input for enhanced dev shells
}: let
  # ============================================================================
  # CROSS-PLATFORM BUILD ARCHITECTURE
  # ============================================================================
  # Docker images are built with Linux-targeted pkgs (x86_64-linux, aarch64-linux)
  # regardless of the host platform. On macOS, Nix delegates realization to remote
  # builders (nix-rosetta-builder or /etc/nix/machines) transparently.
  #
  # Architecture:
  #   1. Host pkgs (aarch64-darwin etc.) are used for devShells, apps, CLI tools
  #   2. Docker images use targetPkgs imported with the target Linux system
  #   3. buildRustCrate with Linux pkgs targets the correct rustcTarget (ELF binary)
  #   4. dockerTools.buildLayeredImage with Linux pkgs creates correct Linux images
  #   5. Pre-evaluated image derivations in release apps are always Linux derivations
  #
  # This fixes the "exec format error" caused by embedding Darwin binaries in
  # Docker images labeled as amd64.

  # Native pkgs with Rust overlay
  pkgs = import nixpkgs {
    inherit system;
    overlays = [ nixLib.rustOverlays.${system}.rust ];
  };
in {
  serviceName,
  src,
  description ? "${serviceName} Service with crate2nix",
  buildInputs ? [],
  nativeBuildInputs ? [],
  enableAwsSdk ? false,
  extraDevInputs ? [],
  devEnvVars ? {},
  repoRoot ? src,  # Repository root (for monorepo: pass the repo root, not the service dir)
  migrationsPath ? src + "/migrations",
  cargoNix ? src + "/Cargo.nix",
  # Service type: "graphql" (default) or "rest" — controls port naming and env vars in Docker image
  serviceType ? "graphql",
  ports ? (if serviceType == "rest" then {
    http = 8080;
    health = 8081;
    metrics = 9090;
  } else {
    graphql = 8080;
    health = 8081;
    metrics = 9090;
  }),
  productName ? null,  # Product identifier — null for standalone repos
  registryBase ? null,  # Registry base URL — null when registry is set
  registry ? null,  # Explicit registry override (e.g., "ghcr.io/pleme-io/shinka")
  packageName ? (if productName != null then "${serviceName}-service" else serviceName),  # Crate name
  namespace ? (if productName != null then "${productName}-staging" else "${serviceName}-system"),
  serviceDirRelative ? (if productName != null then "services/rust/${serviceName}" else "."),
  cluster ? "staging",  # Target cluster for deployment
  architectures ? ["amd64" "arm64"],  # Supported architectures: amd64, arm64
}: let
  # Service lib - uses native (host) pkgs for apps, devShells, etc.
  serviceLib = import ../../default.nix {
    inherit pkgs system crate2nix forge;
  };

  # Build inputs (host pkgs — for devShell and host-side tools)
  defaultBuildInputs = with pkgs; [openssl postgresql sqlite];
  allBuildInputs = defaultBuildInputs ++ buildInputs;
  defaultNativeBuildInputs = with pkgs; [pkg-config cmake perl];
  allNativeBuildInputs = defaultNativeBuildInputs ++ nativeBuildInputs;

  # Helper to check if architecture is enabled
  hasArch = arch: builtins.elem arch architectures;

  # Docker images MUST contain Linux ELF binaries, not host-platform binaries.
  # On non-Linux hosts (macOS), Nix delegates building to remote builders
  # (nix-rosetta-builder or configured Linux builders in /etc/nix/machines).
  mkDockerImage = arch: let
    targetSystem = if arch == "arm64" then "aarch64-linux" else "x86_64-linux";
    targetPkgs = import nixpkgs {
      system = targetSystem;
      overlays = [ nixLib.rustOverlays.${targetSystem}.rust ];
    };
    builders = import ./crate2nix-builders.nix { pkgs = targetPkgs; inherit crate2nix; };
  in builders.mkCrate2nixDockerImage {
    inherit serviceName src cargoNix migrationsPath ports enableAwsSdk packageName serviceType;
    buildInputs = (with targetPkgs; [openssl postgresql sqlite]) ++ buildInputs;
    nativeBuildInputs = (with targetPkgs; [pkg-config cmake perl]) ++ nativeBuildInputs;
    architecture = arch;
  };

  dockerImage-amd64 = if hasArch "amd64" then mkDockerImage "amd64" else null;
  dockerImage-arm64 = if hasArch "arm64" then mkDockerImage "arm64" else null;

  # Standard development environment variables
  # Automatically derives database name and user from serviceName
  defaultDevEnvVars = {
    RUST_SRC_PATH = "${pkgs.fenixRustToolchain}/lib/rustlib/src/rust/library";
    DATABASE_URL = "postgresql://${serviceName}_test:test_password@localhost:5432/${serviceName}_test";
    REDIS_URL = "redis://localhost:6379";
    RUST_LOG = "info,${serviceName}=debug";
    # Required for tonic-build/prost-build proto compilation
    PROTOC = "${pkgs.protobuf}/bin/protoc";
  };

  allDevEnvVars = defaultDevEnvVars // devEnvVars;

  # Standard development tools for Rust
  # Use fenix toolchain (1.90+) for cargo/rustc/clippy/rustfmt to match MSRV
  # of our dependencies (async-graphql, darling, etc. require 1.88+)
  devTools = [
    pkgs.fenixRustToolchain  # cargo, rustc, clippy, rustfmt, rust-src
    pkgs.rust-analyzer
    pkgs.cargo-watch
    pkgs.protobuf  # Required for tonic-build/prost-build (gRPC proto compilation)
  ];
in {
  # Package outputs - Docker images
  # Only defined for requested architectures
  # Apps use `nix build --system x86_64-linux .#dockerImage-amd64` to build for target platform
  # Nix's remote builder support (configured in /etc/nix/machines) handles cross-compilation
  packages =
    (if dockerImage-amd64 != null then { inherit dockerImage-amd64; } else {}) //
    (if dockerImage-arm64 != null then { inherit dockerImage-arm64; } else {}) //
    { default = if dockerImage-amd64 != null then dockerImage-amd64 else dockerImage-arm64; };

  # Development shell with all dependencies
  devShells.default = if devenv != null then
    devenv.lib.mkShell {
      inputs = { inherit nixpkgs; inherit devenv; };
      inherit pkgs;
      modules = [
        (import ../../devenv/rust-service.nix)
        ({ lib, ... }: {
          env = builtins.mapAttrs (_: v: lib.mkDefault v) allDevEnvVars;
          packages = extraDevInputs ++ [ crate2nix ];
        })
      ];
    }
  else
    pkgs.mkShell ({
      buildInputs = allBuildInputs ++ devTools ++ extraDevInputs ++ [ crate2nix ];
      nativeBuildInputs = allNativeBuildInputs;
    }
    // allDevEnvVars);

  # Apps for build, push, deploy, release workflows
  # Apps call `nix build --system x86_64-linux` directly (no nix→shell→nix pattern)
  # Remote builders configured in /etc/nix/machines handle cross-compilation transparently
  apps = serviceLib.mkCrate2nixServiceApps {
    inherit serviceName src repoRoot productName namespace cluster registryBase registry serviceDirRelative crate2nix dockerImage-amd64 dockerImage-arm64 architectures nixHooks;
    forge = forge;
  } // {
    # Add rust-version app for easy version verification
    rust-version = {
      type = "app";
      program = toString (pkgs.writeShellScript "rust-version" ''
        echo "Rust version for ${serviceName} service:"
        ${(pkgs.fenixRustc or pkgs.rustc)}/bin/rustc --version
      '');
    };

    # Generate Cargo.nix for crate2nix builds
    generateCargoNix = {
      type = "app";
      program = toString (pkgs.writeShellScript "generate-cargo-nix" ''
        echo "🔨 Generating Cargo.nix for ${serviceName}..."
        ${crate2nix}/bin/crate2nix generate
        echo "✅ Cargo.nix generated successfully!"
        echo ""
        echo "Don't forget to commit it:"
        echo "  git add Cargo.nix"
        echo "  git commit -m 'chore: regenerate Cargo.nix for ${serviceName}'"
      '');
    };

    # Alias for generateCargoNix
    regenerate-cargo-nix = {
      type = "app";
      program = toString (pkgs.writeShellScript "regenerate-cargo-nix" ''
        echo "🔨 Regenerating Cargo.nix for ${serviceName}..."
        ${crate2nix}/bin/crate2nix generate
        echo "✅ Cargo.nix regenerated successfully!"
        echo ""
        echo "Don't forget to commit it:"
        echo "  git add Cargo.nix"
        echo "  git commit -m 'chore: regenerate Cargo.nix for ${serviceName}'"
      '');
    };
  };
}
