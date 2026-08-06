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
    # tatara-lisp ships the `tatara-script` binary, which is what the
    # no-shell rule is enforced WITH. tatara-lisp itself consumes substrate,
    # so this is a circular repo reference; that is fine because each flake
    # resolves its inputs from its own lock rather than recursing, and the
    # copy of substrate inside tatara-lisp is only used to build the script
    # binary. Deliberate, not accidental.
    tatara-lisp = {
      url = "github:pleme-io/tatara-lisp";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
    # skill-lint — validates the SKILL.md files this repo ships (see
    # checks.skill-map below).
    #
    # `inputs.substrate.follows = ""` is LOAD-BEARING, not tidiness.
    # skill-lint's own flake is a substrate consumer
    # (`substrate.rust.tool`), so a naive input pulls a SECOND, independently
    # locked substrate subtree into substrate's own lock. Measured
    # 2026-07-27: 52 nodes / 1150 lines -> 103 nodes / 2378 lines. The empty
    # follows resolves skill-lint's substrate to the root flake — this one —
    # collapsing that to 53 nodes / 1169 lines, a single added node.
    skill-lint = {
      url = "github:pleme-io/skill-lint";
      inputs.substrate.follows = "";
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

    # ── the fleet Go compiler, built from SUBSTRATE's nixpkgs ──────────────
    #
    # Bound here rather than reached through `self.goToolchains` so the `lib`
    # output does not depend on its own sibling attribute. Same pattern as
    # `genFor` above. The pin (version + every hash) is committed data in
    # lib/build/go/go-toolchain-pin.json — the fenix data/stable.json analogue.
    goToolchainFor = system:
      (import ./lib/build/go/overlay.nix).mkGoToolchain {
        pkgs = import nixpkgs { inherit system; };
      };
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
        checks = eachSystem (system: let
          pkgs = import nixpkgs { inherit system; };
        in {
          iroha =
            (import ./lib/iroha { lib = nixpkgs.lib; }).tests.asCheck pkgs;
          kata =
            (import ./lib/kata { lib = nixpkgs.lib; }).tests.asCheck pkgs;

          # MINIMAL-PRODUCTION-IMAGE — pure base-selection forcing-function
          # (no shell / no init / no libc in the minimal base). Runs on every
          # system incl. darwin.
          go-minimal-image =
            (import ./lib/build/go/tests/minimal-image-test.nix { inherit pkgs; }).asCheck pkgs;

          # ── Mutating-verb retirement (★★ PLATFORM-MEDIATED) ────────────
          # Guards the backward-compatibility contract of
          # lib/infra/mutating-verbs.nix: with every verb enabled (the
          # default, and what every existing consumer gets) `retireApps` must
          # return the app set BY IDENTITY and must not force `pkgs` — the
          # tests pass `pkgs = throw "…"` to prove it, so a regression that
          # starts rewrapping enabled apps turns this red instead of silently
          # moving every consumer's store paths. Also covers the validator
          # negatives (unknown field / non-bool enable / retirement with no
          # date or no `executes` / a verb this builder doesn't produce).
          #
          # Also covers COMPOSITION (added 2026-07-28): that a retirement
          # SURVIVES being composed. The 20 isolation tests above never
          # asked, so a change that retired only the RETURNED app set —
          # leaving `deploy` / `cycle` splicing the live cloud mutation
          # behind a top-level app that reads as refusing — would have kept
          # this check green. The composition block drives the two real
          # composition layers end to end (gated-pangea-workspace.nix's
          # `deploy`, infra-sdlc.nix's `cycle`) against a content-keyed fake
          # `pkgs`, and ships its own CONTROL: the open build must still
          # splice the real apply, or a harness that can see nothing would
          # report every negative as passing.
          #
          # NOT VACUOUS: verified red before landing, not merely observed
          # green. Five deliberate breaks were each run and each failed —
          # deleting the identity short-circuit (16/20), disabling the
          # declaration validator (16/20), deleting the stray-verb check
          # (19/20), replacing `base = retire rawBase` with `base = rawBase`
          # in gated-pangea-workspace.nix (24/30, 6 composition tests red,
          # all 20 isolation tests still green — the whole reason the block
          # exists), and blinding the composition fake to script bodies
          # (26/30, BOTH controls red while the two negatives they guard
          # stayed vacuously green — exactly the failure a control is for).
          # The stray-verb break is why `rejects-unknown-verb` uses a
          # working fake `pkgs` rather than the poisoned one: with the
          # poisoned `pkgs` that test stayed GREEN under the break, passing
          # on a throw from the wrong cause.
          mutating-verbs =
            (import ./lib/infra/tests/mutating-verbs-test.nix { inherit (nixpkgs) lib; }).asCheck pkgs;

          # ── The Rust builders' verification SURFACE ────────────────────
          # Wired 2026-07-27, alongside the change that made the surface
          # exist at all. `nix flake check` builds `checks.<system>.*` and
          # NOTHING else — packages are only evaluated ("build skipped") —
          # so a builder that emits no checks hands every consumer a
          # command that passes over a crate which was never compiled.
          # Measured on this fixture: at HEAD 3f4dfb9 a consumer-shaped
          # flake with a DELIBERATELY FAILING test reported
          # `checks.aarch64-darwin` = [] and `nix flake check` exit 0.
          #
          # This gate guards the ingredient, not the mechanism: that
          # `test-check.nix` keeps emitting `build` on every path, emits
          # `tests` exactly where substrate can genuinely run them, and —
          # the load-bearing one — does NOT evaluate the test derivation on
          # the path where it cannot (asserted with a poisoned `mkTests`
          # thunk, the same trick mutating-verbs uses for `pkgs`).
          #
          # NOT VACUOUS: verified red before landing, not merely observed
          # green. Deleting the availability gate (so `tests` is emitted on
          # the lockfile path) fails 3 tests including
          # `lockfile-never-forces-mkTests`; making the opt-out accept a
          # bare `enable = false` fails the two reason-required negatives.
          rust-test-check =
            (import ./lib/build/rust/tests/test-check-test.nix { inherit (nixpkgs) lib; }).asCheck pkgs;

          # ── The "did the gate have anything to build?" gate ────────────
          # Policy consumed by `.github/workflows/cargo-ci.yml` via
          # `flakeChecksGatePath` below. It lives in a real Nix file rather
          # than inline in the workflow because the inline version — a Nix
          # indented string inside a YAML block scalar inside a shell
          # single-quoted argument — silently lost its string delimiters on
          # the first attempt, and a gate that fails to PARSE never runs.
          #
          # NOT VACUOUS: `empty-check-set-throws` asserts the gate FAILS on
          # the exact input it exists to reject; making it return a
          # friendly string instead of throwing turns four tests red.
          flake-checks-gate =
            (import ./lib/util/tests/flake-checks-gate-test.nix { inherit (nixpkgs) lib; }).asCheck pkgs;

          # ── The "can the cargo-test job ENTER the devShell?" gate ──────
          # Policy INTENDED for `.github/workflows/nix-devshell-cargo-test.yml`,
          # exposed as `devshellPreflightPath` below.
          #
          # ⚠ NOT WIRED AS OF THIS COMMIT. No workflow imports
          # `devshellPreflightPath` — verified 2026-07-28 by grepping
          # `.github/` for it (zero hits). What ships here is the POLICY plus
          # its own tests; the CI leg that would invoke it is a follow-up.
          # Said out loud because a comment claiming a wiring that does not
          # exist is the same defect class this file's other gates close.
          #
          # Why it is worth having ready: `nix develop` failing is the ONLY
          # thing standing between a consumer and a completely opaque red.
          # Measured 2026-07-28 across 292 `substrate.rust.*` consumer
          # flake.nix files, ZERO set `buildMode = "cargo-nix"`, so
          # `checks.tests` is emitted for none of them and that job is the
          # only leg that runs their tests at all.
          #
          # NOT VACUOUS: `devenv-backed-throws` and
          # `unevaluable-devshell-throws` assert the gate FAILS on the two
          # shapes it exists to diagnose; making it return a friendly string
          # instead of throwing turns six tests red.
          devshell-preflight =
            (import ./lib/util/tests/devshell-preflight-test.nix { inherit (nixpkgs) lib; }).asCheck pkgs;

          # ── The `shape` argument is no longer inert ────────────────────
          # `mk-rust-tool-flake.nix` declared `shape ? "tool"` and never read
          # it, so all five `substrate.rust.<shape>` entry points were the
          # same builder and `shape = "libary"` was silently swallowed.
          #
          # NOT VACUOUS: `unknown-shape-throws` asserts the exact input the
          # old code accepted now fails, and
          # `known-set-covers-every-flake-call-site` reads THIS file to catch
          # the closed set and the `callShape` sites drifting apart.
          rust-shape =
            (import ./lib/build/rust/tests/shape-test.nix { inherit (nixpkgs) lib; }).asCheck pkgs;
          rust-determinism-flags =
            (import ./lib/build/rust/tests/determinism-flags-test.nix { inherit (nixpkgs) lib; }).asCheck pkgs;

          # ── Per-skill STRUCTURE gate ───────────────────────────────────
          # Wired 2026-07-27. Before this, skill-lint ran in exactly ONE repo
          # fleet-wide (blackmatter-pleme); the two skills substrate ships were
          # validated by nothing. A gate wired into 1 of 7 repos is green
          # because it never looks, which is indistinguishable from passing.
          #
          # This gate could not be wired until the skills were FIXED, not
          # merely observed: both `pangea-infrastructure` and
          # `substrate-builder` were missing their whole `metadata` block, and
          # baselining both would have left ZERO subjects — which skill-lint's
          # own DiscoveryChecker correctly refuses ("no skills found" is an
          # error, never a pass). A gate over an empty set is the vacuous-guard
          # failure mode, so the honest options were a permanently-red gate or
          # a real fix. Both skills were re-verified against the tree the same
          # day and their genuine defects corrected; the gate covers the
          # result.
          #
          # WHY THE EMPTY MAP DIR: skill-lint calls skill_map() inside
          # CheckContext::from_source BEFORE any --skip-* flag is consulted, so
          # a map argument is mandatory even when every map-dependent check is
          # off. substrate has no local skill-map.d — the fleet map lives in
          # blackmatter-pleme — so the gate is handed an empty one and the
          # map-dependent checks are skipped explicitly.
          #
          # COVERED: every SKILL.md here parses, its `name` matches its
          # directory, and it carries `description` + `metadata.version` +
          # `metadata.last_verified`. NOT COVERED, do not round this up:
          # whether these skills appear in the fleet map at all, and whether
          # `last_verified` is RECENT — freshness is deliberately not gated
          # (a bot bumping a date to go green manufactures a false claim), and
          # map parity belongs to blackmatter-pleme, not to this flake.
          #
          # NOT VACUOUS: verified red before landing, not merely observed
          # green — the same binary and args fail on a removed metadata block.
          skill-map = pkgs.runCommand "skill-map-check" {
            nativeBuildInputs = [ inputs.skill-lint.packages.${system}.default ];
          } ''
            skill-lint check --skills-dir ${./skills} --map-dir ${pkgs.emptyDirectory} \
              --skip-sync --skip-map-integrity --skip-version
            touch $out
          '';
        }
        # The end-to-end build+RUN gate: build the smoke fixture as a minimal
        # scratch-base image and serve /health=200. Linux-only (execs a linux
        # binary + binds a socket); built by super-cache-ci / CI.
        // nixpkgs.lib.optionalAttrs (nixpkgs.lib.hasSuffix "linux" system) {
          go-minimal-image-serves =
            import ./lib/build/go/tests/minimal-image-serve-test.nix { inherit pkgs; };

          # The hardened peer of the above: same fixture, built through
          # mkHardenedGoImage with nothing overridden, so a wrong default in
          # that builder fails here. tataraScript comes from the flake input
          # because the conformance body is tlisp, not shell.
          go-hardened-image =
            import ./lib/build/go/tests/hardened-image-test.nix {
              inherit pkgs;
              tataraScript = inputs.tatara-lisp.packages.${system}.tatara-script;
              goToolchain = goToolchainFor system;
            };

          # The SPA peer: proves the port rule applied, the assets sit at the
          # interface path, no libc came back in through the binary's package,
          # the shaped /bin/sh satisfies the chart's preStop hook while refusing
          # everything else, and it still serves.
          web-static-spa-image =
            import ./lib/build/web/tests/static-spa-image-test.nix {
              inherit pkgs;
              tataraScript = inputs.tatara-lisp.packages.${system}.tatara-script;
              goToolchain = goToolchainFor system;
            };
        });

        # ── The subject set for nix-devshell-cargo-test.yml's own gate ────
        #
        # `.github/workflows/devshell-cargo-test-selftest.yml` calls the REAL
        # `nix-devshell-cargo-test.yml` against this shell, so the reusable
        # is exercised end to end by a consumer-shaped caller inside this
        # repo rather than only in the three downstream repos that discover
        # its breakage after `@main` has already moved.
        #
        # That gap is the whole reason this exists. On 2026-07-27 a
        # `cargo-test` job was added to the shared `cargo-ci.yml`; because
        # nothing here consumed it, the first execution of that job anywhere
        # was in a consumer's CI, and it failed for all three of them. A
        # shared reusable with no in-repo caller has no way to go red before
        # its blast radius does.
        #
        # Deliberately a PLAIN `mkShell`: it is the shape substrate's own
        # Rust builders emit since e232917 (`devenv = null` -> fenix
        # mkShell), so the green half of the selftest asserts the supported
        # shape genuinely works — `name` resolves to "nix-shell", the
        # preflight returns Ok, and cargo really runs. A devenv-backed shell
        # is deliberately NOT added here: `nix flake check` evaluates every
        # devShell, so declaring one would make substrate's own flake
        # un-evaluable purely — the exact defect being diagnosed, self-
        # inflicted. The devenv arm is covered by
        # `checks.<system>.devshell-preflight`'s `devenv-backed-throws`.
        devShells = eachSystem (system: let
          pkgs = import nixpkgs { inherit system; };
        in {
          selftest-cargo = pkgs.mkShell {
            packages = [ pkgs.cargo pkgs.rustc ];
          };

          # ── release-gate ────────────────────────────────────────────────
          # The floor the publish gate runs in when a consumer's OWN devShell
          # cannot be entered. Measured 2026-08-06 across the 52
          # rust-auto-release consumers: only 17 can be entered; 25 are
          # devenv-backed (`nix develop` fails pure AND --impure), 7 have no
          # flake, 3 hard-fail otherwise — and substrate itself declares no
          # `default`. Without this shell a default-on gate blocks ~35 repos
          # from publishing on day one, for an environment defect rather than
          # a test failure.
          #
          # WHY THIS IS NOT THE FALLBACK devshell-preflight.nix REJECTS.
          # That file refuses `dtolnay/rust-toolchain@stable` + bare cargo,
          # because an UNPINNED ambient toolchain lets a crate that needs
          # hermetic inputs go green on the accident — a fresh vacuous guard
          # inside the gate meant to close one. This is a nix-PINNED substrate
          # shell, and the distinction is decisive: when a crate needs an input
          # this lacks, it FAILS TO BUILD — a loud false RED. It cannot
          # manufacture a green over an environment that could not run the
          # tests. If a crate passes without its declared inputs, those inputs
          # were not load-bearing and the green is true.
          #
          # Still a WEAKER tier than the declared shell — the environment under
          # test is not the crate's own — so the gate stamps `tier=` on every
          # run rather than letting a fallback pass as the strong thing.
          #
          # Honest limits: no per-crate buildInputs (pkg-config + protobuf +
          # openssl cover the 6 protoc consumers and openssl-sys, NOT the 2
          # wgpu/GPU ones), and a repo's rust-toolchain.toml is ignored here
          # (that is a rustup feature; this ships plain rustc). Both are
          # false-REDs when they bite, never false greens.
          #
          # Separate from selftest-cargo on purpose: that shell's comment
          # commits it to being the minimal shape substrate's builders emit,
          # and the selftest asserts against it. This one is allowed to grow.
          release-gate = pkgs.mkShell {
            packages = [ pkgs.cargo pkgs.rustc pkgs.pkg-config pkgs.protobuf ];
            buildInputs = [ pkgs.openssl ];
          };
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

        # ── goToolchains — the Go answer to `fenix`, and the whole point ────
        #
        # THE fleet Go compiler, built from SUBSTRATE's own nixpkgs and published
        # per-system so a consumer needs no new flake input to get a current
        # compiler — exactly the ergonomic `rustOverlays` gives for Rust.
        #
        # "Built from substrate's own nixpkgs" is the load-bearing half, not a
        # detail. fenix works on a nixos-24.05 consumer precisely BECAUSE that
        # consumer's nixpkgs never builds rustc. substrate's Go toolchain used to
        # be `prev.callPackage`d out of the consumer's package set, and against
        # the consumer that needed it that did not degrade — it ABORTED
        # uncatchably (`replaceVars` does not exist in 24.05). Measured; see
        # lib/build/go/overlay.nix's header.
        #
        #   # consumer flake — no `inputs.fenix`, no `inputs.go-overlay`
        #   hardened = import "${substrate}/lib/build/go/hardened-image.nix" {
        #     goToolchain = substrate.goToolchains.${system}.stable;
        #   };
        #
        # The version + every hash is committed data (lib/build/go/
        # go-toolchain-pin.json, the fenix data/stable.json analogue), so a
        # fleet-wide compiler bump is a two-field diff here, not a lock bump and
        # not a resolution at eval.
        goToolchains = eachSystem (system: { stable = goToolchainFor system; });

        # Per-system library and overlay exports
        # Consumers access as: substrate.lib.${system}, substrate.rustOverlays.${system}.rust
        lib = eachSystem (system: let
          rustOverlay = import ./lib/build/rust/overlay.nix;
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ (rustOverlay.mkRustOverlay { inherit fenix system; }) ];
          };
        in import ./lib {
          inherit pkgs crate2nix system;
          fenix = fenix.packages.${system};
          # The pinned Go compiler, so mkHardenedGoBinary / mkStaticSpaImage
          # reached through `substrate.lib.${system}` are current BY DEFAULT.
          # Deliberately NOT applied as an overlay on `pkgs` above: that would
          # rebuild every Go package in the closure, which is the exact thing
          # lib/build/rust/overlay.nix refuses to do for rustc/cargo.
          goToolchain = goToolchainFor system;
        });

        # NOTE: Named `rustOverlays` (not `overlays`) because flake-parts reserves
        # `flake.overlays` for nixpkgs overlay functions (final: prev: { ... }).
        # Per-system attrsets like this would fail the overlay type check.
        rustOverlays = eachSystem (system: {
          rust = (import ./lib/build/rust/overlay.nix).mkRustOverlay { inherit fenix system; };
        });

        # Go sibling of `rustOverlays`, same naming reason. The package-set-wide
        # altitude: closes over substrate's pinned toolchain so a consumer can
        # apply it to its OWN nixpkgs and have every Go package in that set built
        # by the fleet compiler.
        #
        # SECONDARY BY DESIGN. This replaces `go` and `buildGoModule` globally,
        # so it rebuilds every Go package in the consumer's closure and pkgsMusl
        # inherits it too. Reach for the per-derivation `goToolchain` seam first
        # (`substrate.goToolchains.${system}.stable` into one builder); use this
        # only when a consumer genuinely wants one answer for a whole package set.
        goOverlays = eachSystem (system: {
          go = (import ./lib/build/go/overlay.nix).mkGoOverlay {
            goToolchain = goToolchainFor system;
          };
        });

        # Home-manager tool module helpers (profile orchestration, safe packages)
        hmToolHelpers = ./lib/hm-tool-helpers.nix;

        # The `nix flake check` non-vacuity gate, as a standalone import
        # path. Consumed by `.github/workflows/cargo-ci.yml` from inside a
        # CONSUMER's checkout (where substrate's tree is not present), so it
        # has to be reachable as a flake attr rather than a relative path:
        #
        #   nix eval --impure --raw --expr '
        #     import (builtins.getFlake "github:pleme-io/substrate").flakeChecksGatePath {
        #       system = builtins.currentSystem;
        #       checks = (builtins.getFlake (toString ./.)).checks or {};
        #     }'
        #
        # Guarded by checks.<system>.flake-checks-gate above.
        flakeChecksGatePath = ./lib/util/flake-checks-gate.nix;

        # The devShell-enterability gate, as a standalone import path. Same
        # reasoning as flakeChecksGatePath: it is consumed from inside a
        # CONSUMER's checkout, where substrate's tree is not present.
        #
        #   nix eval --impure --raw --expr '
        #     import (builtins.getFlake "github:pleme-io/substrate").devshellPreflightPath {
        #       system    = builtins.currentSystem;
        #       devshell  = "default";
        #       devShells = (builtins.getFlake (toString ./.)).devShells or {};
        #     }'
        #
        # `--impure` is not optional here: on the very revs this gate exists
        # to diagnose, the devShell attribute cannot be evaluated purely.
        # Guarded by checks.<system>.devshell-preflight above.
        devshellPreflightPath = ./lib/util/devshell-preflight.nix;

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
        # MINIMAL-PRODUCTION-IMAGE conformance-check generator — run any
        # built Go image through the strict-stack forcing-function.
        goMinimalImageCheckBuilder = ./lib/build/go/minimal-image-check.nix;

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
        # The unified surface auto-wires every REAL gen verb as a
        # flake app in the consumer's outputs: `nix run .#lock`,
        # `nix run .#build-spec`, `nix run .#confirm`. (plan/diff/sbom
        # are Adapter TRAIT methods but not yet CLI subcommands — the
        # phantom apps were removed from adapter-apps.nix so `nix run`
        # never lands on an `unrecognized subcommand`.) Zero
        # consumer-side declaration.
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
        # substrate is a library repo and had no `apps` output until sql-apply.
        # It needs one for a narrow, structural reason: `sql-apply` is a
        # FIRST-PARTY tool, and the two existing image-publishing homes both
        # reject it. hardened-images' catalog requires `upstreamImage` ("the
        # REQUIRED 'what does this replace'", lib/mk-hardened-image-set.nix) —
        # a hardened rebuild of an upstream, which this is not; supplying a
        # fake one would be dishonest metadata. vendor-mirror.yml's `vendor-*`
        # naming is for third-party mirrors. So the image is published from
        # where it is built, and hardened-images only MIRRORS it into Zot
        # (as `pleme-sql-apply`, the prefix `pleme-concprobe` already
        # establishes for our own tools).
        #
        # Additive: no consumer reads `substrate.apps`, and adding the output
        # cannot change what any existing `packages`/`lib` consumer resolves.
        apps = eachSystem (system: {
          # Pushes through doca (oci-push) DIRECTLY rather than through
          # substrate's own mkImageReleaseApp, for a structural reason:
          # mkImageReleaseApp emits a `forge` invocation, and substrate resolves
          # forge as `inputs.forge or null` -- an input it never declares -- so
          # the app calls a bare `forge` nothing puts on PATH and the push dies
          # with `forge: not found`, exit 127 (measured, run 31003430292).
          # hardened-images does not use that helper either; its own mkPushApp
          # shells straight to doca, which substrate DOES package. Same shape
          # here.
          #
          # amd64 ONLY. mkImageReleaseApp's dual-arch default interpolates both
          # image derivations into one script, so running it on a single runner
          # tries to build the other arch there -- `Reason: platform mismatch /
          # Required system: 'aarch64-linux' / Current system: 'x86_64-linux'`
          # (measured, run 31002775957). Dual-arch needs a runner per arch plus
          # a manifest join, the release-vector + release-vector-arm64 +
          # join-vector shape. amd64 is also what this image is FOR: every
          # hardened-* image in Camelot's Zot is amd64-only (verified against
          # the registry) and the Jobs that run sql-apply schedule on the amd64
          # pool.
          #
          # Credentials are NOT handled here: the release workflow's registry
          # login writes ~/.docker/config.json, which doca reads through its own
          # docker_config_credentials path.
          "release:sql-apply" =
            let
              pkgsHere = import nixpkgs { inherit system; };
              image = import ./lib/build/sql-apply-image.nix {
                pkgs = import nixpkgs { system = "x86_64-linux"; };
              };
              doca = self.packages.${system}.oci-push;
            in
            {
              type = "app";
              program = toString (pkgsHere.writeShellScript "release-sql-apply" ''
                set -eu
                sha="''${GITHUB_SHA:-dev}"
                exec ${doca}/bin/oci-push push \
                  --backend native \
                  --registry ghcr.io \
                  --image pleme-io/sql-apply \
                  --tag "amd64-''${sha}" \
                  --additional-tags amd64-latest \
                  --tarball ${image}
              '');
            };
        });

        packages = eachSystem (system: {
          gen = genFor system;

          # cargo-nextest exposed as a PACKAGE, deliberately NOT added to
          # consumer devShells.
          #
          # The anti-vacuity assertion must not be supplied by the repo being
          # gated. 20 of the 52 rust-auto-release consumers pin substrate at
          # 2026-06-07, so anything added to mkRustDevShell reaches them only
          # after they re-lock — and a consumer can replace `tools` /
          # `extraPackages` outright. Handing the workflow an absolute store
          # path instead makes the assertion work on every consumer TODAY and
          # unremovable from the consumer side.
          #
          # Why nextest at all: `cargo test` EXITS 0 when it runs zero tests.
          # Measured 2026-08-06 (cargo 1.91.0), one fixture per shape — crate
          # with no tests: exit 0; all #[ignore]: exit 0; filter matching
          # nothing: exit 0. All three are vacuous greens, and `cargo test`
          # cannot tell you which one you have. `cargo nextest run
          # --no-tests=fail` exits 4 on each. So the anti-vacuity rule is a
          # FLAG ON AN EXISTING TOOL, not a gate of our own invention.
          # Already in substrate's nixpkgs pin (0.9.136) — no new flake input.
          cargo-nextest = (import nixpkgs { inherit system; }).cargo-nextest;
          # oci-push (→ doca): typed OCI manager. `nix run …#oci-push -- push …`
          # replaces inline skopeo bash in the image-push pipeline.
          # fenix threaded through 2026-07-22 -- see lib/build/oci-push.nix's
          # own header for the edition2024/MSRV incident this closes. Passed
          # ALREADY PER-SYSTEM-INDEXED (fenix.packages.${system}), matching
          # oci-push.nix's own expected shape (the same convention
          # lib/default.nix already uses at its own fenix = fenix.packages.
          # ${system}; shadow, confirmed against wasm/build.nix +
          # leptos-build.nix) -- NOT the raw flake input `mkRustOverlay`
          # above takes (that function does its OWN `.packages.${system}`
          # indexing internally; oci-push.nix deliberately does not, to
          # match the more common internal convention).
          oci-push = import ./lib/build/oci-push.nix {
            pkgs = import nixpkgs { inherit system; };
            fenix = fenix.packages.${system};
            inherit system;
          };
          # relver: typed release-version primitive. `nix run …#relver -- next …`
          # replaces inline semver/tag bash in the auto-bump workflows.
          relver = import ./lib/build/relver.nix {
            pkgs = import nixpkgs { inherit system; };
          };
          # sql-apply: typed SQL migration runner. `nix run …#sql-apply -- apply …`
          # replaces lib/service/db-migration.nix's writeShellScript runner (and
          # the database CLI it shelled to), which is what forced a busybox base
          # on every consumer of that pattern.
          sql-apply = import ./lib/build/sql-apply.nix {
            pkgs = import nixpkgs { inherit system; };
          };
          # The image carrying it — a K8s Job's `command:` can only run what is
          # inside its image, so the tool needs one to reach a cluster.
          # distroless-static: no shell, no database CLI, no libc.
          sql-apply-image = import ./lib/build/sql-apply-image.nix {
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
          # The Go sibling of `fenix` above. A consumer calling libFor with its
          # OWN pkgs should pass `substrate.goToolchains.${system}.stable` here —
          # that is what decouples its Go artifacts from its own nixpkgs pin.
          # Omitting it leaves Go builds on the consumer's `pkgs.go`, which
          # mkHardenedGoBinary's CVE floor will reject at eval if it is stale.
          goToolchain ? null,
        }:
          import ./lib {
            inherit pkgs system crate2nix fenix forge goToolchain;
          };
      };
    };
}
