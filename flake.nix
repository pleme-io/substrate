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
    # Fleet source-of-truth for devenv. Consumers of
    # rust-{tool,service,library}-flake.nix should set
    # `inputs.devenv.follows = "substrate/devenv"` rather than carry
    # their own URL. Recent devenv revs (bc8b216 / c429c11 / c58faa9)
    # eval-fail with `config.shell // {…}` on this nixpkgs pin;
    # a3ebee0 is the rev cartorio + lacre run on cleanly.
    devenv = {
      url = "github:cachix/devenv/a3ebee0b80ce56ae4acba2c971c09ee6eca75338";
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
        # Devenv modules for consumer repos
        # Import these in devenv.shells.default.imports or devenv.lib.mkShell modules
        devenvModules = {
          rust = ./lib/devenv/rust.nix;
          rust-service = ./lib/devenv/rust-service.nix;
          rust-tool = ./lib/devenv/rust-tool.nix;
          rust-library = ./lib/devenv/rust-library.nix;
          web = ./lib/devenv/web.nix;
          nix = ./lib/devenv/nix.nix;
          android = ./lib/devenv/android.nix;
          gitops = ./lib/devenv/gitops.nix;
          infrastructure = ./lib/devenv/infrastructure.nix;
        };

        # Per-system library and overlay exports
        # Consumers access as: substrate.lib.${system}, substrate.rustOverlays.${system}.rust
        lib = eachSystem (system: let
          rustOverlay = import ./lib/build/rust/overlay.nix;
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
          rust = (import ./lib/build/rust/overlay.nix).mkRustOverlay { inherit fenix system; };
        });

        # Home-manager tool module helpers (profile orchestration, safe packages)
        hmToolHelpers = ./lib/hm-tool-helpers.nix;

        # Standalone import paths for consumer flakes
        rustToolReleaseFlakeBuilder = ./lib/build/rust/tool-release-flake.nix;
        rustToolImageFlakeBuilder = ./lib/build/rust/tool-image-flake.nix;
        rustLibraryFlakeBuilder = ./lib/build/rust/library-flake.nix;
        zigToolReleaseFlakeBuilder = ./lib/build/zig/tool-release-flake.nix;

        # Zero-argument Rust-tool flake factory. Reads the consumer's
        # Cargo.toml to derive toolName + repo + packageName. Consumer
        # flake collapses to:
        #   outputs = i: i.substrate.mkRustToolFlake { src = i.self; inputs = i; };
        mkRustToolFlake = import ./lib/build/rust/mk-rust-tool-flake.nix;

        # Rust overlay module for direct import
        rustOverlay = ./lib/build/rust/overlay.nix;

        # Flake-parts module factory for monorepo consumers
        monorepoPartsModule = ./lib/util/monorepo-parts.nix;

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
