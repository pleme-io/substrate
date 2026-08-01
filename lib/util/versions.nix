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
  # ── SCOPE OF THIS WHOLE MODULE, counted 2026-08-02 ───────────────────────
  # The maxLayers note below is a symptom; this is the shape. `versions.nix` is
  # imported by exactly TWO files in the repo:
  #
  #   lib/build/rust/leptos-build.nix   (uses versions.docker.maxLayers, x2)
  #   lib/build/wasm/wasi-service.nix
  #
  # and reference counts for its nine top-level groups, across all of lib/:
  #
  #   versions.docker      3      versions.nixpkgs     1
  #   versions.crane       0      versions.crate2nix   0
  #   versions.fenix       0      versions.forge       0
  #   versions.mkInputs    0      versions.rust        0
  #   versions.substrate   0
  #
  # SEVEN OF NINE GROUPS ARE REFERENCED NOWHERE. Fleet-wide the picture is the
  # same: one file outside this module mentions any of the unused groups.
  #
  # So this is not "a default that one builder forgot to use" -- it is a
  # centralised version-pin module that centralises almost nothing, and the
  # maxLayers gap is what that looks like when one unwired constant finally
  # costs an image (cnpg-postgresql, never published, 101 > dockerTools' 100).
  #
  # The header above documents `let versions = import ../util/versions.nix;` as
  # THE usage pattern. Two files do it. Every other builder pins its own values
  # inline, and nothing detects the divergence -- an unimported Nix file is not
  # dead code the evaluator can see, it simply never participates.
  #
  # `pending-versions-adoption: 7 of 9 groups have zero consumers. Either wire
  #  them or delete the ones that were never real, but do not leave a module
  #  whose name promises fleet-wide pins and delivers two files.`
  #
    # ── "Default" REACHES 1 OF 5 BUILDERS (counted 2026-08-02) ──────────────
    # This says "Default maxLayers for buildLayeredImage" and it is not the
    # default of anything except leptos-build.nix. Every buildLayeredImage call
    # site in this repo, and whether it references this value:
    #
    #   lib/build/rust/leptos-build.nix   3 calls   USES it (2 references)
    #   lib/build/docker/node-image.nix   2 calls   does not
    #   lib/build/go/docker.nix           3 calls   does not
    #   lib/build/go/hardened-image.nix   1 call    does not
    #   lib/build/web/docker.nix          2 calls   does not
    #
    # The four that do not get dockerTools' OWN default, which is 100 -- not
    # 120. So this constant documents an intent that four fifths of the call
    # sites never see, and reading it gives a false picture of what the fleet
    # actually builds with.
    #
    # MEASURED CONSEQUENCE, not hypothetical: hardened-images'
    # `cnpg-postgresql` fails EVERY release at build time with
    #   Error: usedLayers 101 layers to store 'fromImage' and 'extraCommands',
    #          but only maxLayers=100 were allowed
    # and ghcr returns "Package not found" for it -- the image has NEVER
    # published. It needs exactly one more layer than dockerTools allows, and
    # the constant that would have given it twenty more was right here, unwired.
    #
    # NOT FLIPPED IN THIS PASS, deliberately. Raising maxLayers changes how a
    # closure is split into layers, which changes every layer digest and
    # therefore every image digest built through those four builders. That is a
    # fleet-wide rebuild and a cache invalidation, not a config tweak, and it
    # should be a deliberate act with someone watching the first rebuild --
    # not a side effect of fixing one image that has never shipped.
    #
    # `pending-maxlayers-wiring: 4 of 5 builders ignore this value. Wire them
    #  together, in one change, with the digest churn expected and announced.`
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
