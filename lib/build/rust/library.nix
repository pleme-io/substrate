# ============================================================================
# RUST LIBRARY BUILDER - Nix-based SDLC for crates.io Rust libraries
# ============================================================================
# Build verification, dev shells, and lifecycle apps.
# No Docker, no deploy — libraries publish to crates.io.
#
# Apps:
#   check-all  — cargo fmt + clippy + test
#   bump       — version bump (patch|minor|major), regenerate, git commit + tag
#   publish    — cargo publish
#   release    — bump + publish in one step
#   regenerate — regenerate Cargo.nix from Cargo.lock
#
# Usage in library flake.nix:
#   let rustLibrary = import "${substrate}/lib/rust-library.nix" {
#     inherit system nixpkgs;
#     nixLib = substrate;
#     crate2nix = inputs.crate2nix;
#   };
#   in rustLibrary {
#     name = "pleme-notifications";
#     src = ./.;
#   }
#
# This returns: { packages, devShells, apps }
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
  name,
  src,
  cargoNix ? src + "/Cargo.nix",
  buildInputs ? [],
  nativeBuildInputs ? [],
  crateOverrides ? {},
  extraDevInputs ? [],
  devEnvVars ? {},
}: let
  _ = check.all [
    (check.nonEmptyStr "name" name)
    (check.list "buildInputs" buildInputs)
    (check.list "nativeBuildInputs" nativeBuildInputs)
    (check.attrs "crateOverrides" crateOverrides)
  ];
  # Default build inputs for libraries (lighter than services — no postgres/sqlite)
  defaultBuildInputs = with pkgs; [ openssl ];
  allBuildInputs = defaultBuildInputs ++ buildInputs;
  defaultNativeBuildInputs = with pkgs; [ pkg-config ];
  allNativeBuildInputs = defaultNativeBuildInputs ++ nativeBuildInputs;

  # crate2nix build — verifies the library compiles in Nix sandbox
  crate2nixTools = import "${crate2nix}/tools.nix" { inherit pkgs; };
  generatedCargoNix =
    if builtins.pathExists cargoNix then cargoNix
    else crate2nixTools.generatedCargoNix { inherit name src; };

  project = import generatedCargoNix {
    inherit pkgs;
    defaultCrateOverrides = pkgs.defaultCrateOverrides // {
      ${name} = oldAttrs: {
        buildInputs = allBuildInputs;
        nativeBuildInputs = allNativeBuildInputs;
      };
    } // crateOverrides;
  };

  libraryBuild = project.rootCrate.build;

  # Dev tools
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

in {
  packages.default = libraryBuild;

  devShells.default = (import ../shared/devshell.nix { inherit pkgs; }).mkRustDevShell {
    inherit pkgs devenv nixpkgs;
    devenvModule = ../../devenv/rust-library.nix;
    tools = devTools;
    buildInputs = allBuildInputs;
    nativeBuildInputs = allNativeBuildInputs;
    extraPackages = extraDevInputs ++ [ crate2nix ];
    env = allDevEnvVars;
  };

  apps = (import ../shared/cargo-release-app.nix {
    inherit pkgs crate2nix;
  }).mkCargoReleaseApps { inherit name; };
}
