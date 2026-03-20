# ============================================================================
# TYPESCRIPT LIBRARY BUILDER - Nix-based SDLC for TypeScript libraries
# ============================================================================
# Build verification, dev shells, and lifecycle apps.
# Uses dream2nix for dependency resolution from package-lock.json.
# No Docker, no deploy — libraries publish to npm.
#
# Usage in library flake.nix:
#   let tsLibrary = import "${substrate}/lib/typescript-library.nix" {
#     inherit system nixpkgs dream2nix;
#   };
#   in tsLibrary {
#     name = "pleme-types";
#     src = self;
#   }
#
# This returns: { packages, devShells, apps }
#
# Apps:
#   check-all  — biome + tsc + vitest
#   bump       — version bump (patch|minor|major), git commit + tag
#   publish    — build + npm publish
#   release    — bump + publish in one step
{
  nixpkgs,
  system,
  dream2nix,
  devenv ? null,
}: let
  pkgs = import nixpkgs { inherit system; };
in {
  name,
  src,
  version ? "1.0.0",
  nodeVersion ? pkgs.nodejs_22,
  extraDevInputs ? [],
  extraNativeBuildInputs ? [],
  buildScript ? "build",
}: let
  # dream2nix build — verifies the library compiles in Nix sandbox
  libraryModule = dream2nix.lib.evalModules {
    packageSets.nixpkgs = pkgs;
    modules = [
      {
        imports = [
          dream2nix.modules.dream2nix.nodejs-package-lock-v3
          dream2nix.modules.dream2nix.nodejs-granular-v3
        ];

        inherit name version;

        deps = {nixpkgs, ...}: {
          inherit (nixpkgs) stdenv;
          nodejs = nodeVersion;
        };

        mkDerivation = {
          inherit src;

          nativeBuildInputs = extraNativeBuildInputs;

          buildPhase = ''
            runHook preBuild
            npm run ${buildScript}
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp -r dist/* $out/
            cp package.json $out/
            cp README.md $out/ 2>/dev/null || true
            runHook postInstall
          '';
        };

        nodejs-package-lock-v3 = {
          packageLockFile = "${src}/package-lock.json";
        };

        paths = {
          projectRoot = src;
          projectRootFile = "flake.nix";
          package = src;
        };
      }
    ];
  };

  libraryBuild = libraryModule.config.public.out;

in {
  packages.default = libraryBuild;

  devShells.default = if devenv != null then
    devenv.lib.mkShell {
      inputs = { inherit nixpkgs; inherit devenv; };
      inherit pkgs;
      modules = [
        (import ../../devenv/web.nix)
        ({ ... }: {
          packages = [ pkgs.biome ] ++ extraDevInputs;
        })
      ];
    }
  else
    pkgs.mkShell {
      name = "${name}-dev";
      buildInputs = [
        nodeVersion
        pkgs.biome
      ] ++ extraDevInputs;
    };

  apps = {
    check-all = {
      type = "app";
      program = toString (pkgs.writeShellScript "${name}-check-all" ''
        set -euo pipefail
        echo "Running checks for ${name}..."
        echo ""

        echo "==> biome check"
        ${pkgs.biome}/bin/biome check --diagnostic-level=warn src
        echo ""

        echo "==> tsc --noEmit"
        npx tsc --noEmit
        echo ""

        echo "==> vitest run"
        npx vitest run
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
          major|minor|patch|premajor|preminor|prepatch|prerelease) ;;
          *)
            echo "Usage: nix run .#bump -- {major|minor|patch}"
            echo ""
            echo "Bumps version in package.json, commits, and tags."
            echo "Supports: major, minor, patch, premajor, preminor, prepatch, prerelease"
            exit 1
            ;;
        esac

        OLD_VERSION=$(${pkgs.jq}/bin/jq -r .version package.json)
        echo "Current version: $OLD_VERSION"
        echo ""

        echo "==> npm version $BUMP_TYPE"
        NEW_VERSION=$(npm version "$BUMP_TYPE" -m "release: ${name} v%s" --no-git-tag-version)
        echo ""

        # Update package-lock.json version to match
        if [ -f package-lock.json ]; then
          ${pkgs.jq}/bin/jq --arg v "''${NEW_VERSION#v}" '.version = $v | .packages[""].version = $v' package-lock.json > package-lock.json.tmp
          mv package-lock.json.tmp package-lock.json
        fi

        # Git commit + tag
        ${pkgs.git}/bin/git add package.json package-lock.json
        ${pkgs.git}/bin/git commit -m "release: ${name} $NEW_VERSION"
        ${pkgs.git}/bin/git tag "$NEW_VERSION"

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

        echo "==> npm run ${buildScript}"
        npm run ${buildScript}
        echo ""

        if [ "$DRY_RUN" = "true" ]; then
          echo "Dry run: validating ${name} for npm..."
          npm publish --access public --dry-run
          echo ""
          echo "Dry run passed. Ready to publish."
        else
          if [ -z "''${NPM_TOKEN:-}" ]; then
            echo "Error: NPM_TOKEN is not set."
            echo "Set it via: export NPM_TOKEN=<your-token>"
            exit 1
          fi
          echo "Publishing ${name} to npm..."
          npm publish --access public
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
          major|minor|patch|premajor|preminor|prepatch|prerelease) ;;
          *)
            echo "Usage: nix run .#release -- {major|minor|patch}"
            echo ""
            echo "Bumps version, builds, publishes, and pushes in one step."
            exit 1
            ;;
        esac

        if [ -z "''${NPM_TOKEN:-}" ]; then
          echo "Error: NPM_TOKEN is not set."
          echo "Set it via: export NPM_TOKEN=<your-token>"
          exit 1
        fi

        OLD_VERSION=$(${pkgs.jq}/bin/jq -r .version package.json)
        echo "Current version: $OLD_VERSION"
        echo ""

        # Bump
        echo "==> npm version $BUMP_TYPE"
        NEW_VERSION=$(npm version "$BUMP_TYPE" --no-git-tag-version)
        if [ -f package-lock.json ]; then
          ${pkgs.jq}/bin/jq --arg v "''${NEW_VERSION#v}" '.version = $v | .packages[""].version = $v' package-lock.json > package-lock.json.tmp
          mv package-lock.json.tmp package-lock.json
        fi
        ${pkgs.git}/bin/git add package.json package-lock.json
        ${pkgs.git}/bin/git commit -m "release: ${name} $NEW_VERSION"
        ${pkgs.git}/bin/git tag "$NEW_VERSION"
        echo "Bumped $OLD_VERSION -> $NEW_VERSION"
        echo ""

        # Build
        echo "==> npm run ${buildScript}"
        npm run ${buildScript}
        echo ""

        # Publish
        echo "==> npm publish --access public"
        npm publish --access public
        echo ""

        # Push
        echo "==> git push && git push --tags"
        ${pkgs.git}/bin/git push
        ${pkgs.git}/bin/git push --tags
        echo ""

        echo "Released ${name} $NEW_VERSION"
      '');
    };
  };
}
