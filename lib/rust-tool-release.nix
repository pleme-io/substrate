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
  # APPS
  # ============================================================================

  # Release script: build all targets, tag, upload to GitHub
  releaseApp = {
    type = "app";
    program = toString (hostPkgs.writeShellScript "${toolName}-release" ''
      set -euo pipefail

      DRY_RUN=false
      for arg in "$@"; do
        case "$arg" in
          --dry-run) DRY_RUN=true ;;
        esac
      done

      # Read version from Cargo.toml
      VERSION=$(${hostPkgs.gnused}/bin/sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
      if [ -z "$VERSION" ]; then
        echo "ERROR: Could not read version from Cargo.toml"
        exit 1
      fi
      TAG="v$VERSION"
      echo "Building ${toolName} $TAG for all targets..."

      # Validate
      if [ "$DRY_RUN" = false ]; then
        if ! ${hostPkgs.git}/bin/git diff --quiet HEAD 2>/dev/null; then
          echo "ERROR: Uncommitted changes. Commit or stash first."
          exit 1
        fi
        if ${hostPkgs.git}/bin/git rev-parse "$TAG" >/dev/null 2>&1; then
          echo "ERROR: Tag $TAG already exists."
          exit 1
        fi
      fi

      TMPDIR=$(mktemp -d)
      trap "rm -rf $TMPDIR" EXIT

      TARGETS=(
        "${toolName}-aarch64-apple-darwin"
        "${toolName}-x86_64-apple-darwin"
        "${toolName}-x86_64-unknown-linux-musl"
        "${toolName}-aarch64-unknown-linux-musl"
      )

      for target in "''${TARGETS[@]}"; do
        echo "Building $target..."
        STORE_PATH=$(nix build ".#$target" --no-link --print-out-paths 2>&1)
        cp "$STORE_PATH/bin/${toolName}" "$TMPDIR/$target"
        chmod +x "$TMPDIR/$target"
        echo "  -> $TMPDIR/$target"
      done

      echo ""
      echo "All targets built successfully."

      if [ "$DRY_RUN" = true ]; then
        echo ""
        echo "[DRY RUN] Would create tag $TAG and upload:"
        for target in "''${TARGETS[@]}"; do
          echo "  $target"
        done
        echo ""
        echo "Binaries available in: $TMPDIR"
        # Keep tmpdir alive for inspection
        trap - EXIT
        exit 0
      fi

      echo "Creating tag $TAG..."
      ${hostPkgs.git}/bin/git tag -a "$TAG" -m "Release $TAG"
      ${hostPkgs.git}/bin/git push origin "$TAG"

      echo "Creating GitHub release..."
      ${hostPkgs.gh}/bin/gh release create "$TAG" \
        --repo "${repo}" \
        --generate-notes \
        "''${TARGETS[@]/#/$TMPDIR/}"

      echo ""
      echo "Release $TAG published to https://github.com/${repo}/releases/tag/$TAG"
    '');
  };

  # Version bump script
  bumpApp = {
    type = "app";
    program = toString (hostPkgs.writeShellScript "${toolName}-bump" ''
      set -euo pipefail

      LEVEL="''${1:-patch}"
      case "$LEVEL" in
        major|minor|patch) ;;
        *) echo "Usage: nix run .#bump -- {major|minor|patch}"; exit 1 ;;
      esac

      echo "Bumping $LEVEL version..."
      ${hostPkgs.cargo-edit}/bin/cargo set-version --bump "$LEVEL"

      echo "Regenerating Cargo.nix..."
      ${crate2nix}/bin/crate2nix generate

      NEW_VERSION=$(${hostPkgs.gnused}/bin/sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
      echo ""
      echo "Bumped to v$NEW_VERSION"
      echo ""
      echo "Review and commit:"
      echo "  git add Cargo.toml Cargo.lock Cargo.nix"
      echo "  git commit -m 'chore: bump to v$NEW_VERSION'"
    '');
  };

  # Regenerate Cargo.nix
  regenerateApp = {
    type = "app";
    program = toString (hostPkgs.writeShellScript "${toolName}-regenerate-cargo-nix" ''
      set -euo pipefail
      echo "Regenerating Cargo.nix..."
      ${crate2nix}/bin/crate2nix generate
      echo "Cargo.nix regenerated."
      echo "Don't forget to commit: git add Cargo.nix"
    '');
  };

  # Check all (fmt, clippy, test)
  checkAllApp = {
    type = "app";
    program = toString (hostPkgs.writeShellScript "${toolName}-check-all" ''
      set -euo pipefail
      echo "Checking ${toolName}..."
      echo "-> cargo fmt --check"
      cargo fmt --check
      echo "-> cargo clippy"
      cargo clippy -- -D warnings
      echo "-> cargo test"
      cargo test
      echo "All checks passed."
    '');
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

  devShells.default = hostPkgs.mkShell {
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
  };
}
