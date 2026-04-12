# Rust Tool Release — Typed Module Definition
#
# NixOS-style option declarations for the Rust CLI tool builder.
# Validates inputs before the builder constructs 4-target derivations.
#
# Pure — depends only on nixpkgs lib.
{ lib, ... }:

let
  inherit (lib) mkOption types;
in {
  options.substrate.rust.tool = {
    toolName = mkOption {
      type = types.nonEmptyStr;
      description = "CLI tool binary name.";
    };

    src = mkOption {
      type = types.path;
      description = "Source directory containing Cargo.toml.";
    };

    repo = mkOption {
      type = types.strMatching "[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+";
      description = "GitHub org/repo for release publishing (e.g. 'pleme-io/kindling').";
    };

    cargoNix = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to Cargo.nix (auto-detected from src if null).";
    };

    buildInputs = mkOption {
      type = types.listOf types.package;
      default = [];
    };

    nativeBuildInputs = mkOption {
      type = types.listOf types.package;
      default = [];
    };

    crateOverrides = mkOption {
      type = types.attrsOf types.raw;
      default = {};
    };
  };
}
