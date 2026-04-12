# Rust Service — Typed Module Definition
#
# NixOS-style option declarations for the Rust service builder.
# This module defines every parameter with its type, default, and
# description. lib.evalModules validates user input against these
# options before the builder sees the arguments.
#
# Pure — depends only on nixpkgs lib.
#
# Usage:
#   eval = lib.evalModules {
#     modules = [
#       (import ./service-module.nix)
#       { config.substrate.rust.service = userArgs; }
#     ];
#   };
#   spec = eval.config.substrate.rust.service;
{ lib, ... }:

let
  inherit (lib) mkOption types;
in {
  options.substrate.rust.service = {
    serviceName = mkOption {
      type = types.nonEmptyStr;
      description = "Service name (used for image naming, K8s labels, crate lookup).";
    };

    src = mkOption {
      type = types.path;
      description = "Source directory containing Cargo.toml.";
    };

    description = mkOption {
      type = types.str;
      default = "";
      apply = d: if d == "" then "Rust service" else d;
      description = "Human-readable service description.";
    };

    serviceType = mkOption {
      type = types.enum [ "graphql" "rest" ];
      default = "graphql";
      description = "Protocol type — controls default port naming.";
    };

    ports = mkOption {
      type = types.attrsOf types.port;
      default = {};
      description = "Service ports. Auto-generated from serviceType if empty.";
    };

    architectures = mkOption {
      type = types.listOf (types.enum [ "amd64" "arm64" ]);
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
      type = types.nullOr types.str;
      default = null;
      description = "Kubernetes namespace. Auto-derived from productName if null.";
    };

    cluster = mkOption {
      type = types.str;
      default = "staging";
      description = "Target cluster name.";
    };

    packageName = mkOption {
      type = types.nullOr types.nonEmptyStr;
      default = null;
      description = "Workspace member crate name. Auto-derived from serviceName if null.";
    };

    serviceDirRelative = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Relative path from repo root to service directory.";
    };

    cargoNix = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to Cargo.nix (auto-detected from src if null).";
    };

    repoRoot = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Repository root (for monorepo). Defaults to src.";
    };

    migrationsPath = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to SQL migrations. Defaults to src/migrations.";
    };

    buildInputs = mkOption {
      type = types.listOf types.package;
      default = [];
      description = "Additional build-time library dependencies.";
    };

    nativeBuildInputs = mkOption {
      type = types.listOf types.package;
      default = [];
      description = "Additional build-time tool dependencies.";
    };

    enableAwsSdk = mkOption {
      type = types.bool;
      default = false;
      description = "Include AWS SDK cross-compilation dependencies.";
    };

    extraDevInputs = mkOption {
      type = types.listOf types.package;
      default = [];
      description = "Extra packages for the development shell.";
    };

    devEnvVars = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Extra environment variables for the dev shell.";
    };

    extraContents = mkOption {
      type = types.raw;
      default = _pkgs: [];
      description = "Function: pkgs -> [packages] to include in Docker image.";
    };

    crateOverrides = mkOption {
      type = types.attrsOf types.raw;
      default = {};
      description = "Per-crate build overrides for crate2nix.";
    };
  };
}
