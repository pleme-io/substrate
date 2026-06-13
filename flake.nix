# substrate - Reusable Nix build patterns for service deployment
{
  description = "substrate - Reusable Nix build patterns for service deployment";

  inputs = {
    # THE fleet nixpkgs anchor. Pinned to a concrete nixos-26.05 rev (not the
    # floating branch) so substrate is the single source of truth: every repo
    # does `nixpkgs.follows = "substrate/nixpkgs"` and gets THIS exact rev,
    # regardless of when it last locked. Bump here = one deliberate fleet-wide
    # nixpkgs move (then `nix flake update substrate` across the fleet).
    #
    # 26.05.20260603 (2026-06-03), chosen CONTEMPORANEOUS with the nix-darwin +
    # home-manager pins below — it is home-manager release-26.05's own tested
    # nixpkgs, so the whole tuple `nix flake check`s clean with zero release
    # skew. (The prior anchor addf7cf was 26.05.20251208 — same release LABEL
    # but ~6 months older and incompatible with current home-manager, which
    # imports lib/services/lib.nix that postdated it. Aligning by label ≠ by
    # commit; the tuple must be pinned to commits that go perfectly together.)
    nixpkgs.url = "github:NixOS/nixpkgs/6b316287bae2ee04c9b93c8c858d930fd07d7338";
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
    # gen is INTENTIONALLY NOT a flake input.
    #
    # gen's own flake builds itself via `substrate.mkRustToolFlake`, so
    # `inputs.gen` created a substrate↔gen FLAKE-INPUT CYCLE
    # (gen → substrate → gen → …) that Nix unrolls, growing this
    # flake.lock by ~64 nodes on every lock bump (history: monotonic
    # +128 lines per lock update; the lock had bloated past 2600 nodes).
    #
    # Instead, gen is built FROM A PINNED SOURCE
    # (`lib/build/rust/gen-pin.json` — rev + sha256) using substrate's
    # OWN tool-builder (`self.mkRustToolFlake`). No `inputs.gen` ⇒ no
    # cycle ⇒ the lock collapses to a small, stable size. Bumping gen is
    # a 2-line edit to `gen-pin.json` (rev + sha256) — NO lock growth.
    #
    # The same `gen-pin.json` rev is read by the four IFD auto-fetch
    # sites in `lib/build/rust/` (tool-release-flake / workspace-release-
    # flake / mk-rust-tool-flake / lockfile-builder) so downstream
    # consumers that hit the IFD fallback still resolve substrate's
    # pinned gen rev. Those `getFlake`-at-rev fetches happen at
    # IFD/eval time and do NOT grow any lock.
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
    # THE fleet's nix-darwin + home-manager pins. Both are the 26.05
    # release line — release-aligned to the nixpkgs anchor above so the
    # whole tuple (nixpkgs + nix-darwin + home-manager) moves together.
    # Each follows substrate's nixpkgs, so the single nixpkgs commit is
    # shared across all three (no skew, perfectly-together tuple).
    # Consumers do `nix-darwin.follows = "substrate/nix-darwin"` and
    # `home-manager.follows = "substrate/home-manager"` to inherit THESE
    # exact revs. Bump here = one deliberate fleet-wide move.
    nix-darwin = {
      url = "github:LnL7/nix-darwin/731951a251ca96cbd12a8e1bde63737e21947644";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/4eb4fec41674d5b059aa2eedf0f98453890546fa";
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

    # ── gen, built from a PINNED SOURCE (no flake input → no cycle) ──
    #
    # `inputs.gen` was removed to break the substrate↔gen flake-input
    # cycle that grew this lock unboundedly (see the inputs comment).
    # gen is rebuilt here from a pinned tarball via substrate's OWN
    # tool-builder, producing a derivation byte-identical to the old
    # `inputs.gen.packages.${system}.default` for the same gen rev.
    #
    # `gen-pin.json` (rev + sha256) is the single source of truth for
    # the gen pin — bump = edit those two fields, NO lock growth.
    genPin = builtins.fromJSON (builtins.readFile ./lib/build/rust/gen-pin.json);
    # FOD fetch — system-independent (content-addressed by sha256), so a
    # single fetch serves every system.
    genSrc = (import nixpkgs { system = builtins.head systems; }).fetchFromGitHub {
      owner = "pleme-io";
      repo = "gen";
      rev = genPin.rev;
      sha256 = genPin.sha256;
    };
    # Build gen the SAME way gen's own flake builds itself
    # (`substrate.mkRustToolFlake { src = ./.; member = "gen-cli"; }`),
    # but with substrate's machinery referenced via `self` — no
    # `inputs.gen`. gen ships a committed `Cargo.build-spec.json`, so
    # this takes mkRustToolFlake's committed-spec fast path (crate2nix
    # under lockfile-builder); no chicken-and-egg, gen builds WITHOUT a
    # working gen. `gen` left unset ⇒ the inner builder auto-fetches the
    # gen-pin rev only as an IFD build-tool, which never fires here
    # because the committed spec is present.
    genFlake = self.mkRustToolFlake {
      inputs = {
        inherit nixpkgs crate2nix fenix;
        flake-utils = inputs.flake-utils;
        devenv = inputs.devenv or null;
        forge = inputs.forge or null;
      };
      src = genSrc;
      member = "gen-cli";
    };
    genFor = system: genFlake.packages.${system}.default;
  in
    flake-parts.lib.mkFlake { inherit inputs; } {
      inherit systems;

      flake = {
        # iroha (いろは) — the pleme-io Nix primitive alphabet.
        # One controlled, composable primitive set: option surfaces, package
        # modules, daemon units, overlay algebra, manifest, profiles, shims,
        # proof harness. Pure { lib } — system-independent, zero pkgs at
        # import. Consumers:
        #   iroha = inputs.substrate.iroha;                      # ready-bound
        #   iroha = import "${substrate}/lib/iroha" { inherit lib; };  # own lib
        # Self-test surface: checks.<system>.iroha (every letter's suite).
        iroha = import ./lib/iroha { lib = nixpkgs.lib; };
        irohaPath = ./lib/iroha;

        # kata (型) — the fleet-standard layer above iroha: typed fleet
        # blanks (fleet-config), registries (domains/users), one-call
        # assembly (mkFleet), and the instantiable fleet-repo template
        # (templates.fleet). A private fleet repo is config-only.
        kata = import ./lib/kata { lib = nixpkgs.lib; };
        kataPath = ./lib/kata;

        templates.fleet = {
          path = ./templates/fleet;
          description = "kata-standard private fleet repo — fill in fleet.nix, node hardware, secrets; all behavior from the vocabulary";
        };

        # Aggregate-before-assert eval-test derivations for the vocabulary.
        checks = eachSystem (system: {
          iroha =
            (import ./lib/iroha { lib = nixpkgs.lib; }).tests.asCheck
            (import nixpkgs { inherit system; });
          kata =
            (import ./lib/kata { lib = nixpkgs.lib; }).tests.asCheck
            (import nixpkgs { inherit system; });
        });

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

        # Go release-flake builders (peers of the rust* family; also surfaced
        # per-system via substrate.lib.${system}.<name> from ./lib/default.nix).
        goToolReleaseFlakeBuilder = ./lib/build/go/tool-release-flake.nix;
        goLibraryFlakeBuilder = ./lib/build/go/library-flake.nix;
        goWorkspaceReleaseFlakeBuilder = ./lib/build/go/workspace-release-flake.nix;
        goServiceFlakeBuilder = ./lib/build/go/service-flake.nix;
        goToolImageFlakeBuilder = ./lib/build/go/tool-image-flake.nix;
        goActionReleaseFlakeBuilder = ./lib/build/go/action-release-flake.nix;

        # Borealis pattern-registry §4f gap-fills (highest leverage, Nix).
        # goPrivateModuleBuilder — hermetic buildGoModule for PRIVATE org Go
        # deps (deploy-token FOD vendor-fetch OR Athens GOPROXY), no `--impure`,
        # cartorio-attestable. nodeDockerImageBuilder — JS-service OCI wrapper
        # mirroring mkGoDockerImage, completing L2 language coverage.
        # Also surfaced per-system via substrate.lib.${system}.<name>.
        goPrivateModuleBuilder = ./lib/build/go/private-module.nix;
        goDockerImageBuilder = ./lib/build/go/docker.nix;
        nodeDockerImageBuilder = ./lib/build/docker/node-image.nix;

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
            # gen is no longer a flake input — pass null so the inner
            # tool/workspace builders auto-fetch the `gen-pin.json` rev
            # at IFD time (no lock growth). The substrate↔gen cycle is
            # broken; consumers that need gen-as-build-tool resolve it
            # from the pin, not from a flake input.
            gen = null;
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
        # single `gen-pin.json` edit. Available as a top-level binary and
        # for IFD invocation inside `mkBuildSpec`. Built from the pinned
        # source via substrate's own tool-builder (no flake-input cycle).
        packages = eachSystem (system: {
          gen = genFor system;
          # oci-push (→ doca): typed OCI manager. `nix run …#oci-push -- push …`
          # replaces inline skopeo bash in the image-push pipeline.
          oci-push = import ./lib/build/oci-push.nix {
            pkgs = import nixpkgs { inherit system; };
          };
          # relver: typed release-version primitive. `nix run …#relver -- next …`
          # replaces inline semver/tag bash in the auto-bump workflows.
          relver = import ./lib/build/relver.nix {
            pkgs = import nixpkgs { inherit system; };
          };
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
