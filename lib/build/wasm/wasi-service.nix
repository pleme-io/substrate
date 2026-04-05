# ============================================================================
# WASI SERVICE BUILDER - Rust source to wasm32-wasip2 Docker image
# ============================================================================
# Compiles a Rust crate to wasm32-wasip2, optimizes with wasm-opt, and packages
# the .wasm module alongside wasmtime in a layered Docker image.
#
# Uses stdenv.mkDerivation with cargo build --target wasm32-wasip2 (NOT
# crate2nix, which assumes native ELF output).
#
# Docker image layout (two logical layers via buildLayeredImage):
#   Layer 1 (cached, heavy ~50MB): wasmtime binary + cacert
#   Layer 2 (tiny, changes often): .wasm module
#
# Usage:
#   wasiService = import "${substrate}/lib/wasi-service.nix" {
#     inherit pkgs;
#     fenix = inputs.fenix.packages.${system};
#   };
#   result = wasiService {
#     name = "my-wasi-service";
#     src = ./.;
#     wasiCapabilities = [ "network" "env" ];
#   };
#   # result.wasmModule — optimized .wasm derivation
#   # result.dockerImage — layered Docker image with wasmtime + .wasm
#   # result.devShell — development environment
#
# Returns: { wasmModule, dockerImage, devShell }
{
  pkgs,
  fenix,
  wasiOverlay ? null,
}:
{
  name,
  src,
  cargoArgs ? "",
  wasiCapabilities ? [ "network" "env" ],
  extraContents ? [],
  tag ? "latest",
  architecture ? "amd64",
}: let
  versions = import ../../util/versions.nix;
  dockerHelpers = import ../../util/docker-helpers.nix;

  # Build the WASI Rust toolchain from fenix
  wasiToolchain = fenix.combine [
    fenix.stable.cargo
    fenix.stable.rustc
    fenix.targets.wasm32-wasip2.stable.rust-std
  ];

  # ============================================================================
  # WASM MODULE BUILD
  # ============================================================================
  # Compile Rust source to wasm32-wasip2 and optimize with wasm-opt.
  wasmModule = pkgs.stdenv.mkDerivation {
    pname = "${name}-wasm";
    version = "0.1.0";
    inherit src;

    nativeBuildInputs = [
      wasiToolchain
      pkgs.binaryen  # provides wasm-opt
    ];

    # Disable default configure/install phases — we only need build
    dontConfigure = true;
    dontInstall = false;

    buildPhase = ''
      runHook preBuild

      export HOME=$(mktemp -d)
      export CARGO_HOME=$HOME/.cargo

      cargo build \
        --release \
        --target wasm32-wasip2 \
        ${cargoArgs}

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/lib

      # Find and copy the .wasm output
      WASM_FILE=$(find target/wasm32-wasip2/release -maxdepth 1 -name "*.wasm" -type f | head -1)
      if [ -z "$WASM_FILE" ]; then
        echo "ERROR: No .wasm file found in target/wasm32-wasip2/release/"
        exit 1
      fi

      echo "Optimizing WASM: $WASM_FILE"

      # Optimize with wasm-opt -O3
      wasm-opt -O3 "$WASM_FILE" -o "$out/lib/${name}.wasm"

      echo "Output: $out/lib/${name}.wasm ($(wc -c < "$out/lib/${name}.wasm") bytes)"

      runHook postInstall
    '';
  };

  # ============================================================================
  # WASI CAPABILITY FLAGS
  # ============================================================================
  # Map capability names to wasmtime CLI flags
  capabilityFlags = builtins.concatStringsSep " " (map (cap:
    if cap == "network" then "--wasi inherit-network"
    else if cap == "env" then "--wasi inherit-env"
    else if cap == "stdio" then "--wasi inherit-stdio"
    else if cap == "filesystem" then "--wasi inherit-filesystem"
    else if cap == "clocks" then "--wasi inherit-clocks"
    else if cap == "random" then "--wasi inherit-random"
    else if cap == "exit" then "--wasi inherit-exit"
    else "--wasi inherit-${cap}"
  ) wasiCapabilities);

  # ============================================================================
  # DOCKER IMAGE
  # ============================================================================
  # Layered image: wasmtime + cacert (heavy, cached) and .wasm module (light).
  # Architecture is always for the native host (wasmtime is the native binary).
  dockerImage = pkgs.dockerTools.buildLayeredImage {
    inherit name tag architecture;
    maxLayers = versions.docker.maxLayers;

    contents = [
      pkgs.wasmtime
      pkgs.cacert
      wasmModule
    ] ++ extraContents;

    config = {
      Entrypoint = [
        "${pkgs.wasmtime}/bin/wasmtime"
        "run"
      ] ++ (if capabilityFlags != "" then pkgs.lib.splitString " " capabilityFlags else [])
        ++ [ "/lib/${name}.wasm" ];
      Env = [
        (dockerHelpers.mkSslEnv pkgs)
        "RUST_LOG=info"
      ];
      WorkingDir = "/";
      User = "65534:65534";
    };
  };

  # ============================================================================
  # DEVELOPMENT SHELL
  # ============================================================================
  devShell = pkgs.mkShell {
    buildInputs = [
      wasiToolchain
      pkgs.wasmtime
      pkgs.wasm-tools
      pkgs.wasmer
      pkgs.binaryen
      pkgs.rust-analyzer
    ];

    shellHook = ''
      echo "${name} WASI Development Environment"
      echo ""
      echo "Target: wasm32-wasip2"
      echo "Tools: cargo, wasmtime, wasm-tools, wasmer, wasm-opt"
      echo ""
      echo "Build:  cargo build --target wasm32-wasip2 --release"
      echo "Run:    wasmtime run ${capabilityFlags} target/wasm32-wasip2/release/${name}.wasm"
      echo ""
    '';

    CARGO_BUILD_TARGET = "wasm32-wasip2";
  };

in {
  inherit wasmModule dockerImage devShell;
}
