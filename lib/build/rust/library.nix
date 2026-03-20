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

  devShells.default = if devenv != null then
    devenv.lib.mkShell {
      inputs = { inherit nixpkgs; inherit devenv; };
      inherit pkgs;
      modules = [
        (import ../../devenv/rust-library.nix)
        ({ lib, ... }: {
          env = builtins.mapAttrs (_: v: lib.mkDefault v) allDevEnvVars;
          packages = extraDevInputs ++ [ crate2nix ];
        })
      ];
    }
  else
    pkgs.mkShell ({
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

    bump = {
      type = "app";
      program = toString (pkgs.writeShellScript "${name}-bump" ''
        set -euo pipefail

        BUMP_TYPE="''${1:-patch}"
        case "$BUMP_TYPE" in
          major|minor|patch) ;;
          *)
            echo "Usage: nix run .#bump -- {major|minor|patch}"
            echo ""
            echo "Bumps version in Cargo.toml, regenerates Cargo.nix, commits, and tags."
            exit 1
            ;;
        esac

        OLD_VERSION=$(${pkgs.fenixRustToolchain}/bin/cargo metadata --no-deps --format-version 1 | ${pkgs.jq}/bin/jq -r '.packages[0].version')
        echo "Current version: $OLD_VERSION"
        echo ""

        echo "==> cargo set-version --bump $BUMP_TYPE"
        ${pkgs.cargo-edit}/bin/cargo set-version --bump "$BUMP_TYPE"
        NEW_VERSION=$(${pkgs.fenixRustToolchain}/bin/cargo metadata --no-deps --format-version 1 | ${pkgs.jq}/bin/jq -r '.packages[0].version')
        echo ""

        echo "==> Regenerating Cargo.nix..."
        ${crate2nix}/bin/crate2nix generate
        echo ""

        # Update Cargo.lock
        ${pkgs.fenixRustToolchain}/bin/cargo check --quiet 2>/dev/null || true

        ${pkgs.git}/bin/git add Cargo.toml Cargo.lock Cargo.nix
        ${pkgs.git}/bin/git commit -m "release: ${name} v$NEW_VERSION"
        ${pkgs.git}/bin/git tag "v$NEW_VERSION"

        echo "Bumped $OLD_VERSION -> $NEW_VERSION"
        echo ""
        echo "Next steps:"
        echo "  git push && git push --tags"
        echo "  nix run .#publish"
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

    release = {
      type = "app";
      program = toString (pkgs.writeShellScript "${name}-release" ''
        set -euo pipefail

        BUMP_TYPE="''${1:-patch}"
        case "$BUMP_TYPE" in
          major|minor|patch) ;;
          *)
            echo "Usage: nix run .#release -- {major|minor|patch}"
            echo ""
            echo "Bumps version, publishes, and pushes in one step."
            exit 1
            ;;
        esac

        if [ -z "''${CARGO_REGISTRY_TOKEN:-}" ]; then
          echo "Error: CARGO_REGISTRY_TOKEN is not set."
          echo "Set it via: export CARGO_REGISTRY_TOKEN=<your-token>"
          exit 1
        fi

        OLD_VERSION=$(${pkgs.fenixRustToolchain}/bin/cargo metadata --no-deps --format-version 1 | ${pkgs.jq}/bin/jq -r '.packages[0].version')
        echo "Current version: $OLD_VERSION"
        echo ""

        # Bump
        echo "==> cargo set-version --bump $BUMP_TYPE"
        ${pkgs.cargo-edit}/bin/cargo set-version --bump "$BUMP_TYPE"
        NEW_VERSION=$(${pkgs.fenixRustToolchain}/bin/cargo metadata --no-deps --format-version 1 | ${pkgs.jq}/bin/jq -r '.packages[0].version')
        echo ""

        echo "==> Regenerating Cargo.nix..."
        ${crate2nix}/bin/crate2nix generate
        ${pkgs.fenixRustToolchain}/bin/cargo check --quiet 2>/dev/null || true
        ${pkgs.git}/bin/git add Cargo.toml Cargo.lock Cargo.nix
        ${pkgs.git}/bin/git commit -m "release: ${name} v$NEW_VERSION"
        ${pkgs.git}/bin/git tag "v$NEW_VERSION"
        echo "Bumped $OLD_VERSION -> $NEW_VERSION"
        echo ""

        # Publish
        echo "==> cargo publish"
        ${pkgs.fenixRustToolchain}/bin/cargo publish
        echo ""

        # Push
        echo "==> git push && git push --tags"
        ${pkgs.git}/bin/git push
        ${pkgs.git}/bin/git push --tags
        echo ""

        echo "Released ${name} v$NEW_VERSION"
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
