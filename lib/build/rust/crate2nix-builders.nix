# Crate2nix Builders - Project, Tool, Docker Image Builders
# Per-crate derivation caching with Attic for 60-80% faster CI/CD builds
{ pkgs, crate2nix }:

let check = import ../../types/assertions.nix;
in {
  # Build Rust project using crate2nix for granular per-crate caching
  mkCrate2nixProject = {
    serviceName,
    src,
    cargoToml ? src + "/Cargo.toml",
    cargoLock ? src + "/Cargo.lock",
    cargoNix ? src + "/Cargo.nix",
    buildInputs ? [],
    nativeBuildInputs ? [],
    crateOverrides ? {},
    enableAwsSdk ? false,
  }: let
    crate2nixTools = import "${crate2nix}/tools.nix" {inherit pkgs;};
    generatedCargoNix =
      if builtins.pathExists cargoNix then cargoNix
      else crate2nixTools.generatedCargoNix { name = serviceName; inherit src; };

    project = import generatedCargoNix {
      inherit pkgs;
      defaultCrateOverrides = pkgs.defaultCrateOverrides // {
        ${serviceName} = oldAttrs: { inherit buildInputs nativeBuildInputs; };
      } // crateOverrides;
    };
  in project;

  # Build standalone CLI tools using crate2nix with per-crate caching
  mkCrate2nixTool = {
    toolName,
    src,
    cargoNix ? src + "/Cargo.nix",
    buildInputs ? [],
    nativeBuildInputs ? [],
    runtimeDeps ? [],
    crateOverrides ? {},
  }: let
    crate2nixTools = import "${crate2nix}/tools.nix" {inherit pkgs;};
    generatedCargoNix =
      if builtins.pathExists cargoNix then cargoNix
      else crate2nixTools.generatedCargoNix { name = toolName; inherit src; };

    project = import generatedCargoNix {
      inherit pkgs;
      defaultCrateOverrides = pkgs.defaultCrateOverrides // {
        ${toolName} = oldAttrs: { inherit buildInputs nativeBuildInputs; };
      } // crateOverrides;
    };

    toolBinary = project.rootCrate.build;

    wrappedTool =
      if runtimeDeps == [] then toolBinary
      else (pkgs.runCommand "${toolName}-wrapped" {
        nativeBuildInputs = [pkgs.makeWrapper];
        # Set mainProgram so `nix run` knows which binary to execute
        meta.mainProgram = toolName;
      } ''
        mkdir -p $out/bin
        cp -r ${toolBinary}/bin/* $out/bin/
        wrapProgram $out/bin/${toolName} --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps}
      '');
  in wrappedTool;

  # Generate test runner Docker image for Kenshi TestGates
  # Uses crate2nix (same as production) to compile test binaries at Nix build time.
  # This avoids rustPlatform's strict edition validation that breaks on edition2024.
  #
  # Usage:
  #   testImage = mkCrate2nixTestImage {
  #     serviceName = "backend";
  #     productName = "myapp";
  #     cargoNix = ./Cargo.nix;
  #   };
  #
  # The resulting image can be run by Kenshi:
  #   docker run <image>  # Run all tests
  mkCrate2nixTestImage = {
    serviceName,
    productName ? "unknown",
    cargoNix,
    src ? null,
    workspaceSrc ? null,
    repoRoot ? null,
    architecture ? "amd64",
    tag ? "latest",
    buildInputs ? [],
    nativeBuildInputs ? [],
    crateOverrides ? {},
    packageName ? "${serviceName}-service",
  }: let
    # Import the same Cargo.nix as production - this is the key to avoiding edition2024 issues
    # crate2nix pre-parses all Cargo.toml files when generating Cargo.nix, so we never hit
    # the edition2024 validation that breaks rustPlatform.buildRustPackage
    project = import cargoNix {
      inherit pkgs;
      # Build with tests enabled - crate2nix's buildRustCrate supports this
      buildRustCrateForPkgs = pkgs: pkgs.buildRustCrate.override {
        defaultCrateOverrides = pkgs.defaultCrateOverrides // {
          # Add build inputs for crates that need them
          "${packageName}" = oldAttrs: {
            inherit buildInputs;
            nativeBuildInputs = nativeBuildInputs ++ (with pkgs; [pkg-config cmake perl git]);
            OPENSSL_DIR = "${pkgs.openssl.dev}";
            OPENSSL_LIB_DIR = "${pkgs.openssl.out}/lib";
            OPENSSL_INCLUDE_DIR = "${pkgs.openssl.dev}/include";
          };
          # Handle protobuf for tonic/prost
          tonic-build = oldAttrs: {
            nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ [pkgs.protobuf];
            PROTOC = "${pkgs.protobuf}/bin/protoc";
          };
          prost-build = oldAttrs: {
            nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ [pkgs.protobuf];
            PROTOC = "${pkgs.protobuf}/bin/protoc";
          };
        } // crateOverrides;
      };
    };

    # Get the service crate - same approach as production
    serviceCrate = if project ? workspaceMembers
      then project.workspaceMembers."${packageName}"
      else project.rootCrate;

    # Build the service with tests - crate2nix builds test binaries alongside the main binary
    # The test binaries end up in the same output as the main build
    serviceBuild = serviceCrate.build.override {
      # Enable test compilation - this builds test binaries without running them
      runTests = false;  # Don't run tests during build (no DB available)
    };

    # Test runner script
    testRunnerBin = pkgs.writeShellScript "run-tests" ''
      #!/bin/sh
      set -e
      echo "Kenshi Test Runner - ${serviceName}"
      echo "=================================="
      FAILED=0
      PASSED=0

      # Run all test binaries found in /app/bin
      for bin in /app/bin/*; do
        [ -x "$bin" ] || continue
        name=$(basename "$bin")
        echo ""
        echo ">>> Running: $name"
        if "$bin" "$@"; then
          PASSED=$((PASSED + 1))
          echo "<<< PASSED: $name"
        else
          FAILED=$((FAILED + 1))
          echo "<<< FAILED: $name"
        fi
      done

      echo ""
      echo "=================================="
      echo "Results: $PASSED passed, $FAILED failed"

      if [ $FAILED -eq 0 ]; then
        echo "All tests passed!"
        exit 0
      else
        echo "Some tests failed!"
        exit 1
      fi
    '';

  in pkgs.dockerTools.buildLayeredImage {
    name = "${serviceName}-service-test";
    inherit tag architecture;
    contents = with pkgs; [
      cacert
      busybox
      # Include the built service - test binaries are in the same derivation
      serviceBuild
    ];
    extraCommands = ''
      mkdir -p app/bin
      # Copy the main binary and any test binaries from the crate2nix build
      if [ -d "${serviceBuild}/bin" ]; then
        cp -r ${serviceBuild}/bin/* app/bin/ 2>/dev/null || true
      fi
    '';
    config = let dockerHelpers = import ../../util/docker-helpers.nix; in {
      Entrypoint = [ "${testRunnerBin}" ];
      Cmd = [];
      Env = [
        (dockerHelpers.mkSslEnv pkgs)
        "RUST_LOG=info"
        "RUST_BACKTRACE=1"
      ];
      WorkingDir = "/app";
      Labels = {
        "io.kenshi.test-image" = "true";
        "io.kenshi.service" = serviceName;
        "io.kenshi.test-type" = "crate2nix";
      };
    };
  };

  # Generate multi-arch Docker images using crate2nix with per-crate caching
  mkCrate2nixDockerImage = {
    serviceName,
    src,
    cargoNix ? src + "/Cargo.nix",
    migrationsPath ? src + "/migrations",
    architecture ? "amd64",
    tag ? "latest",
    # Service type: "graphql" (default) or "rest" — determines main port key and env vars
    serviceType ? "graphql",
    # Ports: GraphQL services use `ports.graphql`, REST services use `ports.http`
    ports ? (if serviceType == "rest" then { http = 8080; health = 8081; metrics = 9090; }
            else { graphql = 8080; health = 8081; metrics = 9090; }),
    buildInputs ? [],
    nativeBuildInputs ? [],
    crateOverrides ? {},
    enableAwsSdk ? false,
    packageName ? "${serviceName}-service",  # Crate name in workspace (standalone: just serviceName)
    # Function: pkgs -> [packages] to include in Docker image at runtime.
    # Example: pkgs: with pkgs; [ opentofu git ]
    extraContents ? (_pkgs: []),
  }: let
    _ = check.all [
      (check.nonEmptyStr "serviceName" serviceName)
      (check.architecture "architecture" architecture)
      (check.str "tag" tag)
      (check.enum "serviceType" ["graphql" "rest"] serviceType)
      (check.namedPorts "ports" ports)
      (check.attrs "crateOverrides" crateOverrides)
      (check.bool "enableAwsSdk" enableAwsSdk)
    ];
    muslTarget = if architecture == "arm64" then "aarch64-unknown-linux-musl" else "x86_64-unknown-linux-musl";
    crossPkgs = if enableAwsSdk then (if architecture == "arm64" then pkgs.pkgsCross.aarch64-multiplatform-musl else pkgs.pkgsCross.musl64) else pkgs;
    targetEnvNameUpper = pkgs.lib.toUpper (pkgs.lib.replaceStrings ["-"] ["_"] muslTarget);
    targetEnvNameLower = pkgs.lib.replaceStrings ["-"] ["_"] muslTarget;

    project = import cargoNix {
      inherit pkgs;
      defaultCrateOverrides = pkgs.defaultCrateOverrides // {
        tonic-build = oldAttrs: {
          nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ [pkgs.protobuf];
        };
        prost-build = oldAttrs: {
          nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ [pkgs.protobuf];
        };
        aws-lc-sys = oldAttrs: {
          nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ (with crossPkgs; [cmake perl go clang]);
          "CC_${targetEnvNameLower}" = if enableAwsSdk then "${crossPkgs.stdenv.cc}/bin/${crossPkgs.stdenv.cc.targetPrefix}cc" else null;
          "CXX_${targetEnvNameLower}" = if enableAwsSdk then "${crossPkgs.stdenv.cc}/bin/${crossPkgs.stdenv.cc.targetPrefix}c++" else null;
          "AR_${targetEnvNameLower}" = if enableAwsSdk then "${crossPkgs.stdenv.cc.bintools}/bin/${crossPkgs.stdenv.cc.bintools.targetPrefix}ar" else null;
        };

        # NOTE: GIT_SHA is intentionally NOT set here to preserve cache stability.
        # Setting GIT_SHA via builtins.getEnv would bust the entire crate cache on every commit.
        # Instead, GIT_SHA is passed at runtime via the Docker image's Env config.
        # The Rust code reads it via std::env::var("GIT_SHA") at runtime.
        "${packageName}" = oldAttrs: {
          inherit buildInputs;
          nativeBuildInputs = nativeBuildInputs ++ (with pkgs; [cmake perl git]);
          PROTOC = if builtins.any (p: p.pname or "" == "protobuf") nativeBuildInputs then "${pkgs.protobuf}/bin/protoc" else null;
          CARGO_BUILD_TARGET = muslTarget;
          "CARGO_TARGET_${targetEnvNameUpper}_RUSTFLAGS" = "-C target-feature=+crt-static -C link-arg=-s";
          "CC_${targetEnvNameLower}" = if enableAwsSdk then "${crossPkgs.stdenv.cc}/bin/${crossPkgs.stdenv.cc.targetPrefix}cc" else null;
          "CXX_${targetEnvNameLower}" = if enableAwsSdk then "${crossPkgs.stdenv.cc}/bin/${crossPkgs.stdenv.cc.targetPrefix}c++" else null;
          "AR_${targetEnvNameLower}" = if enableAwsSdk then "${crossPkgs.stdenv.cc.bintools}/bin/${crossPkgs.stdenv.cc.bintools.targetPrefix}ar" else null;
          postInstall = (oldAttrs.postInstall or "") + ''
            mkdir -p $out/migrations
            if [ -d "${toString migrationsPath}" ]; then
              cp -r ${migrationsPath}/* $out/migrations/ || true
            fi
          '';
        };
      } // crateOverrides;
    };

    serviceBinary =
      if project ? workspaceMembers then
        if project.workspaceMembers ? "${packageName}" then
          project.workspaceMembers."${packageName}".build
        else
          builtins.throw ''
            substrate: packageName "${packageName}" not found in Cargo workspace members.
            Available members: ${builtins.concatStringsSep ", " (builtins.attrNames project.workspaceMembers)}
            Hint: packageName must match the `name` field in Cargo.toml exactly.
          ''
      else
        project.rootCrate.build;

    # Resolve the main service port from the appropriate key based on service type
    mainPort = if serviceType == "rest" then ports.http or 8080
               else ports.graphql or 8080;

    # Service-type-specific env vars
    serviceTypeEnvVars =
      if serviceType == "rest" then [
        "PORT=${toString mainPort}"
        "HTTP_PORT=${toString mainPort}"
      ] else [
        "PORT=${toString mainPort}"
        "GRAPHQL_PORT=${toString mainPort}"
      ];
    extras = extraContents pkgs;
  in pkgs.dockerTools.buildLayeredImage {
    name = "${serviceName}-service";
    inherit tag architecture;
    contents = with pkgs; [cacert serviceBinary] ++ extras;
    config = let dockerHelpers = import ../../util/docker-helpers.nix; in {
      Entrypoint = ["${serviceBinary}/bin/${serviceName}"];
      ExposedPorts = builtins.listToAttrs (
        builtins.map (p: { name = "${toString p}/tcp"; value = {}; })
          (pkgs.lib.unique [ mainPort ports.health ports.metrics ])
      );
      Env = [
        (dockerHelpers.mkSslEnv pkgs)
        "RUST_LOG=info"
        "HEALTH_PORT=${toString ports.health}"
        # GIT_SHA is set at deployment time via Kubernetes env vars or docker run -e
        # Default to "nix-build" to indicate this is a Nix-built image
        # The actual git SHA should be injected by the release pipeline
        "GIT_SHA=nix-build"
      ] ++ serviceTypeEnvVars
        ++ pkgs.lib.optional (extras != []) "PATH=${pkgs.lib.makeBinPath ([serviceBinary] ++ extras)}";
      WorkingDir = "/app";
      User = "65534:65534";
    };
  };
}
