# ============================================================================
# WASI COMPONENT BUILDER - Rust source to WASI Component Model artifacts
# ============================================================================
# Compiles a Rust crate to wasm32-wasip2 and post-processes it into a WASI
# Component using wasm-tools. Extracts WIT interface definitions for
# interoperability with other WASI runtimes and component compositions.
#
# Uses stdenv.mkDerivation with cargo build --target wasm32-wasip2 (NOT
# crate2nix, which assumes native ELF output).
#
# Usage:
#   wasiComponent = import "${substrate}/lib/wasi-component.nix" {
#     inherit pkgs;
#     fenix = inputs.fenix.packages.${system};
#   };
#   result = wasiComponent {
#     name = "my-component";
#     src = ./.;
#   };
#   # result.component — WASI component (.component.wasm)
#   # result.wit — extracted WIT interface definitions
#   # result.wasmModule — raw compiled .wasm (pre-componentization)
#
# Returns: { component, wit, wasmModule }
{
  pkgs,
  fenix,
}:
{
  name,
  src,
  cargoArgs ? "",
}: let
  # Build the WASI Rust toolchain from fenix
  wasiToolchain = fenix.combine [
    fenix.stable.cargo
    fenix.stable.rustc
    fenix.targets.wasm32-wasip2.stable.rust-std
  ];

  # ============================================================================
  # RAW WASM MODULE BUILD
  # ============================================================================
  # Compile Rust source to wasm32-wasip2 (raw core module).
  wasmModule = pkgs.stdenv.mkDerivation {
    pname = "${name}-wasm";
    version = "0.1.0";
    inherit src;

    nativeBuildInputs = [
      wasiToolchain
      pkgs.binaryen
    ];

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

      # Optimize with wasm-opt before componentization
      wasm-opt -O3 "$WASM_FILE" -o "$out/lib/${name}.wasm"

      echo "Raw module: $out/lib/${name}.wasm ($(wc -c < "$out/lib/${name}.wasm") bytes)"

      runHook postInstall
    '';
  };

  # ============================================================================
  # WASI COMPONENT (wasm-tools component new)
  # ============================================================================
  # Transform the raw wasm module into a WASI Component.
  component = pkgs.stdenv.mkDerivation {
    pname = "${name}-component";
    version = "0.1.0";
    src = wasmModule;

    nativeBuildInputs = [
      pkgs.wasm-tools
    ];

    dontConfigure = true;
    dontInstall = false;

    buildPhase = ''
      runHook preBuild

      wasm-tools component new \
        lib/${name}.wasm \
        -o ${name}.component.wasm

      echo "Component: ${name}.component.wasm ($(wc -c < "${name}.component.wasm") bytes)"

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/lib
      cp ${name}.component.wasm $out/lib/

      runHook postInstall
    '';
  };

  # ============================================================================
  # WIT EXTRACTION (wasm-tools component wit)
  # ============================================================================
  # Extract WIT interface definitions from the component for documentation
  # and composition with other WASI components.
  wit = pkgs.stdenv.mkDerivation {
    pname = "${name}-wit";
    version = "0.1.0";
    src = component;

    nativeBuildInputs = [
      pkgs.wasm-tools
    ];

    dontConfigure = true;
    dontInstall = false;

    buildPhase = ''
      runHook preBuild

      wasm-tools component wit \
        lib/${name}.component.wasm \
        > ${name}.wit

      echo "WIT interface:"
      cat ${name}.wit

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/wit
      cp ${name}.wit $out/wit/

      runHook postInstall
    '';
  };

in {
  inherit component wit wasmModule;
}
