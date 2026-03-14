# ============================================================================
# RUST TOOL RELEASE BUILDER - Cross-platform CLI tool builds + GitHub releases
# ============================================================================
# Builds a Rust CLI tool for 4 targets from aarch64-darwin:
#   - aarch64-apple-darwin  (native)
#   - x86_64-apple-darwin   (Rosetta)
#   - x86_64-unknown-linux-musl  (remote builder, static)
#   - aarch64-unknown-linux-musl (remote builder, static)
#
# Usage:
#   let rustTool = import "${substrate}/lib/rust-tool-release.nix" {
#     inherit system nixpkgs crate2nix;
#   };
#   in rustTool {
#     toolName = "kindling";
#     src = self;
#     repo = "pleme-io/kindling";
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
  darwinHelpers = import ./darwin.nix;
  rustOverlay = import ./rust-overlay.nix;

  # Host pkgs — used for devShell, apps, and native builds
  hostOverlays = if fenix != null
    then [ (rustOverlay.mkRustOverlay { inherit fenix system; }) ]
    else [];
  hostPkgs = import nixpkgs {
    inherit system;
    overlays = hostOverlays;
  };

  # ============================================================================
  # TARGET PKGS BUILDERS
  # ============================================================================
  # Linux static binaries via pkgsStatic (musl) — built on remote builders.
  # Darwin binaries via standard pkgs — Rosetta handles x86_64-darwin on arm64.

  mkLinuxStaticPkgs = targetSystem: (import nixpkgs { system = targetSystem; }).pkgsStatic;
  mkDarwinPkgs = targetSystem: import nixpkgs { system = targetSystem; };

  # All cross-compilation targets
  targets = {
    "aarch64-apple-darwin" = {
      pkgs = mkDarwinPkgs "aarch64-darwin";
      isDarwin = true;
    };
    "x86_64-apple-darwin" = {
      pkgs = mkDarwinPkgs "x86_64-darwin";
      isDarwin = true;
    };
    "x86_64-unknown-linux-musl" = {
      pkgs = mkLinuxStaticPkgs "x86_64-linux";
      isDarwin = false;
    };
    "aarch64-unknown-linux-musl" = {
      pkgs = mkLinuxStaticPkgs "aarch64-linux";
      isDarwin = false;
    };
  };
in {
  toolName,
  src,
  repo,
  cargoNix ? src + "/Cargo.nix",
  buildInputs ? [],
  nativeBuildInputs ? [],
  crateOverrides ? {},
  ...
}:
let
  # ============================================================================
  # BINARY BUILDER
  # ============================================================================
  mkBinary = targetName: targetInfo: let
    targetPkgs = targetInfo.pkgs;
    project = import cargoNix {
      pkgs = targetPkgs;
      defaultCrateOverrides = targetPkgs.defaultCrateOverrides // {
        ${toolName} = attrs: {
          buildInputs = (attrs.buildInputs or [])
            ++ buildInputs
            ++ (darwinHelpers.mkDarwinBuildInputs targetPkgs);
          nativeBuildInputs = (attrs.nativeBuildInputs or [])
            ++ (builtins.map (name: targetPkgs.${name}) nativeBuildInputs);
        };
      } // crateOverrides;
    };
  in project.rootCrate.build;

  # Build all target binaries
  binaries = builtins.mapAttrs mkBinary targets;

  # Native binary (matches host system)
  nativeTarget =
    if system == "aarch64-darwin" then "aarch64-apple-darwin"
    else if system == "x86_64-darwin" then "x86_64-apple-darwin"
    else if system == "x86_64-linux" then "x86_64-unknown-linux-musl"
    else if system == "aarch64-linux" then "aarch64-unknown-linux-musl"
    else throw "Unsupported system: ${system}";

  nativeBinary = binaries.${nativeTarget};

  # ============================================================================
  # APPS (via release-helpers.nix)
  # ============================================================================
  # Resolve forge command — avoid hostPkgs.forge which collides with a removed
  # nixpkgs alias (throws instead of returning missing).
  forgeCmd = if forge != null
    then "${forge}/bin/forge"
    else "forge";

  releaseHelpers = import ./release-helpers.nix;

  releaseApp = releaseHelpers.mkReleaseApp {
    inherit hostPkgs toolName repo forgeCmd;
    language = "rust";
  };

  bumpApp = releaseHelpers.mkBumpApp {
    inherit hostPkgs toolName forgeCmd;
    language = "rust";
  };

  # Regenerate Cargo.nix — delegates to forge tool regenerate
  regenerateApp = {
    type = "app";
    program = toString (hostPkgs.writeShellScript "${toolName}-regenerate-cargo-nix" ''
      set -euo pipefail
      exec ${forgeCmd} tool regenerate --language rust
    '');
  };

  checkAllApp = releaseHelpers.mkCheckAllApp {
    inherit hostPkgs toolName forgeCmd;
    language = "rust";
  };

  lockPlatformApp = releaseHelpers.mkLockPlatformApp {
    inherit hostPkgs toolName forgeCmd;
    language = "rust";
  };

  # Dev tools for devShell
  devTools = if fenix != null then [
    hostPkgs.fenixRustToolchain
  ] else (with hostPkgs; [
    cargo
    rustc
    clippy
    rustfmt
  ]);
in {
  packages = builtins.listToAttrs (
    builtins.map (targetName: {
      name = "${toolName}-${targetName}";
      value = binaries.${targetName};
    }) (builtins.attrNames targets)
  ) // {
    default = nativeBinary;
    ${toolName} = nativeBinary;
  };

  devShells.default = if devenv != null then
    devenv.lib.mkShell {
      inputs = { inherit nixpkgs; inherit devenv; };
      pkgs = hostPkgs;
      modules = [
        (import ./devenv/rust-tool.nix)
        ({ ... }: {
          packages = [ crate2nix ] ++ buildInputs;
        })
      ];
    }
  else
    hostPkgs.mkShell {
      buildInputs = devTools ++ [
        hostPkgs.rust-analyzer
        crate2nix
      ] ++ buildInputs
        ++ (darwinHelpers.mkDarwinBuildInputs hostPkgs);
    };

  apps = {
    default = {
      type = "app";
      program = "${nativeBinary}/bin/${toolName}";
    };
    release = releaseApp;
    bump = bumpApp;
    regenerate-cargo-nix = regenerateApp;
    check-all = checkAllApp;
    lock-platform = lockPlatformApp;
  };
}
