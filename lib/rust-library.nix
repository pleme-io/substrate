# ============================================================================
# RUST LIBRARY BUILDER - Nix-based SDLC for crates.io Rust libraries
# ============================================================================
# Build verification, dev shells, check-all, publish, and regenerate apps.
# No Docker, no push, no deploy — libraries don't need them.
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
}: let
  pkgs = import nixpkgs {
    inherit system;
    overlays = [ nixLib.overlays.${system}.rust ];
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
  ];

  defaultDevEnvVars = {
    RUST_SRC_PATH = "${pkgs.fenixRustToolchain}/lib/rustlib/src/rust/library";
  };
  allDevEnvVars = defaultDevEnvVars // devEnvVars;

in {
  packages.default = libraryBuild;

  devShells.default = pkgs.mkShell ({
    buildInputs = allBuildInputs ++ devTools ++ extraDevInputs ++ [ crate2nix ];
    nativeBuildInputs = allNativeBuildInputs;
  } // allDevEnvVars);

  apps = {
    check-all = {
      type = "app";
      program = toString (pkgs.writeShellScript "${name}-check-all" ''
        set -euo pipefail
        echo "Running checks for ${name}..."
        echo ""

        echo "==> cargo fmt --check"
        ${pkgs.fenixRustToolchain}/bin/cargo fmt --check
        echo ""

        echo "==> cargo clippy"
        ${pkgs.fenixRustToolchain}/bin/cargo clippy --all-targets -- -D warnings
        echo ""

        echo "==> cargo test"
        ${pkgs.fenixRustToolchain}/bin/cargo test
        echo ""

        echo "All checks passed."
      '');
    };

    publish = {
      type = "app";
      program = toString (pkgs.writeShellScript "${name}-publish" ''
        set -euo pipefail

        DRY_RUN=false
        for arg in "$@"; do
          case "$arg" in
            --dry-run) DRY_RUN=true ;;
          esac
        done

        if [ "$DRY_RUN" = "true" ]; then
          echo "Dry run: validating ${name} for crates.io..."
          ${pkgs.fenixRustToolchain}/bin/cargo publish --dry-run
          echo ""
          echo "Dry run passed. Ready to publish."
        else
          if [ -z "''${CARGO_REGISTRY_TOKEN:-}" ]; then
            echo "Error: CARGO_REGISTRY_TOKEN is not set."
            echo "Set it via: export CARGO_REGISTRY_TOKEN=<your-token>"
            exit 1
          fi
          echo "Publishing ${name} to crates.io..."
          ${pkgs.fenixRustToolchain}/bin/cargo publish
          echo ""
          echo "Published successfully."
        fi
      '');
    };

    regenerate = {
      type = "app";
      program = toString (pkgs.writeShellScript "${name}-regenerate" ''
        set -euo pipefail
        echo "Regenerating Cargo.nix for ${name}..."
        ${crate2nix}/bin/crate2nix generate
        echo "Cargo.nix regenerated."
        echo ""
        echo "Don't forget to commit it:"
        echo "  git add Cargo.nix && git commit -m 'chore: regenerate Cargo.nix'"
      '');
    };
  };
}
