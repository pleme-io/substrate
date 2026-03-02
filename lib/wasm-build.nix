# WASM Build Helpers - Yew/WASM applications with Fenix
# Build Rust WASM applications (Yew framework) with wasm-bindgen and wasm-opt
# Supports both nginx (legacy) and Hanabi (preferred) for serving WASM
{ pkgs, fenix, crate2nix }:

let
  # WASM target toolchain from fenix
  wasmToolchain = fenix.combine [
    fenix.latest.cargo
    fenix.latest.rustc
    fenix.targets.wasm32-unknown-unknown.latest.rust-std
  ];
in {
  # Build Yew/WASM applications with pure Nix
  mkWasmBuild = {
    name,
    src,
    cargoNix ? src + "/Cargo.nix",
    indexHtml ? src + "/index.html",
    staticAssets ? null,
    wasmBindgenTarget ? "web",
    optimizeLevel ? 3,
    crateOverrides ? {},
  }: let
    # Generate or use existing Cargo.nix
    crate2nixTools = import "${crate2nix}/tools.nix" { inherit pkgs; };
    generatedCargoNix =
      if builtins.pathExists cargoNix then cargoNix
      else crate2nixTools.generatedCargoNix { inherit name src; };

    # Build the WASM crate using crate2nix
    project = import generatedCargoNix {
      inherit pkgs;
      defaultCrateOverrides = pkgs.defaultCrateOverrides // {
        ${name} = oldAttrs: {
          nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ [
            wasmToolchain
          ];
          CARGO_BUILD_TARGET = "wasm32-unknown-unknown";
          RUSTFLAGS = "-C target-feature=+atomics,+bulk-memory,+mutable-globals";
        };
      } // crateOverrides;
    };

    wasmBinary = project.rootCrate.build;

    # Post-process WASM with wasm-bindgen and wasm-opt
  in pkgs.stdenv.mkDerivation {
    inherit name;
    src = wasmBinary;

    nativeBuildInputs = with pkgs; [
      wasm-bindgen-cli
      binaryen
    ];

    buildPhase = ''
      # Find the WASM file
      WASM_FILE=$(find . -name "*.wasm" -type f | head -1)
      if [ -z "$WASM_FILE" ]; then
        echo "No WASM file found in build output"
        exit 1
      fi

      echo "Processing WASM: $WASM_FILE"

      # Generate JS bindings with wasm-bindgen
      wasm-bindgen "$WASM_FILE" \
        --out-dir out \
        --target ${wasmBindgenTarget} \
        --no-typescript

      # Optimize WASM with wasm-opt
      wasm-opt -O${toString optimizeLevel} \
        out/*_bg.wasm \
        -o out/*_bg.wasm \
        --enable-bulk-memory \
        --enable-threads || true
    '';

    installPhase = ''
      mkdir -p $out

      # Copy wasm-bindgen output
      cp -r out/* $out/

      # Copy index.html if provided
      ${if builtins.pathExists indexHtml then ''
        cp ${indexHtml} $out/index.html
      '' else ''
        # Generate basic index.html
        cat > $out/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>${name}</title>
    <link rel="stylesheet" href="styles.css">
</head>
<body>
    <script type="module">
        import init from './${name}.js';
        init();
    </script>
</body>
</html>
EOF
      ''}

      # Copy static assets if provided
      ${if staticAssets != null then ''
        cp -r ${staticAssets}/* $out/ || true
      '' else ""}
    '';
  };

  # Build Docker image for serving WASM application
  mkWasmDockerImage = {
    name,
    wasmApp,
    tag ? "latest",
    architecture ? "amd64",
    port ? 80,
  }: pkgs.dockerTools.buildLayeredImage {
    inherit name tag architecture;
    contents = with pkgs; [
      nginx
      wasmApp
    ];

    extraCommands = ''
      mkdir -p var/log/nginx var/cache/nginx run
      chmod 755 var/log/nginx var/cache/nginx run

      # Create nginx config
      mkdir -p etc/nginx
      cat > etc/nginx/nginx.conf << 'EOF'
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    types {
        application/wasm wasm;
    }

    sendfile on;
    keepalive_timeout 65;
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/wasm;

    server {
        listen ${toString port};
        server_name _;
        root ${wasmApp};
        index index.html;

        location / {
            try_files $uri $uri/ /index.html;
        }

        # WASM MIME type and CORS headers
        location ~* \.wasm$ {
            add_header Content-Type application/wasm;
            add_header Cross-Origin-Opener-Policy same-origin;
            add_header Cross-Origin-Embedder-Policy require-corp;
        }
      }
}
EOF
    '';

    config = {
      Cmd = ["nginx" "-g" "daemon off;"];
      ExposedPorts = { "${toString port}/tcp" = {}; };
      Env = [
        "NGINX_PORT=${toString port}"
      ];
      WorkingDir = "/";
    };
  };

  # Generate dev shell for WASM development
  mkWasmDevShell = {
    name,
    extraPackages ? [],
  }: pkgs.mkShell {
    buildInputs = [
      wasmToolchain
      pkgs.wasm-bindgen-cli
      pkgs.binaryen
      pkgs.trunk
      pkgs.cargo-watch
    ] ++ extraPackages;

    shellHook = ''
      echo "🦀 ${name} WASM Development Environment"
      echo ""
      echo "🎯 Target: wasm32-unknown-unknown"
      echo "🔧 Tools: cargo, wasm-bindgen, wasm-opt, trunk"
      echo ""
      echo "🚀 Quick Start:"
      echo "   trunk serve    - Start dev server with hot reload"
      echo "   trunk build    - Build for production"
      echo ""
      export CARGO_TARGET_WASM32_UNKNOWN_UNKNOWN_RUNNER=""
    '';

    CARGO_BUILD_TARGET = "wasm32-unknown-unknown";
  };

  # Build Docker image for WASM application using Hanabi (花火) BFF server
  # Preferred over nginx - provides full-stack observability, health checks, compression
  mkWasmDockerImageWithHanabi = {
    name,
    wasmApp,
    webServer,  # Hanabi binary from crate2nix build
    tag ? "latest",
    architecture ? "amd64",
  }: pkgs.dockerTools.buildLayeredImage {
    inherit name tag architecture;

    contents = with pkgs; [
      webServer
      cacert
      curl
      busybox
    ];

    fakeRootCommands = (import ./docker-helpers.nix).mkWebUserSetup;

    extraCommands = let dockerHelpers = import ./docker-helpers.nix; in ''
      # Copy WASM app to /app/static (Hanabi's default static directory)
      mkdir -p app/static
      cp -r ${wasmApp}/* app/static/

      # Create required directories
      chmod -R 755 app/static
      ${dockerHelpers.mkTmpDirs}

      # Create Hanabi config for WASM serving
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
      Cmd = ["${webServer}/bin/hanabi"];
      ExposedPorts = {
        "80/tcp" = {};
        "8080/tcp" = {};
      };
      Env = [
        (import ./docker-helpers.nix).mkSslEnv pkgs
        "HANABI_CONFIG=/app/config/hanabi.yaml"
      ];
      WorkingDir = "/app/static";
      User = "web";
    };
  };

  # Expose the WASM toolchain for custom builds
  inherit wasmToolchain;
}
