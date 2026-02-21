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
}: let
  # ============================================================================
  # CROSS-PLATFORM BUILD ARCHITECTURE
  # ============================================================================
  # CRITICAL: This follows the hard rule: NEVER call nix from tools invoked by Nix apps
  #
  # Architecture:
  #   1. Packages are ALWAYS defined for their target platforms (x86_64-linux, aarch64-linux)
  #   2. Apps call `nix build --system x86_64-linux .#dockerImage` DIRECTLY
  #   3. Nix's remote builders (/etc/nix/machines) handle cross-compilation transparently
  #   4. Tools like forge handle push/deploy but NEVER call nix build
  #
  # This avoids the nix→shell→nix anti-pattern that causes:
  #   - "Exec format error" on Darwin
  #   - "attribute does not exist" evaluation failures
  #   - Circular dependency issues

  # Native pkgs with Rust overlay
  pkgs = import nixpkgs {
    inherit system;
    overlays = [ nixLib.overlays.${system}.rust ];
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
  ports ? {
    graphql = 8080;
    health = 8081;
    metrics = 9090;
  },
  productName ? null,  # Product identifier — null for standalone repos
  registryBase ? null,  # Registry base URL — null when registry is set
  registry ? null,  # Explicit registry override (e.g., "ghcr.io/pleme-io/shinka")
  packageName ? (if productName != null then "${serviceName}-service" else serviceName),  # Crate name
  namespace ? (if productName != null then "${productName}-staging" else "${serviceName}-system"),
  serviceDirRelative ? (if productName != null then "services/rust/${serviceName}" else "."),
  cluster ? "staging",  # Target cluster for deployment
  architectures ? ["amd64" "arm64"],  # Supported architectures: amd64, arm64
}: let
  # Service lib - uses native pkgs
  serviceLib = import ./default.nix {
    inherit pkgs system crate2nix forge;
  };

  # Build inputs
  defaultBuildInputs = with pkgs; [openssl postgresql sqlite];
  allBuildInputs = defaultBuildInputs ++ buildInputs;
  defaultNativeBuildInputs = with pkgs; [pkg-config cmake perl];
  allNativeBuildInputs = defaultNativeBuildInputs ++ nativeBuildInputs;

  # Build Docker images for requested architectures
  # These are defined based on the architectures parameter
  # When called with --system x86_64-linux, Nix uses remote builders transparently
  # This is the correct pattern - no platform-specific conditionals in packages

  # Helper to check if architecture is enabled
  hasArch = arch: builtins.elem arch architectures;

  dockerImage-amd64 = if hasArch "amd64" then serviceLib.mkCrate2nixDockerImage {
    inherit serviceName src cargoNix migrationsPath ports enableAwsSdk packageName;
    buildInputs = allBuildInputs;
    nativeBuildInputs = allNativeBuildInputs;
    architecture = "amd64";
  } else null;

  dockerImage-arm64 = if hasArch "arm64" then serviceLib.mkCrate2nixDockerImage {
    inherit serviceName src cargoNix migrationsPath ports enableAwsSdk packageName;
    buildInputs = allBuildInputs;
    nativeBuildInputs = allNativeBuildInputs;
    architecture = "arm64";
  } else null;

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
  devShells.default = pkgs.mkShell ({
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
