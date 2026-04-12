# ============================================================================
# RUST WORKSPACE RELEASE BUILDER - Multi-crate workspace builds + releases
# ============================================================================
# Builds a specific binary crate from a Cargo workspace for 4 targets:
#   - aarch64-apple-darwin  (native)
#   - x86_64-apple-darwin   (Rosetta)
#   - x86_64-unknown-linux-musl  (remote builder, static)
#   - aarch64-unknown-linux-musl (remote builder, static)
#
# Differs from tool-release.nix in that it uses workspaceMembers instead
# of rootCrate, supporting Cargo workspaces with multiple crates.
#
# Usage:
#   let rustWorkspace = import "${substrate}/lib/build/rust/workspace-release.nix" {
#     inherit system nixpkgs crate2nix;
#   };
#   in rustWorkspace {
#     toolName = "mamorigami";         # binary name (from [[bin]] in Cargo.toml)
#     packageName = "mamorigami-cli";  # workspace member crate name
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

  hostOverlays = if fenix != null
    then [ (rustOverlay.mkRustOverlay { inherit fenix system; }) ]
    else [];
  hostPkgs = import nixpkgs {
    inherit system;
    overlays = hostOverlays;
  };

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
  packageName,
  src,
  repo,
  cargoNix ? src + "/Cargo.nix",
  buildInputs ? [],
  nativeBuildInputs ? [],
  crateOverrides ? {},
  ...
}:
let
  _ = check.all [
    (check.nonEmptyStr "toolName" toolName)
    (check.nonEmptyStr "packageName" packageName)
    (check.list "buildInputs" buildInputs)
    (check.list "nativeBuildInputs" nativeBuildInputs)
    (check.attrs "crateOverrides" crateOverrides)
  ];
  # ============================================================================
  # BINARY BUILDER — workspace-aware
  # ============================================================================
  mkBinary = targetName: targetInfo: let
    targetPkgs = targetInfo.pkgs;
    project = import cargoNix {
      pkgs = targetPkgs;
      defaultCrateOverrides = targetPkgs.defaultCrateOverrides // {
        ${packageName} = attrs: {
          buildInputs = (attrs.buildInputs or [])
            ++ buildInputs
            ++ (darwinHelpers.mkDarwinBuildInputs targetPkgs);
          nativeBuildInputs = (attrs.nativeBuildInputs or [])
            ++ (builtins.map (name: targetPkgs.${name}) nativeBuildInputs);
        };
      } // crateOverrides;
    };
  in
    if project ? workspaceMembers then
      if project.workspaceMembers ? "${packageName}" then
        project.workspaceMembers.${packageName}.build
      else
        builtins.throw ''
          substrate/workspace-release: packageName "${packageName}" not found.
          Available members: ${builtins.concatStringsSep ", " (builtins.attrNames project.workspaceMembers)}
        ''
    else
      project.rootCrate.build;

  binaries = builtins.mapAttrs mkBinary targets;

  nativeTarget =
    if system == "aarch64-darwin" then "aarch64-apple-darwin"
    else if system == "x86_64-darwin" then "x86_64-apple-darwin"
    else if system == "x86_64-linux" then "x86_64-unknown-linux-musl"
    else if system == "aarch64-linux" then "aarch64-unknown-linux-musl"
    else throw "Unsupported system: ${system}";

  nativeBinary = binaries.${nativeTarget};

  # ============================================================================
  # APPS
  # ============================================================================
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
