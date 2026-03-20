# ============================================================================
# ZIG TOOL RELEASE BUILDER - Cross-platform CLI tool builds + GitHub releases
# ============================================================================
# Builds a Zig CLI tool for 4 targets using Zig's built-in cross-compilation.
# Unlike the Rust variant, ALL targets are built on the host — no remote
# builders needed. Zig bundles its own libc for Linux targets.
#
# Targets:
#   - aarch64-apple-darwin  (native or Zig cross-compile)
#   - x86_64-apple-darwin   (Zig cross-compile)
#   - x86_64-unknown-linux-musl  (Zig cross-compile, static)
#   - aarch64-unknown-linux-musl (Zig cross-compile, static)
#
# Usage:
#   let zigTool = import "${substrate}/lib/zig-tool-release.nix" {
#     inherit system nixpkgs;
#   };
#   in zigTool {
#     toolName = "z9s";
#     src = self;
#     repo = "drzln/z9s";
#   }
#
# Returns: { packages, devShells, apps }
{
  nixpkgs,
  system,
}: let
  zigOverlay = import ./overlay.nix;

  hostPkgs = import nixpkgs {
    inherit system;
    overlays = [ (zigOverlay.mkZigOverlay {}) ];
  };
  lib = hostPkgs.lib;

  # ============================================================================
  # ZIG CROSS-COMPILATION TARGETS
  # ============================================================================
  # Zig target triple → release binary name mapping.
  # Zig has built-in cross-compilation — all targets build on the host.
  # Linux targets use musl (static, fully portable).
  # Darwin targets require building ON Darwin (macOS system headers).

  targets = {
    "aarch64-apple-darwin" = "aarch64-macos";
    "x86_64-apple-darwin" = "x86_64-macos";
    "x86_64-unknown-linux-musl" = "x86_64-linux-musl";
    "aarch64-unknown-linux-musl" = "aarch64-linux-musl";
  };
in {
  toolName,
  src,
  repo,
  version ? "0.1.0",
  deps ? null,
  nativeBuildInputs ? [],
  zigBuildFlags ? [],
  ...
}:
let
  # ============================================================================
  # BINARY BUILDER
  # ============================================================================
  mkBinary = releaseName: zigTarget: hostPkgs.stdenvNoCC.mkDerivation {
    pname = "${toolName}-${releaseName}";
    inherit version src;

    nativeBuildInputs = [ hostPkgs.zigToolchain ] ++ nativeBuildInputs;

    dontInstall = true;
    dontFixup = true;

    configurePhase = ''
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/.zig-cache
    '';

    buildPhase = ''
      zig build install \
        ${lib.optionalString (deps != null) "--system ${deps}"} \
        -Dtarget=${zigTarget} \
        -Doptimize=ReleaseSafe \
        --color off \
        ${lib.concatStringsSep " " zigBuildFlags} \
        --prefix $out
    '';
  };

  # Build all target binaries
  binaries = lib.mapAttrs mkBinary targets;

  # Native binary (no cross-compilation flag)
  nativeBinary = hostPkgs.stdenvNoCC.mkDerivation {
    pname = toolName;
    inherit version src;

    nativeBuildInputs = [ hostPkgs.zigToolchain ] ++ nativeBuildInputs;

    dontInstall = true;
    dontFixup = true;

    configurePhase = ''
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/.zig-cache
    '';

    buildPhase = ''
      zig build install \
        ${lib.optionalString (deps != null) "--system ${deps}"} \
        -Doptimize=ReleaseSafe \
        --color off \
        ${lib.concatStringsSep " " zigBuildFlags} \
        --prefix $out
    '';
  };

  # ============================================================================
  # APPS (via release-helpers.nix)
  # ============================================================================
  releaseHelpers = import ../../util/release-helpers.nix;

  releaseApp = releaseHelpers.mkReleaseApp {
    inherit hostPkgs toolName repo;
    language = "zig";
  };

  bumpApp = releaseHelpers.mkBumpApp {
    inherit hostPkgs toolName;
    language = "zig";
  };

  checkAllApp = releaseHelpers.mkCheckAllApp {
    inherit hostPkgs toolName;
    language = "zig";
  };
in {
  packages = lib.mapAttrs' (releaseName: binary: {
    name = "${toolName}-${releaseName}";
    value = binary;
  }) binaries // {
    default = nativeBinary;
    ${toolName} = nativeBinary;
  };

  devShells.default = hostPkgs.mkShell {
    buildInputs = [
      hostPkgs.zigToolchain
      hostPkgs.zls
    ] ++ nativeBuildInputs;
  };

  apps = {
    default = {
      type = "app";
      program = "${nativeBinary}/bin/${toolName}";
    };
    release = releaseApp;
    bump = bumpApp;
    check-all = checkAllApp;
  };
}
