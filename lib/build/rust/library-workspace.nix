# ============================================================================
# RUST LIBRARY WORKSPACE BUILDER — multi-crate, no binary
# ============================================================================
# The missing dual to workspace-release.nix on the library side: a Cargo
# workspace where every member is a library (no binary entry point) that
# may be published to crates.io independently.
#
# Use when a workspace is decomposed into types / domain crates / umbrella
# re-export (the pleme-io shigoto / cofre-style "library family" pattern)
# and no binary belongs in the tree.
#
# Apps produced:
#   check-all   — cargo fmt + clippy + test across the whole workspace
#   regenerate  — regenerate Cargo.nix from Cargo.lock
#   (per-member publish/bump are operator-driven via `cargo publish -p <m>`
#    for v1; a topological all-member release helper can land later when a
#    real consumer needs it.)
#
# Usage (typically wrapped by library-workspace-flake.nix):
#   rustLibraryWorkspace {
#     workspaceName = "shigoto";
#     members = [ "shigoto" "shigoto-types" "shigoto-dag" ... ];
#     defaultMember = "shigoto";   # what `nix build` builds
#     src = self;
#   }
#
# Returns: { packages, devShells, apps }
#   packages.${member} for each workspace member
#   packages.default = packages.${defaultMember}
{
  nixpkgs,
  system,
  nixLib,
  crate2nix,
  devenv ? null,
}: let
  check = import ../../types/assertions.nix;
  pkgs = import nixpkgs {
    inherit system;
    overlays = [ nixLib.rustOverlays.${system}.rust ];
  };
in {
  workspaceName,
  members,
  defaultMember ? workspaceName,
  src,
  cargoNix ? src + "/Cargo.nix",
  buildInputs ? [],
  nativeBuildInputs ? [],
  crateOverrides ? {},
  extraDevInputs ? [],
  devEnvVars ? {},
}: let
  _ = check.all [
    (check.nonEmptyStr "workspaceName" workspaceName)
    (check.list "members" members)
    (check.nonEmptyStr "defaultMember" defaultMember)
    (check.list "buildInputs" buildInputs)
    (check.list "nativeBuildInputs" nativeBuildInputs)
    (check.attrs "crateOverrides" crateOverrides)
  ];

  defaultBuildInputs = with pkgs; [ openssl ];
  allBuildInputs = defaultBuildInputs ++ buildInputs;
  defaultNativeBuildInputs = with pkgs; [ pkg-config ];
  allNativeBuildInputs = defaultNativeBuildInputs ++ nativeBuildInputs;

  crate2nixTools = import "${crate2nix}/tools.nix" { inherit pkgs; };
  generatedCargoNix =
    if builtins.pathExists cargoNix then cargoNix
    else crate2nixTools.generatedCargoNix { name = workspaceName; inherit src; };

  # Apply per-member crateOverrides defaults — every workspace member gets
  # the default build/native inputs; consumers can override per-crate via
  # the `crateOverrides` arg.
  perMemberDefaults = pkgs.lib.genAttrs members (_member: _oldAttrs: {
    buildInputs = allBuildInputs;
    nativeBuildInputs = allNativeBuildInputs;
  });

  project = import generatedCargoNix {
    inherit pkgs;
    defaultCrateOverrides = pkgs.defaultCrateOverrides
      // perMemberDefaults
      // crateOverrides;
  };

  # Per-member build attributes. crate2nix exposes each workspace member
  # as `project.workspaceMembers.${member}.build`.
  memberBuilds = pkgs.lib.genAttrs members (member:
    project.workspaceMembers.${member}.build);

  devTools = [
    pkgs.fenixRustToolchain
    pkgs.rust-analyzer
    pkgs.cargo-watch
    pkgs.cargo-edit
  ];

  defaultDevEnvVars = {
    RUST_SRC_PATH = "${pkgs.fenixRustToolchain}/lib/rustlib/src/rust/library";
  };
  allDevEnvVars = defaultDevEnvVars // devEnvVars;

  # Workspace-wide check + regenerate apps (single binary script each;
  # per-member apps would multiply attribute paths without buying anything
  # for v1 — operators run `cargo test -p <member>` directly).
  cargo = pkgs.fenixRustToolchain or pkgs.cargo;
  cargoBin = "${cargo}/bin/cargo";
  toolchainPath = ''export PATH="${cargo}/bin:${pkgs.cargo-edit}/bin:${pkgs.git}/bin:$PATH"'';

  mkCheckAllApp = {
    type = "app";
    program = toString (pkgs.writeShellScript "${workspaceName}-check-all" ''
      set -euo pipefail
      ${toolchainPath}
      echo "Workspace ${workspaceName}: running fmt + clippy + test across all members..."
      echo ""

      echo "==> cargo fmt --check"
      ${cargoBin} fmt --check
      echo ""

      echo "==> cargo clippy --workspace --all-targets"
      ${cargoBin} clippy --workspace --all-targets -- -D warnings
      echo ""

      echo "==> cargo test --workspace"
      ${cargoBin} test --workspace
    '');
  };

  mkRegenerateApp = {
    type = "app";
    program = toString (pkgs.writeShellScript "${workspaceName}-regenerate" ''
      set -euo pipefail
      ${toolchainPath}
      echo "Workspace ${workspaceName}: regenerating Cargo.nix from Cargo.lock..."
      ${crate2nix}/bin/crate2nix generate
      echo "Done. Review the diff and commit Cargo.nix."
    '');
  };

in {
  packages = memberBuilds // {
    default = memberBuilds.${defaultMember};
  };

  devShells.default = (import ../shared/devshell.nix { inherit pkgs; }).mkRustDevShell {
    inherit pkgs devenv nixpkgs;
    devenvModule = ../../devenv/rust-library.nix;
    tools = devTools;
    buildInputs = allBuildInputs;
    nativeBuildInputs = allNativeBuildInputs;
    extraPackages = extraDevInputs ++ [ crate2nix ];
    env = allDevEnvVars;
  };

  apps = {
    check-all = mkCheckAllApp;
    regenerate = mkRegenerateApp;
  };
}
