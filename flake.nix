# substrate - Reusable Nix build patterns for service deployment
{
  description = "substrate - Reusable Nix build patterns for service deployment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    crate2nix = {
      url = "github:nix-community/crate2nix";
      flake = false;
    };
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    nixpkgs,
    crate2nix,
    flake-utils,
    fenix,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        # Import rust-overlay module (single source of truth)
        rustOverlay = import ./lib/rust-overlay.nix;

        # Override pkgs to use latest Rust stable (via fenix) for service builds
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (rustOverlay.mkRustOverlay { inherit fenix system; }) ];
        };
      in {
        # Expose the library with latest Rust stable from fenix
        lib = import ./lib {
          inherit pkgs crate2nix;
          fenix = fenix.packages.${system};
        };

        # Expose Rust overlay for services to use
        overlays.rust = rustOverlay.mkRustOverlay { inherit fenix system; };
      }
    )
    // {
      # Also expose library for non-system-specific usage
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
}
