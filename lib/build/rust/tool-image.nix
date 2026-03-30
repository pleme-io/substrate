# ============================================================================
# RUST TOOL IMAGE BUILDER - Docker images for CLI tools (CronJobs, init containers)
# ============================================================================
# Builds a Rust CLI tool and packages it in a minimal Docker image.
# Designed for K8s CronJobs, init containers, sidecar tasks, and one-shot jobs.
#
# Compared to rust-service.nix:
#   - No ports, GraphQL, REST, health endpoints, or migrations
#   - Supports extraContents for runtime tools (crane, kubectl, etc.)
#   - Simpler image config (Entrypoint only, no ExposedPorts)
#
# Compared to rust-tool-release.nix:
#   - Produces Docker images instead of GitHub releases
#   - Only targets Linux (amd64, arm64) for container images
#   - Native binary still available for local dev/testing
#
# Usage:
#   let rustToolImage = import "${substrate}/lib/build/rust/tool-image.nix" {
#     inherit system nixpkgs crate2nix;
#   };
#   in rustToolImage {
#     toolName = "image-sync";
#     src = self;
#     repo = "pleme-io/image-sync";
#     extraContents = pkgs: [ pkgs.crane ];
#   }
#
# Returns: { packages, devShells, apps }
{
  nixpkgs,
  system,
  crate2nix,
  fenix ? null,
  devenv ? null,
  forge ? null,
}: let
  darwinHelpers = import ../../util/darwin.nix;
  dockerHelpers = import ../../util/docker-helpers.nix;
  rustOverlay = import ./overlay.nix;

  # Host pkgs — used for devShell, apps, and native builds
  hostOverlays = if fenix != null
    then [ (rustOverlay.mkRustOverlay { inherit fenix system; }) ]
    else [];
  hostPkgs = import nixpkgs {
    inherit system;
    overlays = hostOverlays;
  };
in {
  toolName,
  src,
  repo,
  cargoNix ? src + "/Cargo.nix",
  buildInputs ? [],
  nativeBuildInputs ? [],
  crateOverrides ? {},
  # Function: targetPkgs -> [packages] to include in Docker image at runtime
  # Example: pkgs: [ pkgs.crane pkgs.kubectl ]
  extraContents ? (_pkgs: []),
  # Which architectures to build Docker images for
  architectures ? ["amd64" "arm64"],
  # Docker image tag
  tag ? "latest",
  # Container user (default: nobody)
  user ? "65534:65534",
  # Extra environment variables for the container
  env ? [],
  # For workspace crates: the member name in Cargo.toml
  packageName ? null,
  ...
}:
let
  effectivePackageName = if packageName != null then packageName else toolName;
  hasArch = arch: builtins.elem arch architectures;

  # ============================================================================
  # DOCKER IMAGE BUILDER
  # ============================================================================
  # Builds a minimal Docker image for a specific Linux architecture.
  # On macOS, Nix delegates to remote builders transparently.
  mkImage = arch: let
    targetSystem = if arch == "arm64" then "aarch64-linux" else "x86_64-linux";
    targetPkgs = import nixpkgs { system = targetSystem; };

    crate2nixTools = import "${crate2nix}/tools.nix" { pkgs = targetPkgs; };
    generatedCargoNix = if builtins.pathExists cargoNix
      then cargoNix
      else crate2nixTools.generatedCargoNix { name = effectivePackageName; inherit src; };

    project = import generatedCargoNix {
      pkgs = targetPkgs;
      defaultCrateOverrides = targetPkgs.defaultCrateOverrides // {
        ${effectivePackageName} = attrs: {
          buildInputs = (attrs.buildInputs or []) ++ buildInputs;
          nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ nativeBuildInputs;
        };
      } // crateOverrides;
    };

    binary = if project ? workspaceMembers
      then project.workspaceMembers.${effectivePackageName}.build
      else project.rootCrate.build;

    extras = extraContents targetPkgs;
  in targetPkgs.dockerTools.buildLayeredImage {
    name = toolName;
    inherit tag;
    architecture = arch;
    contents = [ targetPkgs.cacert binary ] ++ extras;
    config = {
      Entrypoint = [ "${binary}/bin/${toolName}" ];
      Env = [
        (dockerHelpers.mkSslEnv targetPkgs)
        "RUST_LOG=info"
      ] ++ env;
      WorkingDir = "/";
      User = user;
    };
  };

  images = {}
    // (if hasArch "amd64" then { dockerImage-amd64 = mkImage "amd64"; } else {})
    // (if hasArch "arm64" then { dockerImage-arm64 = mkImage "arm64"; } else {});

  # ============================================================================
  # NATIVE BINARY (for local dev/testing on host system)
  # ============================================================================
  nativeCrate2nixTools = import "${crate2nix}/tools.nix" { pkgs = hostPkgs; };
  nativeCargoNix = if builtins.pathExists cargoNix
    then cargoNix
    else nativeCrate2nixTools.generatedCargoNix { name = effectivePackageName; inherit src; };

  nativeProject = import nativeCargoNix {
    pkgs = hostPkgs;
    defaultCrateOverrides = hostPkgs.defaultCrateOverrides // {
      ${effectivePackageName} = attrs: {
        buildInputs = (attrs.buildInputs or [])
          ++ buildInputs
          ++ (darwinHelpers.mkDarwinBuildInputs hostPkgs);
        nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ nativeBuildInputs;
      };
    } // crateOverrides;
  };

  nativeBinary = if nativeProject ? workspaceMembers
    then nativeProject.workspaceMembers.${effectivePackageName}.build
    else nativeProject.rootCrate.build;

  # Wrap native binary with runtime deps on PATH (matches Docker image contents)
  runtimeDeps = extraContents hostPkgs;
  wrappedNative = if runtimeDeps == [] then nativeBinary
    else hostPkgs.runCommand "${toolName}-wrapped" {
      nativeBuildInputs = [ hostPkgs.makeWrapper ];
      meta.mainProgram = toolName;
    } ''
      mkdir -p $out/bin
      cp -r ${nativeBinary}/bin/* $out/bin/
      wrapProgram $out/bin/${toolName} --prefix PATH : ${hostPkgs.lib.makeBinPath runtimeDeps}
    '';

  # ============================================================================
  # DEV TOOLS
  # ============================================================================
  devTools = if fenix != null then [
    hostPkgs.fenixRustToolchain
  ] else (with hostPkgs; [ cargo rustc clippy rustfmt ]);

  # ============================================================================
  # PUSH APPS
  # ============================================================================
  mkPushApp = archName: {
    type = "app";
    program = toString (hostPkgs.writeShellScript "${toolName}-push-${archName}" ''
      set -euo pipefail
      IMAGE_TAR=$(nix build --no-link --print-out-paths .#dockerImage-${archName})
      REGISTRY="ghcr.io/${repo}"
      echo "Loading ${archName} image..."
      docker load < "$IMAGE_TAR"
      docker tag "${toolName}:${tag}" "$REGISTRY:${tag}"
      docker tag "${toolName}:${tag}" "$REGISTRY:latest"
      echo "Pushing to $REGISTRY..."
      docker push "$REGISTRY:${tag}"
      docker push "$REGISTRY:latest"
      echo "Published $REGISTRY:${tag}"
    '');
  };

in {
  packages = images // {
    default = wrappedNative;
    ${toolName} = wrappedNative;
  };

  devShells.default = if devenv != null then
    devenv.lib.mkShell {
      inputs = { inherit nixpkgs; inherit devenv; };
      pkgs = hostPkgs;
      modules = [
        (import ../../devenv/rust-tool.nix)
        ({ ... }: {
          packages = [ crate2nix ] ++ buildInputs ++ runtimeDeps;
        })
      ];
    }
  else
    hostPkgs.mkShell {
      buildInputs = devTools ++ [
        hostPkgs.rust-analyzer
        crate2nix
      ] ++ buildInputs
        ++ runtimeDeps
        ++ (darwinHelpers.mkDarwinBuildInputs hostPkgs);
    };

  apps = {
    default = {
      type = "app";
      program = "${wrappedNative}/bin/${toolName}";
    };

    regenerate-cargo-nix = {
      type = "app";
      program = toString (hostPkgs.writeShellScript "${toolName}-regenerate-cargo-nix" ''
        set -euo pipefail
        ${crate2nix}/bin/crate2nix generate
      '');
    };
  }
  // (if hasArch "amd64" then { push-amd64 = mkPushApp "amd64"; } else {})
  // (if hasArch "arm64" then { push-arm64 = mkPushApp "arm64"; } else {});
}
