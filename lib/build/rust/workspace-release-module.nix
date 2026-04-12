# Rust Workspace Release — Typed Module Definition
#
# Extends the tool-release module with packageName for workspace builds.
#
# Pure — depends only on nixpkgs lib.
{ lib, ... }:

let
  inherit (lib) mkOption types;
in {
  options.substrate.rust.workspace = {
    toolName = mkOption {
      type = types.nonEmptyStr;
      description = "CLI tool binary name.";
    };

    packageName = mkOption {
      type = types.nonEmptyStr;
      description = "Workspace member crate name to build (must match Cargo.toml name field).";
    };

    src = mkOption {
      type = types.path;
      description = "Source directory containing workspace Cargo.toml.";
    };

    repo = mkOption {
      type = types.strMatching "[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+";
      description = "GitHub org/repo for release publishing.";
    };

    cargoNix = mkOption {
      type = types.nullOr types.path;
      default = null;
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
