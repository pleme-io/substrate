# lib/util/versions.nix
#
# Single source of truth for all shared dependency versions across pleme-io.
#
# Every flake.nix that uses substrate consumes these versions instead of
# hardcoding URLs and revisions. When a version updates here, `tend` propagates
# the change across all repos via `nix flake update`.
#
# This file is the pluggable interface: add a new shared dependency by adding
# an entry here. All consumers inherit it automatically through substrate.
#
# Usage in substrate builders:
#   let versions = import ../util/versions.nix;
#   in versions.nixpkgs.branch  # "nixos-25.11"
#
# Usage in consumer flake.nix (via nix-place or manual):
#   inputs.nixpkgs.url = "github:NixOS/nixpkgs/${substrate.lib.versions.nixpkgs.branch}";
#

{
  # ── Core Platform ──────────────────────────────────────────────────────

  nixpkgs = {
    owner = "NixOS";
    repo = "nixpkgs";
    branch = "nixos-25.11";
    # The URL template for flake inputs
    url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  # ── Rust Tooling ───────────────────────────────────────────────────────

  rust-overlay = {
    owner = "oxalica";
    repo = "rust-overlay";
    url = "github:oxalica/rust-overlay";
    # Consumers MUST: inputs.rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  fenix = {
    owner = "nix-community";
    repo = "fenix";
    url = "github:nix-community/fenix";
    # Consumers MUST: inputs.fenix.inputs.nixpkgs.follows = "nixpkgs";
  };

  crate2nix = {
    owner = "nix-community";
    repo = "crate2nix";
    url = "github:nix-community/crate2nix";
    # Consumers MUST: inputs.crate2nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  crane = {
    owner = "ipetkov";
    repo = "crane";
    url = "github:ipetkov/crane";
    # Consumers MUST: inputs.crane.inputs.nixpkgs.follows = "nixpkgs";
  };

  # ── Nix Infrastructure ─────────────────────────────────────────────────

  flake-utils = {
    owner = "numtide";
    repo = "flake-utils";
    url = "github:numtide/flake-utils";
    # No nixpkgs dependency — no follows needed
  };

  sops-nix = {
    owner = "Mic92";
    repo = "sops-nix";
    url = "github:Mic92/sops-nix";
    # Consumers MUST: inputs.sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  home-manager = {
    owner = "nix-community";
    repo = "home-manager";
    url = "github:nix-community/home-manager";
    # Consumers MUST: inputs.home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  # ── pleme-io Shared ────────────────────────────────────────────────────

  substrate = {
    owner = "pleme-io";
    repo = "substrate";
    url = "github:pleme-io/substrate";
    # Consumers MUST: inputs.substrate.inputs.nixpkgs.follows = "nixpkgs";
  };

  forge = {
    owner = "pleme-io";
    repo = "forge";
    url = "github:pleme-io/forge";
    # Consumers MUST: inputs.forge.inputs.nixpkgs.follows = "nixpkgs";
  };

  # ── Build Configuration ────────────────────────────────────────────────

  rust = {
    # Minimum Rust version for all pleme-io projects
    minimumVersion = "1.89.0";
    edition = "2024";
    # Release profile defaults
    profile = {
      lto = true;
      codegen-units = 1;
      opt-level = "z";
      strip = true;
    };
  };

  docker = {
    # Default maxLayers for buildLayeredImage
    maxLayers = 120;
    # Never use UPX in containers
    useUpx = false;
  };

  # ── Helper: Generate flake input with follows ──────────────────────────
  #
  # Usage:
  #   inputs = versions.mkInputs {
  #     extra = {
  #       my-tool.url = "github:org/tool";
  #     };
  #   };
  #
  # Returns an attrset suitable for flake inputs with all follows pre-wired.
  #
  mkInputs = { extra ? {} }: let
    base = {
      nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
      substrate = {
        url = "github:pleme-io/substrate";
        inputs.nixpkgs.follows = "nixpkgs";
      };
      crate2nix = {
        url = "github:nix-community/crate2nix";
        inputs.nixpkgs.follows = "nixpkgs";
      };
      forge = {
        url = "github:pleme-io/forge";
        inputs.nixpkgs.follows = "nixpkgs";
      };
      flake-utils.url = "github:numtide/flake-utils";
    };
    # Merge extra inputs, auto-adding follows for any that have nixpkgs
    withFollows = builtins.mapAttrs (name: value:
      if builtins.isAttrs value && value ? url && !(value ? inputs)
      then value // { inputs.nixpkgs.follows = "nixpkgs"; }
      else value
    ) extra;
  in base // withFollows;
}
