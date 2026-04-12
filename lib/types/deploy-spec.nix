# Substrate Deploy Spec Types
#
# Typed specifications for deployment targets: container registries,
# architectures, clusters, and namespaces. Used by service builders
# and environment-aware deployment apps.
#
# Pure — depends only on nixpkgs lib.
{ lib }:

let
  inherit (lib) types mkOption;
  foundation = import ./foundation.nix { inherit lib; };
in rec {
  # ── Docker Image Spec ─────────────────────────────────────────────
  # Universal typed input for building container images across all
  # languages. Replaces the 4+ per-language Docker builders.
  dockerImageSpec = types.submodule {
    options = {
      name = mkOption {
        type = types.nonEmptyStr;
        description = "Image name (used in FROM, tags).";
      };
      binary = mkOption {
        type = types.package;
        description = "The built binary package to include.";
      };
      tag = mkOption {
        type = types.str;
        default = "latest";
        description = "Image tag.";
      };
      architecture = mkOption {
        type = foundation.architecture;
        default = "amd64";
      };
      ports = mkOption {
        type = types.attrsOf types.port;
        default = {};
        description = "Exposed ports ({ http = 8080; }).";
      };
      env = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Environment variables as 'NAME=VALUE' strings.";
      };
      user = mkOption {
        type = types.str;
        default = "65534:65534";
        description = "Container user:group (nobody by default).";
      };
      entrypoint = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "Container entrypoint (auto-derived from binary if null).";
      };
      extraContents = mkOption {
        type = types.listOf types.package;
        default = [];
        description = "Additional packages in the image (cacert is always included).";
      };
      workDir = mkOption {
        type = types.str;
        default = "/app";
      };
    };
  };

  # ── Deploy Target Spec ────────────────────────────────────────────
  deploySpec = types.submodule {
    options = {
      architectures = mkOption {
        type = types.listOf foundation.architecture;
        default = [ "amd64" "arm64" ];
        description = "Target architectures for multi-arch builds.";
      };
      registry = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Container registry URL (e.g. ghcr.io/pleme-io/auth).";
      };
      registryBase = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Registry base URL (combined with productName).";
      };
      productName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Product name for registry path.";
      };
      namespace = mkOption {
        type = types.str;
        default = "default";
        description = "Kubernetes namespace.";
      };
      cluster = mkOption {
        type = types.str;
        default = "staging";
        description = "Target cluster name.";
      };
    };
  };

  # ── Release Spec ──────────────────────────────────────────────────
  # Typed input for release automation apps (bump, publish, release).
  releaseSpec = types.submodule {
    options = {
      toolName = mkOption {
        type = types.nonEmptyStr;
        description = "Binary name for release artifacts.";
      };
      repo = mkOption {
        type = foundation.repoRef;
        description = "GitHub org/repo.";
      };
      targets = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Cross-compilation targets.";
      };
    };
  };
}
