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
#     forge = forge.packages.${system}.default;  # for `nix run .#release`
#   };
#   in rustToolImage {
#     toolName = "image-sync";
#     src = self;
#     repo = "pleme-io/image-sync";
#     extraContents = pkgs: [ pkgs.crane ];
#   }
#
# Apps:
#   nix run .#release  — push all arch images to ghcr.io/${repo} via forge
#
# Returns: { packages, devShells, apps }
{
  nixpkgs,
  system,
  # crate2nix is only needed for the (default) crate2nix build path. The
  # gen path (genBuild = true) drives lockfile-builder instead and leaves
  # crate2nix null.
  crate2nix ? null,
  fenix ? null,
  devenv ? null,
  forge ? null,
}: let
  darwinHelpers = import ../../util/darwin.nix;
  dockerHelpers = import ../../util/docker-helpers.nix;
  rustOverlay = import ./overlay.nix;
  # gen build path: lockfile-builder consumes gen's Cargo.build-spec.json
  # (auto-regen via IFD when absent) + Cargo.gen.lock for git-dep source
  # hashes — which the actual fetcher computes, so it is immune to the
  # crate2nix-vs-fetchgit hash drift. Imported lazily per target pkgs below.
  plemeCrateOverrides = import ./pleme-crate-overrides.nix;

  # Host pkgs — used for devShell, apps, and native builds
  hostOverlays = if fenix != null
    then [ (rustOverlay.mkRustOverlay { inherit fenix system; }) ]
    else [];
  hostPkgs = import nixpkgs {
    inherit system;
    overlays = hostOverlays;
  };
  # nonrootUid/nonrootGid only, computed here (not the inner function body's
  # `let`) so it's in scope for the `user ?` argument-pattern default below --
  # Nix evaluates that default against this enclosing scope, not the inner
  # body. Matches oci/hardened-base.nix's own "nonroot" convention (65532),
  # NOT 65534 ("nobody") this default had silently drifted to.
  hardenedBase = import ../oci/hardened-base.nix { pkgs = hostPkgs; };
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
  # Build via gen's lockfile-builder (Cargo.gen.lock hashes) instead of
  # crate2nix's Cargo.nix. Eliminates the crate2nix-vs-fetchgit git-dep
  # hash drift (the recurring `hash mismatch in fixed-output derivation`
  # image-build failure). Requires Cargo.gen.lock in the workspace root
  # (Cargo.build-spec.json is auto-derived via gen IFD when absent).
  genBuild ? false,
  ...
}:
let
  effectivePackageName = if packageName != null then packageName else toolName;
  hasArch = arch: builtins.elem arch architectures;

  # Construct the crate project for a given target pkgs, via gen
  # (lockfile-builder) or crate2nix. Both return the same shape
  # ({ workspaceMembers.<name>.build } / { rootCrate.build }), so the
  # binary-extraction + image-build code below is builder-agnostic.
  # `extraBuildInputs` lets the native (host) build add darwin shims.
  mkProjectFor = pkgs: extraBuildInputs: let
    pkgOverride = attrs: {
      buildInputs = (attrs.buildInputs or []) ++ buildInputs ++ extraBuildInputs;
      nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ nativeBuildInputs;
    };
  in
    if genBuild then
      (import ./lockfile-builder.nix { inherit pkgs; }).mkProject {
        inherit src;
        defaultCrateOverrides =
          pkgs.defaultCrateOverrides // plemeCrateOverrides // {
            ${effectivePackageName} = pkgOverride;
          } // crateOverrides;
      }
    else
      import cargoNix {
        inherit pkgs;
        defaultCrateOverrides = pkgs.defaultCrateOverrides // {
          ${effectivePackageName} = pkgOverride;
        } // crateOverrides;
      };

  # ============================================================================
  # DOCKER IMAGE BUILDER
  # ============================================================================
  # Builds a minimal Docker image for a specific Linux architecture.
  # On macOS, Nix delegates to remote builders transparently.
  # Requires Cargo.nix to exist — generate with: crate2nix generate
  mkImage = arch: let
    targetSystem = if arch == "arm64" then "aarch64-linux" else "x86_64-linux";
    targetPkgs = import nixpkgs { system = targetSystem; };
    # Hardened by default (Pillar 8 / oci/hardened-base.nix): distroless-glibc
    # -- no shell, TLS roots + nonroot /etc/passwd|group stub, nonroot user --
    # in place of a hand-rolled `cacert + binary` layer with no passwd entry
    # for its own uid. Same substrate every other pleme-io image now builds
    # against (breathe/go-docker.nix); this is the shared Rust CLI-tool
    # builder, so fixing it here purifies every current + future consumer.
    hardened = import ../oci/hardened-base.nix { pkgs = targetPkgs; };

    project = mkProjectFor targetPkgs [];

    binary = if project ? workspaceMembers
      then project.workspaceMembers.${effectivePackageName}.build
      else project.rootCrate.build;

    extras = extraContents targetPkgs;
  in hardened.mkPackageImage {
    service = toolName;
    base = hardened.bases.distroless-glibc;
    package = binary;
    publishName = toolName;
    publishTag = tag;
    entrypoint = [ "${binary}/bin/${toolName}" ];
    inherit user;
    extraContents = extras;
    env = [
      (dockerHelpers.mkSslEnv targetPkgs)
      "RUST_LOG=info"
    ] ++ env;
  };

  images = {}
    // (if hasArch "amd64" then { dockerImage-amd64 = mkImage "amd64"; } else {})
    // (if hasArch "arm64" then { dockerImage-arm64 = mkImage "arm64"; } else {});

  # ============================================================================
  # NATIVE BINARY (for local dev/testing on host system)
  # ============================================================================
  nativeProject = mkProjectFor hostPkgs (darwinHelpers.mkDarwinBuildInputs hostPkgs);

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
  # IMAGE RELEASE (forge-based, standard multi-arch pattern)
  # ============================================================================
  forgeCmd = if forge != null
    then "${forge}/bin/forge"
    else "forge";

  imageReleaseModule = import ../../service/image-release.nix {
    pkgs = hostPkgs;
    inherit forgeCmd;
  };

  registry = "ghcr.io/${repo}";

  # Map architecture names to Linux system triples for mkImageReleaseApp
  archToSystem = arch:
    if arch == "arm64" then "aarch64-linux" else "x86_64-linux";

  releaseApp = imageReleaseModule.mkImageReleaseApp {
    name = toolName;
    inherit registry;
    mkImage = targetSystem: mkImage (
      if targetSystem == "aarch64-linux" then "arm64" else "amd64"
    );
    systems = map archToSystem architectures;
  };

in {
  packages = images // {
    default = wrappedNative;
    ${toolName} = wrappedNative;
  };

  devShells.default = (import ../shared/devshell.nix { pkgs = hostPkgs; }).mkRustDevShell {
    pkgs = hostPkgs;
    inherit devenv nixpkgs;
    devenvModule = ../../devenv/rust-tool.nix;
    tools = devTools ++ [ hostPkgs.rust-analyzer ];
    extraPackages = (if crate2nix != null then [ crate2nix ] else []) ++ runtimeDeps;
    inherit buildInputs;
  };

  apps = {
    default = {
      type = "app";
      program = "${wrappedNative}/bin/${toolName}";
    };

    # Primary release app: pushes all architectures via forge image-release
    # Tags: {arch}-{git-short-sha} (immutable) + {arch}-latest (floating)
    release = releaseApp;
  }
  # The crate2nix regenerate app only applies to the crate2nix build path.
  # The gen path (genBuild) regenerates via `gen build .` instead.
  // (if crate2nix != null then {
    regenerate-cargo-nix = {
      type = "app";
      program = toString (hostPkgs.writeShellScript "${toolName}-regenerate-cargo-nix" ''
        set -euo pipefail
        ${crate2nix}/bin/crate2nix generate
      '');
    };
  } else {});
}
