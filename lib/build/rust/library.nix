# ============================================================================
# RUST LIBRARY BUILDER - Nix-based SDLC for crates.io Rust libraries
# ============================================================================
# Build verification, dev shells, and lifecycle apps.
# No Docker, no deploy — libraries publish to crates.io.
#
# Apps:
#   check-all  — cargo fmt + clippy + test
#   bump       — version bump (patch|minor|major), regenerate, git commit + tag
#   publish    — cargo publish
#   release    — bump + publish in one step
#   regenerate — regenerate Cargo.nix from Cargo.lock
#
# Usage in library flake.nix:
#   let rustLibrary = import "${substrate}/lib/rust-library.nix" {
#     inherit system nixpkgs;
#     nixLib = substrate;
#     crate2nix = inputs.crate2nix;
#   };
#   in rustLibrary {
#     name = "pleme-notifications";
#     src = ./.;
#   }
#
# This returns: { packages, devShells, apps, checks }
#
# ── checks (2026-07-27) ─────────────────────────────────────────────────
# `nix flake check` builds `checks.<system>.*` and NOTHING ELSE — packages
# are only evaluated, never realised. Until this builder emitted checks it
# returned `{ packages, devShells, apps }`, so every consumer's
# `nix flake check` was a pure eval check: green over a crate that was
# never compiled, let alone tested. Two checks close that:
#
#   checks.build — the crate compiles (always)
#   checks.tests — the crate's tests run (crate2nix `runTests`, default on)
#
# Policy + the typed opt-out live in ./test-check.nix; see that file for
# why the sibling `tool-release.nix` cannot emit `tests` on its default
# build path.
{
  nixpkgs,
  system,
  nixLib,
  crate2nix,
  devenv ? null,
}: let
  check = import ../../types/assertions.nix;
  pkgs = import nixpkgs {
    inherit system;
    overlays = [ nixLib.rustOverlays.${system}.rust ];
  };
in {
  name,
  src,
  cargoNix ? src + "/Cargo.nix",
  buildInputs ? [],
  nativeBuildInputs ? [],
  crateOverrides ? {},
  extraDevInputs ? [],
  devEnvVars ? {},
  # Typed test-gate declaration. Default: ON. Turning it off requires a
  # typed reason (`{ enable = false; reason = "…"; }`) — a bare boolean
  # flip is refused, so an opt-out is always a recorded decision. See
  # ./test-check.nix.
  tests ? {},
  # Flags passed to the compiled test executable (crate2nix
  # `testCrateFlags`), e.g. [ "--test-threads=1" ].
  testCrateFlags ? [],
  # Packages available in the test-run sandbox (crate2nix `testInputs`).
  # A test needing a binary on PATH declares it here rather than relying
  # on the ambient environment.
  testInputs ? [],
}: let
  _ = check.all [
    (check.nonEmptyStr "name" name)
    (check.list "buildInputs" buildInputs)
    (check.list "nativeBuildInputs" nativeBuildInputs)
    (check.attrs "crateOverrides" crateOverrides)
  ];
  # Default build inputs for libraries (lighter than services — no postgres/sqlite)
  defaultBuildInputs = with pkgs; [ openssl ];
  allBuildInputs = defaultBuildInputs ++ buildInputs;
  defaultNativeBuildInputs = with pkgs; [ pkg-config ];
  allNativeBuildInputs = defaultNativeBuildInputs ++ nativeBuildInputs;

  # crate2nix build — verifies the library compiles in Nix sandbox
  crate2nixTools = import "${crate2nix}/tools.nix" { inherit pkgs; };
  generatedCargoNix =
    if builtins.pathExists cargoNix then cargoNix
    else crate2nixTools.generatedCargoNix { inherit name src; };

  project = import generatedCargoNix {
    inherit pkgs;
    defaultCrateOverrides = pkgs.defaultCrateOverrides // {
      # rmcp 0.15 uses env!("CARGO_CRATE_NAME") at compile time
      # (src/model.rs:860). Cargo sets this per-crate, but nixpkgs'
      # buildRustCrate only exports the CARGO_PKG_* / CARGO_CFG_* /
      # CARGO_MANIFEST_* families — CARGO_CRATE_NAME is absent. A
      # top-level attr does not reach the rustc child, so inject
      # via preBuild which runs in the same shell as buildCrate.
      rmcp = _: { preBuild = "export CARGO_CRATE_NAME=rmcp"; };
      ${name} = oldAttrs: {
        buildInputs = allBuildInputs;
        nativeBuildInputs = allNativeBuildInputs;
      };
    } // crateOverrides;
  };

  libraryBuild = project.rootCrate.build;

  # ── The verification surface ──────────────────────────────────────────
  # `libraryBuild` comes from a crate2nix-generated Cargo.nix, whose
  # `build` attr is `buildRustCrateWithFeatures` behind
  # `lib.makeOverridable`. `.override { runTests = true; }` is crate2nix's
  # own documented API: it rebuilds the crate's targets with `--test`
  # (using the generated `devDependencies`, which the gen lockfile path
  # does not have) and then EXECUTES the test binaries, failing the
  # derivation on a non-zero exit.
  #
  # SCOPE, stated so it is never rounded up: this runs the crate's
  # compiled test targets under the RESOLVED feature set (crate2nix's
  # `rootFeatures`) — it is not `cargo test --all-features` and it does
  # not run doc-tests. A crate whose tests are gated behind a non-default
  # feature must widen `rootFeatures` (or add its own `checks` entry);
  # silently under-scoping the feature matrix here would be a fresh
  # subject-set vacuity inside the very gate meant to close one.
  testCheck = import ./test-check.nix { inherit (pkgs) lib; };
  libraryTests = _: libraryBuild.override {
    runTests = true;
    inherit testCrateFlags testInputs;
  };

  # Dev tools
  devTools = [
    pkgs.fenixRustToolchain
    pkgs.rust-analyzer
    pkgs.cargo-watch
    pkgs.cargo-edit
  ];

  defaultDevEnvVars = {
    RUST_SRC_PATH = "${pkgs.fenixRustToolchain}/lib/rustlib/src/rust/library";
  };
  allDevEnvVars = defaultDevEnvVars // devEnvVars;

in {
  packages.default = libraryBuild;

  devShells.default = (import ../shared/devshell.nix { inherit pkgs; }).mkRustDevShell {
    inherit pkgs devenv nixpkgs;
    devenvModule = ../../devenv/rust-library.nix;
    tools = devTools;
    buildInputs = allBuildInputs;
    nativeBuildInputs = allNativeBuildInputs;
    extraPackages = extraDevInputs ++ [ crate2nix ];
    env = allDevEnvVars;
  };

  # formatBan = true: every crates.io library enforces the TYPED EMISSION
  # `format!()` ban in `check-all` (CLIPPY_CONF_DIR → the substrate clippy.toml),
  # so the ban is enforced-by-construction, not clean-by-hand. A library that
  # commits its own clippy.toml with the entry is respected as-is.
  apps = (import ../shared/cargo-release-app.nix {
    inherit pkgs crate2nix;
  }).mkCargoReleaseApps { inherit name; formatBan = true; };

  # The only outputs `nix flake check` actually BUILDS. Without them the
  # command is an eval-only check that passes over an unbuilt crate.
  checks = testCheck.surface {
    who = "rust-library/${name}";
    decl = tests;
    mode = "cargo-nix";        # library.nix always builds via crate2nix
    buildDrv = libraryBuild;
    mkTests = libraryTests;
  };
}
