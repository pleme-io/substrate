# substrate - Reusable Nix build patterns for service deployment
{
  description = "substrate - Reusable Nix build patterns for service deployment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    crate2nix = {
      url = "github:nix-community/crate2nix";
      flake = false;
    };
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    flake-parts,
    crate2nix,
    fenix,
    ...
  }: let
    systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    eachSystem = f: nixpkgs.lib.genAttrs systems f;
  in
    flake-parts.lib.mkFlake { inherit inputs; } {
      inherit systems;

      flake = {
        # Per-system library and overlay exports
        # Consumers access as: substrate.lib.${system}, substrate.rustOverlays.${system}.rust
        lib = eachSystem (system: let
          rustOverlay = import ./lib/rust-overlay.nix;
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ (rustOverlay.mkRustOverlay { inherit fenix system; }) ];
          };
        in import ./lib {
          inherit pkgs crate2nix;
          fenix = fenix.packages.${system};
        });

        # NOTE: Named `rustOverlays` (not `overlays`) because flake-parts reserves
        # `flake.overlays` for nixpkgs overlay functions (final: prev: { ... }).
        # Per-system attrsets like this would fail the overlay type check.
        rustOverlays = eachSystem (system: {
          rust = (import ./lib/rust-overlay.nix).mkRustOverlay { inherit fenix system; };
        });

        # Standalone import paths for consumer flakes
        rustToolReleaseFlakeBuilder = ./lib/rust-tool-release-flake.nix;
        zigToolReleaseFlakeBuilder = ./lib/zig-tool-release-flake.nix;

        # Rust overlay module for direct import
        rustOverlay = ./lib/rust-overlay.nix;

        # Flake-parts module factory for monorepo consumers
        monorepoPartsModule = ./lib/monorepo-parts.nix;

        # Expose library for non-system-specific usage
        libFor = {
          pkgs,
          forge ? null,
          system,
          fenix ? null,
        }:
          import ./lib {
            inherit pkgs system crate2nix fenix forge;
          };
      };
    };
}
