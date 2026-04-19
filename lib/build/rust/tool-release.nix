# ============================================================================
# RUST RELEASE BUILDER — unified single-crate + workspace CLI tool builds
# ============================================================================
# Builds a Rust CLI tool for 4 targets from any supported host:
#   - aarch64-apple-darwin
#   - x86_64-apple-darwin          (via Rosetta from aarch64-darwin)
#   - x86_64-unknown-linux-musl    (remote builder, static)
#   - aarch64-unknown-linux-musl   (remote builder, static)
#
# Works for both single-crate tools and workspace members:
#   - Single crate:     omit `packageName`; uses `project.rootCrate`
#   - Workspace member: set `packageName`; uses `project.workspaceMembers.${packageName}`
#
# Usage (single crate):
#   rustTool {
#     toolName = "kindling";
#     src = self;
#     repo = "pleme-io/kindling";
#   }
#
# Usage (workspace member — replaces the old separate workspace-release builder):
#   rustTool {
#     toolName = "mamorigami";
#     packageName = "mamorigami-cli";
#     src = self;
#     repo = "pleme-io/mamorigami";
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
  check = import ../../types/assertions.nix;
  darwinHelpers = import ../../util/darwin.nix;
  rustOverlay = import ./overlay.nix;

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
  # Linux static binaries via pkgsStatic (musl). Darwin binaries via standard
  # pkgs — Rosetta handles x86_64-darwin on aarch64 hosts.
  mkLinuxStaticPkgs = targetSystem: (import nixpkgs { system = targetSystem; }).pkgsStatic;
  mkDarwinPkgs = targetSystem: import nixpkgs { system = targetSystem; };

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
  packageName ? null,            # null = single-crate; set = workspace member
  cargoNix ? src + "/Cargo.nix",
  buildInputs ? [],
  nativeBuildInputs ? [],
  crateOverrides ? {},
  ...
}:
let
  _ = check.all [
    (check.nonEmptyStr "toolName" toolName)
    (check.nonEmptyStr "repo" repo)
    (check.list "buildInputs" buildInputs)
    (check.list "nativeBuildInputs" nativeBuildInputs)
    (check.attrs "crateOverrides" crateOverrides)
  ];

  # Crate name for defaultCrateOverrides: workspace member when set, else toolName.
  crateKey = if packageName != null then packageName else toolName;

  # ============================================================================
  # BINARY BUILDER
  # ============================================================================
  mkBinary = _targetName: targetInfo: let
    targetPkgs = targetInfo.pkgs;
    project = import cargoNix {
      pkgs = targetPkgs;
      defaultCrateOverrides = targetPkgs.defaultCrateOverrides // {
        ${crateKey} = attrs: {
          buildInputs = (attrs.buildInputs or [])
            ++ buildInputs
            ++ (darwinHelpers.mkDarwinBuildInputs targetPkgs);
          nativeBuildInputs = (attrs.nativeBuildInputs or [])
            ++ (builtins.map (name: targetPkgs.${name}) nativeBuildInputs);
        };
      } // crateOverrides;
    };
  in
    if packageName != null then
      if project ? workspaceMembers && project.workspaceMembers ? "${packageName}" then
        project.workspaceMembers.${packageName}.build
      else
        builtins.throw ''
          substrate/rust-release: packageName "${packageName}" not found.
          ${if project ? workspaceMembers
            then "Available members: ${builtins.concatStringsSep ", " (builtins.attrNames project.workspaceMembers)}"
            else "Project has no workspaceMembers — is ${toString cargoNix} a workspace Cargo.nix?"}
        ''
    else
      project.rootCrate.build;

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

  releaseHelpers = import ../../util/release-helpers.nix;

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
        (import ../../devenv/rust-tool.nix)
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
