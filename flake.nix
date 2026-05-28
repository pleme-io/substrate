# substrate - Reusable Nix build patterns for service deployment
{
  description = "substrate - Reusable Nix build patterns for service deployment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    # Consumer-facing surface re-export. Bundled here so consumer
    # flakes can drop `inputs.flake-utils.url = ...` and `inputs.
    # crate2nix.url = ...` etc. — substrate's pin propagates.
    flake-utils.url = "github:numtide/flake-utils";
    crate2nix = {
      url = "github:nix-community/crate2nix";
      flake = false;
    };
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # gen ships alongside substrate as part of the unified
    # dep-SDLC + build-SDLC surface. Consumers never declare
    # `inputs.gen` — substrate's `rust.{shape}` factories close
    # over substrate's gen pin and expose every `Adapter` verb
    # (lock / build / plan / confirm / diff / sbom) as flake apps
    # in the consumer's outputs.
    gen = {
      url = "github:pleme-io/gen";
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

        # Canonical Rust SDLC surface. Consumer flake.nix becomes:
        #
        #   {
        #     inputs.substrate.url = "github:pleme-io/substrate";
        #     outputs = { substrate, ... }: substrate.rust.tool {
        #       src = ./.;
        #     };
        #   }
        #
        # Four lines, total. Substrate pre-binds nixpkgs / crate2nix
        # / fenix / devenv / flake-utils / gen — every dependency
        # the build kit needs. Consumer overrides only the
        # differences (e.g. extra crateOverrides, custom buildInputs,
        # module spec). Same shape across every Rust variant
        # (`tool` / `workspace` / `library` / `service` / `binary`)
        # and (once npm + ruby adapters land) across every
        # ecosystem.
        #
        # The unified surface auto-wires every `Adapter` verb as a
        # flake app in the consumer's outputs: `nix run .#lock`,
        # `nix run .#build-spec`, `nix run .#plan`, `nix run .#confirm`,
        # `nix run .#diff`, `nix run .#sbom`. Six operator verbs for
        # zero consumer-side declaration.
        rust = let
          substrateInputs = {
            inherit nixpkgs crate2nix fenix;
            flake-utils = inputs.flake-utils;
            gen = inputs.gen;
            devenv = inputs.devenv or null;
            forge = inputs.forge or null;
          };
          callShape = shape: args:
            import ./lib/build/rust/mk-rust-tool-flake.nix (args // {
              inputs = (args.inputs or {}) // substrateInputs;
              shape = shape;
            });
        in {
          tool      = callShape "tool";
          workspace = callShape "workspace";
          library   = callShape "library";
          service   = callShape "service";
          binary    = callShape "binary";
        };

        # gen, exposed as a substrate-bound package. Consumers never
        # declare `inputs.gen` — the bump propagates fleet-wide via a
        # single substrate bump. Available as a top-level binary and
        # for IFD invocation inside `mkBuildSpec`.
        packages = eachSystem (system: {
          gen = inputs.gen.packages.${system}.default;
        });

        # Sibling ecosystem surfaces. Same shape as `rust` — every
        # ecosystem's Adapter implementations expose the same six
        # operator verbs through the same gen-driven IFD pipeline.
        # v1: routing stubs; substrate.{npm,ruby}.<shape> evaluates
        # but the per-ecosystem build wrappers are pending (they
        # follow the same tool-release / library / service shapes
        # as the rust side).
        #
        # The consumer-facing contract — same as rust — is:
        #
        #   {
        #     inputs.substrate.url = "github:pleme-io/substrate";
        #     outputs = { substrate, ... }: substrate.npm.tool { src = ./.; };
        #   }
        #
        # gen-npm + gen-bundler ship Adapter stubs today; when their
        # `build` impls land, every consumer that opts in lights up
        # without per-repo migration.
        npm = let
          shapeStub = shape: _args:
            throw "substrate.npm.${shape}: pending — gen-npm Adapter build impl lands in M1.";
        in {
          tool      = shapeStub "tool";
          workspace = shapeStub "workspace";
          library   = shapeStub "library";
          service   = shapeStub "service";
          binary    = shapeStub "binary";
        };

        ruby = let
          shapeStub = shape: _args:
            throw "substrate.ruby.${shape}: pending — gen-bundler Adapter build impl lands in M1.";
        in {
          tool      = shapeStub "tool";
          workspace = shapeStub "workspace";
          library   = shapeStub "library";
          service   = shapeStub "service";
          binary    = shapeStub "binary";
        };

        # Rust overlay module for direct import
        rustOverlay = ./lib/build/rust/overlay.nix;

        # Fleet-wide nixpkgs overlay that rewrites
        # crates.io/api/v1/.../download URLs into the canonical
        # static.crates.io CDN form. Catches every fetcher in the
        # closure — substrate's own lockfile-builder, nixpkgs'
        # built-in cargoSetupHook / fetchCargoVendor /
        # prefetch-npm-deps, and any third-party flake that
        # vendors Cargo deps via pkgs.fetchurl.
        # Consumer flakes compose into their nixpkgs.overlays list.
        overlays = {
          crates-io-cdn = import ./lib/build/rust/crates-io-cdn-overlay.nix;
        };

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
