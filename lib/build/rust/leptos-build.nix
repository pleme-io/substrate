# ============================================================================
# LEPTOS BUILD HELPERS - Dual-target SSR + CSR Leptos applications
# ============================================================================
# Build Leptos web applications with two compilation targets:
#   1. SSR server binary (native target via cargo build)
#   2. CSR WASM bundle (wasm32-unknown-unknown via wasm-bindgen + wasm-opt)
#
# The SSR binary serves the CSR WASM bundle from a static directory, enabling
# server-side rendering with client-side hydration.
#
# Supports both nginx (legacy) and Hanabi (preferred) for Docker deployments.
#
# Usage:
#   leptosBuilder = import "${substrate}/lib/leptos-build.nix" {
#     inherit pkgs fenix crate2nix;
#   };
#   result = leptosBuilder.mkLeptosBuild {
#     name = "lilitu-web";
#     src = ./.;
#   };
#   # result.ssrBinary   — native server binary
#   # result.csrBundle   — optimized WASM + JS + index.html
#   # result.combined    — SSR binary + CSR bundle ready for deployment
#   # result.packages    — { default, ssrBinary, csrBundle }
#   # result.devShell    — development environment
#
# Returns: { ssrBinary, csrBundle, combined, packages, devShell }
{ pkgs, fenix, crate2nix }:

let
  versions = import ../../util/versions.nix;
  dockerHelpers = import ../../util/docker-helpers.nix;

  # WASM target toolchain for CSR bundle
  wasmToolchain = fenix.combine [
    fenix.latest.cargo
    fenix.latest.rustc
    fenix.targets.wasm32-unknown-unknown.latest.rust-std
  ];

  # Native toolchain for SSR binary
  nativeToolchain = fenix.combine [
    fenix.latest.cargo
    fenix.latest.rustc
  ];
in {
  # ==========================================================================
  # mkLeptosBuild - Build a Leptos SSR+CSR application
  # ==========================================================================
  mkLeptosBuild = {
    name,
    src,
    # SSR configuration
    ssrBinaryName ? name,
    ssrCargoArgs ? "",
    ssrFeatures ? "ssr",
    # CSR configuration
    csrCargoArgs ? "",
    csrFeatures ? "hydrate",
    wasmBindgenTarget ? "web",
    optimizeLevel ? 3,
    # Asset configuration
    staticAssets ? null,
    indexHtml ? null,
    tailwindConfig ? null,
    # Build overrides
    crateOverrides ? {},
    extraNativeBuildInputs ? [],
  }: let
    # ========================================================================
    # CSR WASM BUNDLE
    # ========================================================================
    # Compile the client-side WASM bundle using cargo + wasm-bindgen + wasm-opt.
    # Uses stdenv.mkDerivation (not crate2nix) because crate2nix assumes native
    # ELF output, same approach as wasi-service.nix.
    csrBundle = pkgs.stdenv.mkDerivation {
      pname = "${name}-csr";
      version = "0.1.0";
      inherit src;

      nativeBuildInputs = [
        wasmToolchain
        pkgs.wasm-bindgen-cli
        pkgs.binaryen
      ] ++ extraNativeBuildInputs
        ++ pkgs.lib.optionals pkgs.stdenv.isDarwin (
          with pkgs.darwin.apple_sdk.frameworks; [
            Security SystemConfiguration CoreFoundation
          ]
        );

      dontConfigure = true;

      buildPhase = ''
        runHook preBuild

        export HOME=$(mktemp -d)
        export CARGO_HOME=$HOME/.cargo

        cargo build \
          --release \
          --target wasm32-unknown-unknown \
          ${pkgs.lib.optionalString (csrFeatures != "") "--features ${csrFeatures}"} \
          ${csrCargoArgs}

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        mkdir -p $out

        # Find the WASM output
        WASM_FILE=$(find target/wasm32-unknown-unknown/release -maxdepth 1 -name "*.wasm" -type f | head -1)
        if [ -z "$WASM_FILE" ]; then
          echo "ERROR: No .wasm file found in target/wasm32-unknown-unknown/release/"
          exit 1
        fi

        echo "Processing WASM: $WASM_FILE"

        # Generate JS bindings with wasm-bindgen
        wasm-bindgen "$WASM_FILE" \
          --out-dir $out/pkg \
          --target ${wasmBindgenTarget} \
          --no-typescript

        # Optimize WASM with wasm-opt
        WASM_BG=$(find $out/pkg -name "*_bg.wasm" -type f | head -1)
        if [ -n "$WASM_BG" ]; then
          wasm-opt -O${toString optimizeLevel} "$WASM_BG" -o "$WASM_BG" \
            --enable-bulk-memory || true
          echo "Optimized: $WASM_BG ($(wc -c < "$WASM_BG") bytes)"
        fi

        # Copy index.html if provided
        ${if indexHtml != null then ''
          cp ${indexHtml} $out/index.html
        '' else ""}

        # Copy static assets if provided
        ${if staticAssets != null then ''
          cp -r ${staticAssets}/* $out/ 2>/dev/null || true
        '' else ""}

        runHook postInstall
      '';
    };

    # ========================================================================
    # SSR SERVER BINARY
    # ========================================================================
    # Compile the server-side rendering binary for the native target.
    ssrBinary = pkgs.stdenv.mkDerivation {
      pname = "${name}-ssr";
      version = "0.1.0";
      inherit src;

      nativeBuildInputs = [
        nativeToolchain
        pkgs.pkg-config
        pkgs.openssl
      ] ++ extraNativeBuildInputs
        ++ pkgs.lib.optionals pkgs.stdenv.isDarwin (
          (with pkgs.darwin.apple_sdk.frameworks; [
            Security SystemConfiguration CoreFoundation
          ]) ++ [ pkgs.libiconv ]
        );

      dontConfigure = true;

      buildPhase = ''
        runHook preBuild

        export HOME=$(mktemp -d)
        export CARGO_HOME=$HOME/.cargo

        cargo build \
          --release \
          --bin ${ssrBinaryName} \
          ${pkgs.lib.optionalString (ssrFeatures != "") "--features ${ssrFeatures}"} \
          ${ssrCargoArgs}

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        mkdir -p $out/bin
        cp target/release/${ssrBinaryName} $out/bin/${ssrBinaryName}

        echo "SSR binary: $out/bin/${ssrBinaryName}"

        runHook postInstall
      '';
    };

    # ========================================================================
    # COMBINED OUTPUT
    # ========================================================================
    # SSR binary + CSR bundle in a single derivation ready for deployment.
    # The SSR binary serves the CSR bundle from /static (or configurable dir).
    combined = pkgs.stdenv.mkDerivation {
      pname = "${name}-combined";
      version = "0.1.0";
      dontUnpack = true;
      dontBuild = true;

      installPhase = ''
        mkdir -p $out/bin $out/static

        # Copy SSR binary
        cp ${ssrBinary}/bin/${ssrBinaryName} $out/bin/${ssrBinaryName}

        # Copy CSR WASM bundle
        cp -r ${csrBundle}/* $out/static/

        echo "Combined output:"
        echo "  Binary: $out/bin/${ssrBinaryName}"
        echo "  Static: $out/static/"
      '';
    };

  in {
    inherit ssrBinary csrBundle combined;

    packages = {
      default = combined;
      inherit ssrBinary csrBundle;
    };

    devShell = pkgs.mkShellNoCC {
      buildInputs = [
        wasmToolchain
        nativeToolchain
        pkgs.wasm-bindgen-cli
        pkgs.binaryen
        pkgs.trunk
        pkgs.cargo-watch
        pkgs.pkg-config
        pkgs.openssl
        pkgs.rust-analyzer
        pkgs.nodePackages.npm
        pkgs.tailwindcss
      ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin (
        (with pkgs.darwin.apple_sdk.frameworks; [
          Security SystemConfiguration CoreFoundation
        ]) ++ [ pkgs.libiconv ]
      );

      shellHook = ''
        echo "${name} Leptos Development Environment"
        echo ""
        echo "Targets: native (SSR) + wasm32-unknown-unknown (CSR)"
        echo "Tools: cargo, trunk, wasm-bindgen, wasm-opt, tailwindcss"
        echo ""
        echo "Development:"
        echo "  trunk serve          - CSR dev server with hot reload"
        echo "  cargo run --features ssr  - Run SSR server"
        echo ""
        echo "Production:"
        echo "  nix build            - Build combined SSR+CSR"
        echo ""
      '';
    };
  };

  # ==========================================================================
  # mkLeptosDockerImage - Docker image for Leptos SSR application
  # ==========================================================================
  # Packages the combined SSR+CSR build into a layered Docker image.
  # The SSR binary serves the CSR bundle directly.
  mkLeptosDockerImage = {
    name,
    leptosBuild,    # Output of mkLeptosBuild
    tag ? "latest",
    architecture ? "amd64",
    port ? 3000,
    healthPort ? 3001,
    extraContents ? [],
    extraEnv ? [],
  }: pkgs.dockerTools.buildLayeredImage {
    inherit name tag architecture;
    maxLayers = versions.docker.maxLayers;

    contents = [
      leptosBuild.combined
      pkgs.cacert
      pkgs.busybox
    ] ++ extraContents;

    fakeRootCommands = dockerHelpers.mkWebUserSetup;

    extraCommands = ''
      ${dockerHelpers.mkTmpDirs}
    '';

    config = {
      Cmd = [ "${leptosBuild.combined}/bin/${name}" ];
      ExposedPorts = {
        "${toString port}/tcp" = {};
        "${toString healthPort}/tcp" = {};
      };
      Env = [
        (dockerHelpers.mkSslEnv pkgs)
        "LEPTOS_SITE_ADDR=0.0.0.0:${toString port}"
        "LEPTOS_SITE_ROOT=/static"
        "RUST_LOG=info"
      ] ++ extraEnv;
      WorkingDir = "/";
      User = "web";
    };
  };

  # ==========================================================================
  # mkLeptosDockerImageWithHanabi - Leptos CSR-only served via Hanabi
  # ==========================================================================
  # For CSR-only deployments: serves the WASM bundle through Hanabi BFF.
  # Use this when you don't need SSR (pure client-side rendering).
  mkLeptosDockerImageWithHanabi = {
    name,
    csrBundle,      # Output of mkLeptosBuild.csrBundle
    webServer,      # Hanabi binary from crate2nix build
    tag ? "latest",
    architecture ? "amd64",
  }: pkgs.dockerTools.buildLayeredImage {
    inherit name tag architecture;
    maxLayers = versions.docker.maxLayers;

    contents = [
      webServer
      pkgs.cacert
      pkgs.curl
      pkgs.busybox
    ];

    fakeRootCommands = dockerHelpers.mkWebUserSetup;

    extraCommands = ''
      mkdir -p app/static
      cp -r ${csrBundle}/* app/static/
      chmod -R 755 app/static
      ${dockerHelpers.mkTmpDirs}

      mkdir -p app/config
      cat > app/config/hanabi.yaml << 'EOF'
server:
  static_dir: "/app/static"
  http_port: 80
  health_port: 8080
  request_timeout_secs: 30
  max_concurrent_connections: 10000

compression:
  enable_gzip: true
  enable_brotli: true

preflight:
  enabled: false
  critical_files: []
  index_html_path: "index.html"

cors:
  allowed_origins:
    - "*"
  allowed_methods:
    - "GET"
    - "POST"
    - "OPTIONS"
  allowed_headers:
    - "Content-Type"
    - "Accept"
  expose_headers: []
  max_age_secs: 3600
  allow_credentials: false
EOF
    '';

    config = {
      Cmd = [ "${webServer}/bin/hanabi" ];
      ExposedPorts = {
        "80/tcp" = {};
        "8080/tcp" = {};
      };
      Env = [
        (dockerHelpers.mkSslEnv pkgs)
        "HANABI_CONFIG=/app/config/hanabi.yaml"
      ];
      WorkingDir = "/app/static";
      User = "web";
    };
  };

  # Expose toolchains for custom builds
  inherit wasmToolchain nativeToolchain;
}
