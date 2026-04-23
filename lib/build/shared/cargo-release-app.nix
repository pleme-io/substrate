# Shared Cargo Release App Factory
#
# Extracted from the inline shell scripts that library.nix had been carrying
# since its inception. These apps wrap `cargo` (not `forge tool …`) because
# Rust library releases go to crates.io, not GitHub releases.
#
# Five apps produced:
#   - check-all  — cargo fmt --check + cargo clippy + cargo test
#   - bump       — cargo set-version --bump, regenerate Cargo.nix, git commit + tag
#   - publish    — cargo publish (with optional --dry-run)
#   - release    — bump + publish + push in one step
#   - regenerate — crate2nix generate
#
# Depends on: pkgs (for writeShellScript + cargo-edit/jq/git), crate2nix path.
#
# Usage:
#   cargoApps = import ./cargo-release-app.nix { inherit pkgs crate2nix; };
#   apps = cargoApps.mkCargoReleaseApps { name = "meimei"; };
{ pkgs, crate2nix }:

let
  # Resolve the cargo + toolchain binaries. Prefer fenix if the overlay is
  # applied; fall back to nixpkgs rustc/cargo otherwise so this works outside
  # the fenix flow too.
  cargo = pkgs.fenixRustToolchain or pkgs.cargo;
  cargoBin = "${cargo}/bin/cargo";
  # cargo subcommands (fmt, clippy, set-version) resolve via PATH, not
  # relative to cargo. Put the toolchain bin/ and cargo-edit's bin/ on
  # PATH so `cargo fmt` / `cargo clippy` / `cargo set-version` all route
  # to the bundled tools.
  toolchainPath = ''export PATH="${cargo}/bin:${pkgs.cargo-edit}/bin:${pkgs.git}/bin:$PATH"'';
in rec {
  # ── check-all ─────────────────────────────────────────────────────
  mkCheckAllApp = { name }: {
    type = "app";
    program = toString (pkgs.writeShellScript "${name}-check-all" ''
      set -euo pipefail
      ${toolchainPath}
      echo "Running checks for ${name}..."
      echo ""

      echo "==> cargo fmt --check"
      ${cargoBin} fmt --check
      echo ""

      echo "==> cargo clippy"
      ${cargoBin} clippy --all-targets -- -D warnings
      echo ""

      echo "==> cargo test"
      ${cargoBin} test
      echo ""

      echo "All checks passed."
    '');
  };

  # ── bump ──────────────────────────────────────────────────────────
  # Bumps version in Cargo.toml via cargo-edit, regenerates Cargo.nix,
  # and produces a `release: <name> v<version>` git commit + annotated tag.
  # Does NOT push — operator calls `git push && git push --tags` separately.
  mkBumpApp = { name }: {
    type = "app";
    program = toString (pkgs.writeShellScript "${name}-bump" ''
      set -euo pipefail
      ${toolchainPath}

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

      OLD_VERSION=$(${cargoBin} metadata --no-deps --format-version 1 | ${pkgs.jq}/bin/jq -r '.packages[0].version')
      echo "Current version: $OLD_VERSION"
      echo ""

      echo "==> cargo set-version --bump $BUMP_TYPE"
      ${pkgs.cargo-edit}/bin/cargo-set-version set-version --bump "$BUMP_TYPE"
      NEW_VERSION=$(${cargoBin} metadata --no-deps --format-version 1 | ${pkgs.jq}/bin/jq -r '.packages[0].version')
      echo ""

      echo "==> Regenerating Cargo.nix..."
      ${crate2nix.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/crate2nix generate
      echo ""

      # Update Cargo.lock (ignored if network-free check fails)
      ${cargoBin} check --quiet 2>/dev/null || true

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

  # ── publish ───────────────────────────────────────────────────────
  # Runs `cargo publish`. Accepts `--dry-run` to validate without uploading.
  # Refuses to publish when CARGO_REGISTRY_TOKEN is unset.
  mkPublishApp = { name }: {
    type = "app";
    program = toString (pkgs.writeShellScript "${name}-publish" ''
      set -euo pipefail
      ${toolchainPath}

      DRY_RUN=false
      for arg in "$@"; do
        case "$arg" in
          --dry-run) DRY_RUN=true ;;
        esac
      done

      if [ "$DRY_RUN" = "true" ]; then
        echo "Dry run: validating ${name} for crates.io..."
        ${cargoBin} publish --dry-run
        echo ""
        echo "Dry run passed. Ready to publish."
      else
        if [ -z "''${CARGO_REGISTRY_TOKEN:-}" ]; then
          echo "Error: CARGO_REGISTRY_TOKEN is not set."
          echo "Set it via: export CARGO_REGISTRY_TOKEN=<your-token>"
          exit 1
        fi
        echo "Publishing ${name} to crates.io..."
        ${cargoBin} publish
        echo ""
        echo "Published successfully."
      fi
    '');
  };

  # ── release ───────────────────────────────────────────────────────
  # Full one-shot: bump + publish + push. Used for "ship it now" moments.
  # Consult the bump/publish apps for the component details.
  mkReleaseApp = { name }: {
    type = "app";
    program = toString (pkgs.writeShellScript "${name}-release" ''
      set -euo pipefail
      ${toolchainPath}

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

      OLD_VERSION=$(${cargoBin} metadata --no-deps --format-version 1 | ${pkgs.jq}/bin/jq -r '.packages[0].version')
      echo "Current version: $OLD_VERSION"
      echo ""

      # Bump
      echo "==> cargo set-version --bump $BUMP_TYPE"
      ${pkgs.cargo-edit}/bin/cargo-set-version set-version --bump "$BUMP_TYPE"
      NEW_VERSION=$(${cargoBin} metadata --no-deps --format-version 1 | ${pkgs.jq}/bin/jq -r '.packages[0].version')
      echo ""

      echo "==> Regenerating Cargo.nix..."
      ${crate2nix.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/crate2nix generate
      ${cargoBin} check --quiet 2>/dev/null || true
      ${pkgs.git}/bin/git add Cargo.toml Cargo.lock Cargo.nix
      ${pkgs.git}/bin/git commit -m "release: ${name} v$NEW_VERSION"
      ${pkgs.git}/bin/git tag "v$NEW_VERSION"
      echo "Bumped $OLD_VERSION -> $NEW_VERSION"
      echo ""

      # Publish
      echo "==> cargo publish"
      ${cargoBin} publish
      echo ""

      # Push
      echo "==> git push && git push --tags"
      ${pkgs.git}/bin/git push
      ${pkgs.git}/bin/git push --tags
      echo ""

      echo "Released ${name} v$NEW_VERSION"
    '');
  };

  # ── regenerate ────────────────────────────────────────────────────
  mkRegenerateApp = { name }: {
    type = "app";
    program = toString (pkgs.writeShellScript "${name}-regenerate" ''
      set -euo pipefail
      echo "Regenerating Cargo.nix for ${name}..."
      ${crate2nix.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/crate2nix generate
      echo "Cargo.nix regenerated."
      echo ""
      echo "Don't forget to commit it:"
      echo "  git add Cargo.nix && git commit -m 'chore: regenerate Cargo.nix'"
    '');
  };

  # ── Combined factory ──────────────────────────────────────────────
  # Returns the full set of five library-lifecycle apps at once.
  mkCargoReleaseApps = { name }: {
    check-all = mkCheckAllApp { inherit name; };
    bump = mkBumpApp { inherit name; };
    publish = mkPublishApp { inherit name; };
    release = mkReleaseApp { inherit name; };
    regenerate = mkRegenerateApp { inherit name; };
  };
}
