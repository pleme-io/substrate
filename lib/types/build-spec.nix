# Substrate Build Spec Types
#
# Typed input specifications for builder functions. The base spec
# captures parameters common to ALL builders. Language-specific
# extensions add fields via submoduleWith composition.
#
# This is the Declare layer in convergence theory — the typed intent
# that gets resolved through module evaluation before reaching the
# builder function.
#
# Pure — depends only on nixpkgs lib.
{ lib }:

let
  inherit (lib) types mkOption;
  foundation = import ./foundation.nix { inherit lib; };
  portTypes = import ./ports.nix { inherit lib; };
in rec {
  # ── Base Build Spec ───────────────────────────────────────────────
  # Common to every builder regardless of language.
  buildSpecBase = {
    options = {
      name = mkOption {
        type = types.nonEmptyStr;
        description = "Project/crate/package name.";
      };
      src = mkOption {
        type = types.path;
        description = "Source directory.";
      };
      version = mkOption {
        type = types.str;
        default = "0.1.0";
        description = "Semantic version.";
      };
      buildInputs = mkOption {
        type = types.listOf types.package;
        default = [];
        description = "Build-time library dependencies.";
      };
      nativeBuildInputs = mkOption {
        type = types.listOf types.package;
        default = [];
        description = "Build-time tool dependencies (compilers, generators).";
      };
    };
  };

  # ── Rust Build Spec ───────────────────────────────────────────────
  rustBuildSpec = types.submoduleWith {
    modules = [ buildSpecBase {
      options = {
        cargoNix = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to Cargo.nix (auto-detected from src if null).";
        };
        crateOverrides = mkOption {
          type = types.attrsOf types.raw;
          default = {};
          description = "Per-crate build overrides for crate2nix.";
        };
        enableAwsSdk = mkOption {
          type = types.bool;
          default = false;
          description = "Include AWS SDK build dependencies.";
        };
        packageName = mkOption {
          type = types.nullOr types.nonEmptyStr;
          default = null;
          description = "Workspace member crate name (for workspace builds).";
        };
        repo = mkOption {
          type = types.nullOr foundation.repoRef;
          default = null;
          description = "GitHub org/repo for release publishing.";
        };
      };
    }];
  };

  # ── Rust Service Spec ─────────────────────────────────────────────
  rustServiceSpec = types.submoduleWith {
    modules = [ buildSpecBase {
      options = {
        serviceName = mkOption {
          type = types.nonEmptyStr;
          description = "Service name (used for image naming, K8s labels).";
        };
        serviceType = mkOption {
          type = foundation.serviceType;
          default = "graphql";
          description = "Protocol type (controls default ports).";
        };
        ports = mkOption {
          type = portTypes.flexiblePorts;
          default = {};
          description = "Service ports. Auto-generated from serviceType if empty.";
        };
        architectures = mkOption {
          type = types.listOf foundation.architecture;
          default = [ "amd64" "arm64" ];
          description = "Docker image architectures to build.";
        };
        registry = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Container registry (e.g. ghcr.io/pleme-io/auth).";
        };
        registryBase = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Registry base URL (combined with productName).";
        };
        productName = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Product name for registry path derivation.";
        };
        namespace = mkOption {
          type = types.str;
          default = "default";
          description = "Kubernetes namespace.";
        };
        cluster = mkOption {
          type = types.str;
          default = "staging";
          description = "Target cluster.";
        };
        cargoNix = mkOption {
          type = types.nullOr types.path;
          default = null;
        };
        crateOverrides = mkOption {
          type = types.attrsOf types.raw;
          default = {};
        };
        enableAwsSdk = mkOption {
          type = types.bool;
          default = false;
        };
        extraContents = mkOption {
          type = types.listOf types.package;
          default = [];
          description = "Additional packages to include in Docker image.";
        };
        description = mkOption {
          type = types.str;
          default = "";
        };
        extraDevInputs = mkOption {
          type = types.listOf types.package;
          default = [];
        };
        devEnvVars = mkOption {
          type = types.attrsOf types.str;
          default = {};
        };
      };
    }];
  };

  # ── Go Build Spec ─────────────────────────────────────────────────
  goBuildSpec = types.submoduleWith {
    modules = [ buildSpecBase {
      options = {
        vendorHash = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Go module vendor hash (null for in-tree vendor).";
        };
        subPackages = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          description = "Go sub-packages to build (e.g. [\"cmd/mytool\"]).";
        };
        ldflags = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          description = "Explicit linker flags.";
        };
        tags = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Go build tags.";
        };
        proxyVendor = mkOption {
          type = types.bool;
          default = false;
        };
        doCheck = mkOption {
          type = types.bool;
          default = false;
          description = "Run tests during build.";
        };
      };
    }];
  };

  # ── Go gRPC Service Spec ──────────────────────────────────────────
  goGrpcServiceSpec = types.submoduleWith {
    modules = [ buildSpecBase {
      options = {
        vendorHash = mkOption {
          type = types.nullOr types.str;
          default = null;
        };
        subPackages = mkOption {
          type = types.listOf types.str;
          default = [];
        };
        ports = mkOption {
          type = portTypes.flexiblePorts;
          default = { grpc = 50051; health = 8080; };
        };
        ldflags = mkOption {
          type = types.listOf types.str;
          default = [];
        };
        architecture = mkOption {
          type = foundation.architecture;
          default = "amd64";
        };
        env = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Environment variables as name=value strings.";
        };
        protobufDeps = mkOption {
          type = types.listOf types.package;
          default = [];
        };
      };
    }];
  };

  # ── TypeScript Build Spec ─────────────────────────────────────────
  typescriptBuildSpec = types.submoduleWith {
    modules = [ buildSpecBase {
      options = {
        cliEntry = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "CLI entry point (e.g. 'src/cli.ts').";
        };
        binName = mkOption {
          type = types.nullOr types.str;
          default = null;
        };
        buildScript = mkOption {
          type = types.str;
          default = "build";
          description = "npm script name for building.";
        };
        workspaceDeps = mkOption {
          type = types.attrsOf types.path;
          default = {};
        };
      };
    }];
  };

  # ── Ruby Build Spec ───────────────────────────────────────────────
  rubyBuildSpec = types.submoduleWith {
    modules = [ buildSpecBase {
      options = {
        shellHookExtra = mkOption {
          type = types.str;
          default = "";
        };
        devShellExtras = mkOption {
          type = types.listOf types.package;
          default = [];
        };
      };
    }];
  };

  # ── Zig Build Spec ───────────────────────────────────────────────
  zigBuildSpec = types.submoduleWith {
    modules = [ buildSpecBase {
      options = {
        repo = mkOption {
          type = foundation.repoRef;
          description = "GitHub org/repo for release publishing.";
        };
        deps = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Pre-fetched Zig dependencies.";
        };
        zigBuildFlags = mkOption {
          type = types.listOf types.str;
          default = [];
        };
      };
    }];
  };

  # ── Python Build Spec ─────────────────────────────────────────────
  pythonBuildSpec = types.submoduleWith {
    modules = [ buildSpecBase {
      options = {
        format = mkOption {
          type = types.enum [ "setuptools" "pyproject" "flit" "hatchling" ];
          default = "setuptools";
        };
        propagatedBuildInputs = mkOption {
          type = types.listOf types.package;
          default = [];
        };
        pythonImportsCheck = mkOption {
          type = types.listOf types.str;
          default = [];
        };
        doCheck = mkOption {
          type = types.bool;
          default = false;
        };
      };
    }];
  };

  # ── Web Build Spec ────────────────────────────────────────────────
  webBuildSpec = types.submoduleWith {
    modules = [ buildSpecBase {
      options = {
        npmDepsHash = mkOption {
          type = types.nullOr types.str;
          default = null;
        };
        buildScript = mkOption {
          type = types.str;
          default = "build:staging";
        };
        npmFlags = mkOption {
          type = types.listOf types.str;
          default = [];
        };
      };
    }];
  };

  # ── WASM Build Spec ───────────────────────────────────────────────
  wasmBuildSpec = types.submoduleWith {
    modules = [ buildSpecBase {
      options = {
        cargoNix = mkOption {
          type = types.nullOr types.path;
          default = null;
        };
        indexHtml = mkOption {
          type = types.nullOr types.path;
          default = null;
        };
        wasmBindgenTarget = mkOption {
          type = types.enum [ "web" "bundler" "nodejs" "no-modules" ];
          default = "web";
        };
        optimizeLevel = mkOption {
          type = types.ints.between 0 4;
          default = 3;
        };
        crateOverrides = mkOption {
          type = types.attrsOf types.raw;
          default = {};
        };
      };
    }];
  };

  # ── Spec Registry ─────────────────────────────────────────────────
  # Maps language names to their spec types for dynamic lookup.
  specsByLanguage = {
    rust = rustBuildSpec;
    rust-service = rustServiceSpec;
    go = goBuildSpec;
    go-grpc = goGrpcServiceSpec;
    zig = zigBuildSpec;
    typescript = typescriptBuildSpec;
    ruby = rubyBuildSpec;
    python = pythonBuildSpec;
    web = webBuildSpec;
    wasm = wasmBuildSpec;
  };
}
