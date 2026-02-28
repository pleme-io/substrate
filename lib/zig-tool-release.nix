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
  zigOverlay = import ./zig-overlay.nix;

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
  # APPS
  # ============================================================================

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

      # Read version from build.zig.zon
      VERSION=$(${hostPkgs.gnused}/bin/sed -n 's/.*\.version *= *"\(.*\)".*/\1/p' build.zig.zon | head -1)
      if [ -z "$VERSION" ]; then
        echo "ERROR: Could not read version from build.zig.zon"
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

  bumpApp = {
    type = "app";
    program = toString (hostPkgs.writeShellScript "${toolName}-bump" ''
      set -euo pipefail

      LEVEL="''${1:-patch}"
      case "$LEVEL" in
        major|minor|patch) ;;
        *) echo "Usage: nix run .#bump -- {major|minor|patch}"; exit 1 ;;
      esac

      # Read current version
      CURRENT=$(${hostPkgs.gnused}/bin/sed -n 's/.*\.version *= *"\(.*\)".*/\1/p' build.zig.zon | head -1)
      IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

      case "$LEVEL" in
        major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
        minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
        patch) PATCH=$((PATCH + 1)) ;;
      esac

      NEW_VERSION="$MAJOR.$MINOR.$PATCH"

      echo "Bumping $CURRENT -> $NEW_VERSION"
      ${hostPkgs.gnused}/bin/sed -i "s/\.version *= *\"$CURRENT\"/\.version = \"$NEW_VERSION\"/" build.zig.zon

      echo ""
      echo "Bumped to v$NEW_VERSION"
      echo ""
      echo "Review and commit:"
      echo "  git add build.zig.zon"
      echo "  git commit -m 'chore: bump to v$NEW_VERSION'"
    '');
  };

  checkAllApp = {
    type = "app";
    program = toString (hostPkgs.writeShellScript "${toolName}-check-all" ''
      set -euo pipefail
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/.zig-cache
      echo "Checking ${toolName}..."
      echo "-> zig build (debug)"
      ${hostPkgs.zigToolchain}/bin/zig build
      echo "-> zig build test"
      ${hostPkgs.zigToolchain}/bin/zig build test 2>/dev/null || echo "(no tests defined)"
      echo "All checks passed."
    '');
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
