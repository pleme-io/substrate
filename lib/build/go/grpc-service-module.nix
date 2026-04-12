# Go gRPC Service — Typed Module Definition
#
# NixOS-style option declarations for the Go gRPC service builder.
#
# Pure — depends only on nixpkgs lib.
{ lib, ... }:

let
  inherit (lib) mkOption types;
in {
  options.substrate.go.grpcService = {
    name = mkOption {
      type = types.nonEmptyStr;
      description = "Service name.";
    };

    src = mkOption {
      type = types.path;
      description = "Source directory containing go.mod.";
    };

    version = mkOption {
      type = types.str;
      default = "0.1.0";
    };

    vendorHash = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Go module vendor hash (null for in-tree vendor).";
    };

    subPackages = mkOption {
      type = types.listOf types.str;
      default = [];
      apply = subs: if subs == [] then null else subs;
      description = "Go sub-packages to build.";
    };

    ports = mkOption {
      type = types.attrsOf types.port;
      default = { grpc = 50051; health = 8080; };
      description = "Service ports.";
    };

    ldflags = mkOption {
      type = types.listOf types.str;
      default = [];
    };

    buildInputs = mkOption {
      type = types.listOf types.package;
      default = [];
    };

    nativeBuildInputs = mkOption {
      type = types.listOf types.package;
      default = [];
    };

    architecture = mkOption {
      type = types.enum [ "amd64" "arm64" ];
      default = "amd64";
    };

    env = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Environment variables as NAME=VALUE strings.";
    };

    protobufDeps = mkOption {
      type = types.listOf types.package;
      default = [];
    };
  };
}
