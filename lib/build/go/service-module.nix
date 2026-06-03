# Go Service — Typed Module Definition
#
# NixOS-style option declarations for the Go service builder.
# This module defines every parameter with its type, default, and
# description. lib.evalModules validates user input against these
# options before the builder sees the arguments.
#
# Closes the daemon gap for general Go services: alongside the OCI
# image + port surface (image, port, env, replicas, healthcheck), it
# carries the systemd/launchd unit fields consumed by the module trio
# (../../module-trio.nix) so a Go service can be deployed both as a
# K8s image and as a host-level daemon. Mirrors the Go gRPC service
# module (./grpc-service-module.nix) in shape and the Rust service
# module (../rust/service-module.nix) in layering.
#
# Pure — depends only on nixpkgs lib.
#
# Usage:
#   eval = lib.evalModules {
#     modules = [
#       (import ./service-module.nix)
#       { config.substrate.go.service = userArgs; }
#     ];
#   };
#   spec = eval.config.substrate.go.service;
{ lib, ... }:

let
  inherit (lib) mkOption types;
in {
  options.substrate.go.service = {
    serviceName = mkOption {
      type = types.nonEmptyStr;
      description = "Service name (used for image naming, K8s labels, daemon unit name).";
    };

    src = mkOption {
      type = types.path;
      description = "Source directory containing go.mod.";
    };

    description = mkOption {
      type = types.str;
      default = "";
      apply = d: if d == "" then "Go service" else d;
      description = "Human-readable service description.";
    };

    version = mkOption {
      type = types.str;
      default = "0.1.0";
      description = "Service version (drives image tag + ldflags).";
    };

    vendorHash = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Go module vendor hash (null for in-tree vendor/).";
    };

    subPackages = mkOption {
      type = types.listOf types.str;
      default = [];
      apply = subs: if subs == [] then null else subs;
      description = "Go sub-packages to build. Auto-derived from serviceName if empty.";
    };

    ldflags = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra Go linker flags.";
    };

    # ── Container image + registry ──────────────────────────────────────
    registry = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Container registry (e.g. ghcr.io/pleme-io/my-go-service).";
    };

    architectures = mkOption {
      type = types.listOf (types.enum [ "amd64" "arm64" ]);
      default = [ "amd64" "arm64" ];
      description = "Docker image architectures to build.";
    };

    systems = mkOption {
      type = types.listOf types.str;
      default = [ "x86_64-linux" "aarch64-linux" ];
      description = "Build systems for the multi-arch image release.";
    };

    image = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Override OCI image name (defaults to serviceName).";
    };

    distroless = mkOption {
      type = types.bool;
      default = false;
      description = "Use the distroless base (cacert + tini, no busybox/shell).";
    };

    tini = mkOption {
      type = types.bool;
      default = true;
      description = "Include tini as PID 1 (only when distroless = true).";
    };

    sign = mkOption {
      type = types.bool;
      default = false;
      description = "Cosign keyless-sign the image after push.";
    };

    sbom = mkOption {
      type = types.bool;
      default = false;
      description = "Emit an SBOM attestation alongside the image.";
    };

    fipsBuild = mkOption {
      type = types.bool;
      default = false;
      description = "Build with Go BoringCrypto (GOEXPERIMENT=boringcrypto).";
    };

    labels = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Extra OCI labels merged into the standard annotation set.";
    };

    # ── Runtime surface ─────────────────────────────────────────────────
    port = mkOption {
      type = types.nullOr types.port;
      default = null;
      description = "Primary service port. Folded into `ports.http` when set.";
    };

    ports = mkOption {
      type = types.attrsOf types.port;
      default = { http = 8080; health = 8081; };
      description = "Service ports (name -> port).";
    };

    env = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Environment variables as NAME=VALUE strings.";
    };

    user = mkOption {
      type = types.str;
      default = "65534:65534";
      description = "Image runtime user (uid:gid).";
    };

    workDir = mkOption {
      type = types.str;
      default = "/app";
      description = "Image working directory.";
    };

    replicas = mkOption {
      type = types.ints.positive;
      default = 1;
      description = "Desired replica count (K8s deployment hint).";
    };

    configPath = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Path to the shikumi-go YAML config the service reads at startup.
        Threaded to the daemon as the <NAME>_CONFIG env var.
      '';
    };

    healthcheck = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          path = mkOption {
            type = types.str;
            default = "/healthz";
            description = "HTTP health-check path.";
          };
          port = mkOption {
            type = types.nullOr types.port;
            default = null;
            description = "Health-check port (defaults to ports.health).";
          };
          intervalSeconds = mkOption {
            type = types.ints.positive;
            default = 30;
            description = "Health-check interval in seconds.";
          };
          timeoutSeconds = mkOption {
            type = types.ints.positive;
            default = 5;
            description = "Health-check timeout in seconds.";
          };
        };
      });
      default = null;
      description = "HTTP health-check probe definition (null disables it).";
    };

    buildInputs = mkOption {
      type = types.listOf types.package;
      default = [];
      description = "Additional build-time library dependencies.";
    };

    # ── Daemon (systemd/launchd) unit fields — module trio ──────────────
    withSystemDaemon = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Emit a system-level daemon unit (NixOS systemd service +
        nix-darwin launchd daemon) via the module trio.
      '';
    };

    withUserDaemon = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Emit a user-level daemon (home-manager: systemd user unit on
        Linux, launchd agent on Darwin) via the module trio.
      '';
    };

    daemonSubcommand = mkOption {
      type = types.str;
      default = "daemon";
      description = "Subcommand the daemon unit invokes (`<binary> <subcommand>`).";
    };

    daemonExtraArgs = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra CLI args appended after the daemon subcommand.";
    };

    daemonEnv = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Environment variables for the daemon unit.";
    };
  };
}
