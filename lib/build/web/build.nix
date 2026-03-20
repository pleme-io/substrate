# Web Build Helpers - Vite, Dream2nix, Dev Shell, Package Outputs
# Build Vite/React applications with standardized configuration
{ pkgs }:

{
  # Build Vite/React applications with standardized configuration
  mkViteBuild = {
    appName,
    src,
    npmDepsHash,
    buildScript ? "build:staging",
    nodeVersion ? pkgs.nodejs_20,
    npmFlags ? [],
  }:
    pkgs.buildNpmPackage {
      pname = appName;
      version = "1.0.0";
      inherit src npmDepsHash npmFlags;

      nativeBuildInputs = with pkgs; [
        nodeVersion
        pkg-config
        python3
      ];

      buildInputs = with pkgs; [
        cairo pango pixman libjpeg giflib librsvg
      ];

      makeCacheWritable = true;
      npmDepsArgs = ["--legacy-peer-deps"];

      preBuild = ''
        export PKG_CONFIG_PATH="${pkgs.lib.makeSearchPath "lib/pkgconfig" [
          pkgs.cairo pkgs.pango pkgs.pixman pkgs.libjpeg pkgs.giflib pkgs.librsvg
        ]}"
        export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [
          pkgs.cairo pkgs.pango pkgs.pixman pkgs.libjpeg pkgs.giflib pkgs.librsvg
        ]}"
      '';

      buildPhase = ''
        export NODE_ENV=production
        export VITE_ENV=staging
        npm run ${buildScript}
      '';

      installPhase = ''
        mkdir -p $out
        cp -r dist/* $out/
      '';

      doCheck = false;
    };

  # Build Vite/React apps using dream2nix for automatic dependency resolution
  mkDream2nixBuild = {
    appName,
    src,
    buildScript ? "build:staging",
    nodeVersion ? pkgs.nodejs_20,
    dream2nix,
    packageLockFile ? null,
    version ? "1.0.0",
    npmFlags ? ["--legacy-peer-deps"],
  }: let
    lockFile = if packageLockFile != null then packageLockFile else "${src}/package-lock.json";

    viteAppModule = dream2nix.lib.evalModules {
      packageSets.nixpkgs = pkgs;
      modules = [
        {
          imports = [
            dream2nix.modules.dream2nix.nodejs-package-lock-v3
            dream2nix.modules.dream2nix.nodejs-granular-v3
          ];

          name = appName;
          inherit version;

          deps = {nixpkgs, ...}: {
            inherit (nixpkgs) stdenv;
            nodejs = nodeVersion;
          };

          mkDerivation = {
            inherit src;

            buildPhase = ''
              runHook preBuild
              export NODE_ENV=production
              export VITE_ENV=staging
              ${pkgs.lib.concatMapStringsSep "\n" (flag: "export npm_config_${pkgs.lib.removePrefix "--" flag}=true") npmFlags}
              npm run ${buildScript}
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out
              cp -r dist/* $out/
              runHook postInstall
            '';

            nativeBuildInputs = with pkgs; [nodeVersion pkg-config python3];
            buildInputs = with pkgs; [cairo pango pixman libjpeg giflib librsvg];
          };

          nodejs-package-lock-v3 = { packageLockFile = lockFile; };
          paths = { projectRoot = src; projectRootFile = "flake.nix"; package = src; };
        }
      ];
    };
  in viteAppModule.config.public.out;

  # Generate comprehensive web development shell
  mkWebDevShell = {
    appName,
    productName ? appName,
    extraPackages ? [],
    nodeVersion ? pkgs.nodejs_20,
  }:
    pkgs.mkShell {
      buildInputs = with pkgs; [
        git git-lfs
        nodeVersion
        nodePackages.pnpm nodePackages.npm nodePackages.typescript
        nodePackages.typescript-language-server nodePackages.vscode-langservers-extracted
        playwright-driver.browsers xvfb-run
        docker docker-compose skopeo
        kubectl kubernetes-helm k9s fluxcd
        nixpkgs-fmt nil
        jq yq curl wget htop
      ] ++ extraPackages;

      shellHook = ''
        echo "🌐 ${productName} Web Frontend Development"
        echo ""
        echo "🚀 Quick Start: npm install && npm run dev"
        echo "🧪 Testing: npm run test"
        echo "🐳 Local: nix run .#local"
        echo "🚢 Deploy: nix run .#release"
        echo ""
        export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
        export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true
        export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
        export NODE_ENV=development
        export PATH="$PWD/node_modules/.bin:$PATH"
        alias k=kubectl d=docker dc=docker-compose
      '';
    };

  # Generate standard package outputs for web applications
  mkWebPackages = { appName, builtApp, dockerImages }:
    { default = builtApp; "${appName}" = builtApp; viteApp = builtApp; } // dockerImages;

  # Generate local testing apps for web applications
  mkWebLocalApps = {
    appName,
    flakeAttr ? "dockerImage-amd64",
    composeFile ? null,
    port ? 8080,
  }: {
    local = {
      type = "app";
      program = toString (pkgs.writeShellScript "${appName}-local" ''
        set -e
        echo "🐳 Building Docker image..."
        nix build .#${flakeAttr}
        echo "📦 Loading image into Docker..."
        docker load < result
        ${if composeFile != null then ''
          echo "🚀 Starting docker-compose..."
          docker-compose -f ${composeFile} up -d
        '' else ''
          echo "🚀 Starting container..."
          docker run -d --name ${appName}-local -p ${toString port}:80 ${appName}:latest
        ''}
        echo ""
        echo "✅ ${appName} running at http://localhost:${toString port}"
      '');
    };

    local-down = {
      type = "app";
      program = toString (pkgs.writeShellScript "${appName}-local-down" ''
        set -e
        echo "🛑 Stopping..."
        ${if composeFile != null then ''
          docker-compose -f ${composeFile} down
        '' else ''
          docker stop ${appName}-local || true
          docker rm ${appName}-local || true
        ''}
        echo "✅ Stopped"
      '');
    };
  };
}
