# ============================================================================
# TYPESCRIPT LIBRARY BUILDER - Nix-based SDLC for TypeScript libraries
# ============================================================================
# Build verification, dev shells, and check-all apps.
# Uses dream2nix for dependency resolution from package-lock.json.
# No Docker, no push, no deploy — libraries don't need them.
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
{
  nixpkgs,
  system,
  dream2nix,
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

  devShells.default = pkgs.mkShell {
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
  };
}
