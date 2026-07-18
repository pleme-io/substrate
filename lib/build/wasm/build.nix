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
  # Hardened by default (Pillar 8 / oci/hardened-base.nix). Only
  # `mkWasmDockerImageWithHanabi` (the Hanabi-serves-a-static-bundle
  # pattern) converts -- `mkWasmDockerImage` (nginx-based) is a
  # documented exception, see the comment at its call site below.
  hardened = import ../oci/hardened-base.nix { inherit pkgs; };
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
    check = import ../../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "name" name)
      (check.int "optimizeLevel" optimizeLevel)
      (check.attrs "crateOverrides" crateOverrides)
    ];
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
  #
  # DOCUMENTED EXCEPTION (not converted to oci/hardened-base.nix): this is
  # a full nginx runtime -- worker processes, a generated nginx.conf, and
  # writable var/log/nginx + var/cache/nginx + run dirs for the pidfile --
  # none of which any hardened-base.nix base was designed to host (they
  # assume a single package/binary + optional extraContents, not an nginx
  # master/worker tree with its own config/log/cache filesystem layout).
  # This module's own doc comment already marks nginx "legacy" in favor of
  # `mkWasmDockerImageWithHanabi` below (which DOES convert), so hardening
  # effort is better spent finishing that migration than propping up this
  # path. If nginx-based WASM serving is still needed after that, a
  # dedicated `hardened.bases.nginx`-shaped variant would be the right
  # follow-up -- not invented here.
  mkWasmDockerImage = {
    name,
    wasmApp,
    tag ? "latest",
    architecture ? "amd64",
    port ? 80,
  }: let
    check = import ../../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "name" name)
      (check.str "tag" tag)
      (check.architecture "architecture" architecture)
      (check.port "port" port)
    ];
  in pkgs.dockerTools.buildLayeredImage {
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
  }: let
    check = import ../../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "name" name)
      (check.list "extraPackages" extraPackages)
    ];
  in pkgs.mkShell {
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
  }: let
    check = import ../../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "name" name)
      (check.str "tag" tag)
      (check.architecture "architecture" architecture)
    ];
    # Same Hanabi-serves-a-static-bundle pattern as shared/docker-image.nix's
    # mkWebDockerImage / leptos-build.nix's mkLeptosDockerImageWithHanabi --
    # `extraCommands`+`fakeRootCommands` do real content-merge + custom-user
    # work `mkPackageImage` can't express, so this stays a direct
    # `buildLayeredImage` call; `wolfi` is a strict superset of the old
    # ad-hoc `[cacert curl busybox]`.
    imageContents = with pkgs; [ webServer curl ];
  in pkgs.dockerTools.buildLayeredImage {
    inherit name tag architecture;

    fromImage = hardened.bases.wolfi;
    contents = imageContents;

    fakeRootCommands = (import ../../util/docker-helpers.nix).mkWebUserSetup;

    extraCommands = let dockerHelpers = import ../../util/docker-helpers.nix; in ''
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
        # Parens force the function application -- inside a Nix list
        # literal each element parses at `expr_select` precedence, so
        # without them this was TWO separate list elements (the unapplied
        # function value + `pkgs`), not one string; found while converting
        # this function's base to the hardened primitive (pre-existing,
        # unrelated to the base swap -- `web/docker.nix`'s mkNodeDockerImage
        # already carries the same fix, with an identical comment).
        ((import ../../util/docker-helpers.nix).mkSslEnv pkgs)
        "HANABI_CONFIG=/app/config/hanabi.yaml"
      ];
      WorkingDir = "/app/static";
      User = "web";
    };
  } // {
    closureInfo = pkgs.closureInfo {
      rootPaths = (hardened.bases.wolfi.contents or []) ++ imageContents;
    };
  };

  # Expose the WASM toolchain for custom builds
  inherit wasmToolchain;
}
