# ============================================================================
# RUST LIBRARY WORKSPACE BUILDER — multi-crate, no binary
# ============================================================================
# The missing dual to workspace-release.nix on the library side: a Cargo
# workspace where every member is a library (no binary entry point) that
# may be published to crates.io independently.
#
# Use when a workspace is decomposed into types / domain crates / umbrella
# re-export (the pleme-io shigoto / cofre-style "library family" pattern)
# and no binary belongs in the tree.
#
# Apps produced:
#   check-all   — cargo fmt + clippy + test across the whole workspace
#   regenerate  — regenerate Cargo.nix from Cargo.lock
#   (per-member publish/bump are operator-driven via `cargo publish -p <m>`
#    for v1; a topological all-member release helper can land later when a
#    real consumer needs it.)
#
# Usage (typically wrapped by library-workspace-flake.nix):
#   rustLibraryWorkspace {
#     workspaceName = "shigoto";
#     members = [ "shigoto" "shigoto-types" "shigoto-dag" ... ];
#     defaultMember = "shigoto";   # what `nix build` builds
#     src = self;
#   }
#
# Returns: { packages, devShells, apps }
#   packages.${member} for each workspace member
#   packages.default = packages.${defaultMember}
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
  # Accepts either shape. A wrong shape still fails here with the arg's name
  # rather than as a type error deep inside crate2nix.
  checkInputs = name: v:
    if builtins.isFunction v then true
    else check.list name v;
in {
  workspaceName,
  members,
  defaultMember ? workspaceName,
  src,
  cargoNix ? src + "/Cargo.nix",
  buildInputs ? [],
  nativeBuildInputs ? [],
  crateOverrides ? {},
  extraDevInputs ? [],
  devEnvVars ? {},
}: let
  _ = check.all [
    (check.nonEmptyStr "workspaceName" workspaceName)
    (check.list "members" members)
    (check.nonEmptyStr "defaultMember" defaultMember)
    (checkInputs "buildInputs" buildInputs)
    (checkInputs "nativeBuildInputs" nativeBuildInputs)
    (check.attrs "crateOverrides" crateOverrides)
  ];

  # ★ A LIST OR A FUNCTION OF pkgs, and the function form is the one that
  # works for a native dependency.
  #
  # These args are supplied ONCE by the flake and reused for every system,
  # while a derivation belongs to exactly one. So a caller who needs
  # `pkgs.pam` had no way to say it: naming a derivation at the flake level
  # requires a `pkgs`, and any `pkgs` they could construct there is pinned to
  # one system and silently wrong on the other three.
  #
  # Measured 2026-08-19 on `mukae`, whose greeter links libpam: the build got
  # all the way to the linker and died on `rust-lld: error: unable to find
  # library -lpam`, with no expressible fix in the flake. Passing
  # `buildInputs = p: [ p.pam ]` resolves against the per-system `pkgs` the
  # helper already has in scope.
  #
  # A plain list keeps working unchanged — this widens the surface and moves
  # nobody.
  resolveInputs = v: if builtins.isFunction v then v pkgs else v;

  defaultBuildInputs = with pkgs; [ openssl ];
  allBuildInputs = defaultBuildInputs ++ (resolveInputs buildInputs);
  defaultNativeBuildInputs = with pkgs; [ pkg-config ];
  allNativeBuildInputs = defaultNativeBuildInputs ++ (resolveInputs nativeBuildInputs);

  crate2nixTools = import "${crate2nix}/tools.nix" { inherit pkgs; };
  generatedCargoNix =
    if builtins.pathExists cargoNix then cargoNix
    else crate2nixTools.generatedCargoNix { name = workspaceName; inherit src; };

  # Apply per-member crateOverrides defaults — every workspace member gets
  # the default build/native inputs; consumers can override per-crate via
  # the `crateOverrides` arg.
  # ★ RPATH FOR EVERY buildInput, because linking is not running.
  #
  # A `buildInput` gives the LINKER a path; it does not put one in the
  # produced ELF. For a library that never matters — nothing execs an rlib —
  # so this builder shipped without it and no consumer noticed. A workspace
  # member with a `[[bin]]` and a native dependency is a different animal, and
  # the failure is silent in the worst way: the derivation is GREEN, the binary
  # is in the store, and it dies on first exec.
  #
  # Measured 2026-08-19 on `mukae`: the greeter built, `bin/mukae` was 1.4MB,
  # and `ldd` said `libpam.so.0 => not found`. Caught only because someone ran
  # `ldd` instead of trusting the green build.
  #
  # Harmless for the library members — an rlib carries no RPATH — so this is
  # unconditional rather than a flag someone has to know to set.
  rpathOpts = map (l: "-C link-arg=-Wl,-rpath,${l}/lib") allBuildInputs;

  perMemberDefaults = pkgs.lib.genAttrs members (_member: _oldAttrs: {
    buildInputs = allBuildInputs;
    nativeBuildInputs = allNativeBuildInputs;
    extraRustcOpts = rpathOpts;
  });

  # FRESHNESS TIE — see ./cargo-nix-tie.nix. A committed Cargo.nix that no
  # longer describes src/Cargo.lock throws here, before anything is built
  # from it. The tie names `cargoNix`, not `generatedCargoNix`: on the
  # fallback branch the latter is a derivation, and crate2nix just built it
  # from this tree, so there is nothing to tie.
  cargoNixTie = import ./cargo-nix-tie.nix { };

  project = cargoNixTie.assertFresh {
    inherit cargoNix src;
    cargoLock = src + "/Cargo.lock";
  } (import generatedCargoNix {
    inherit pkgs;
    defaultCrateOverrides = pkgs.defaultCrateOverrides
      // perMemberDefaults
      // crateOverrides;
  });

  # Per-member build attributes. crate2nix exposes each workspace member
  # as `project.workspaceMembers.${member}.build`.
  memberBuilds = pkgs.lib.genAttrs members (member:
    project.workspaceMembers.${member}.build);

  devTools = [
    pkgs.fenixRustToolchain
    pkgs.rust-analyzer
    pkgs.cargo-watch
    pkgs.cargo-edit
  ];

  defaultDevEnvVars = {
    RUST_SRC_PATH = "${pkgs.fenixRustToolchain}/lib/rustlib/src/rust/library";
  };
  # ★ A LIST OR A FUNCTION OF pkgs — the same widening `buildInputs` got above,
  # for the same reason, found by the same crate.
  #
  # `buildInputs = p: [ p.pam ]` fixes LINKING. It does not fix LOADING: a
  # cargo-built test binary gets `-L` flags but no RUNPATH into the nix store,
  # so on Linux it dies at run time with
  #
  #   error while loading shared libraries: libpam.so.0: cannot open shared
  #   object file: No such file or directory
  #
  # (measured on mukae's release Test gate, 2026-08-23 — `cargo nextest` could
  # not even LIST the tests, exit 127). The cure is `LD_LIBRARY_PATH`, which
  # names a store path, which needs a per-system `pkgs` — the identical bind
  # the buildInputs comment describes, so it gets the identical escape hatch.
  #
  # A plain attrset keeps working unchanged: `resolveInputs` returns a
  # non-function untouched.
  allDevEnvVars = defaultDevEnvVars // (resolveInputs devEnvVars);

  # Workspace-wide check + regenerate apps (single binary script each;
  # per-member apps would multiply attribute paths without buying anything
  # for v1 — operators run `cargo test -p <member>` directly).
  cargo = pkgs.fenixRustToolchain or pkgs.cargo;
  cargoBin = "${cargo}/bin/cargo";
  toolchainPath = ''export PATH="${cargo}/bin:${pkgs.cargo-edit}/bin:${pkgs.git}/bin:$PATH"'';

  mkCheckAllApp = {
    type = "app";
    program = toString (pkgs.writeShellScript "${workspaceName}-check-all" ''
      set -euo pipefail
      ${toolchainPath}
      echo "Workspace ${workspaceName}: running fmt + clippy + test across all members..."
      echo ""

      echo "==> cargo fmt --check"
      ${cargoBin} fmt --check
      echo ""

      echo "==> cargo clippy --workspace --all-targets"
      ${cargoBin} clippy --workspace --all-targets -- -D warnings
      echo ""

      echo "==> cargo test --workspace"
      ${cargoBin} test --workspace
    '');
  };

  mkRegenerateApp = {
    type = "app";
    program = toString (pkgs.writeShellScript "${workspaceName}-regenerate" ''
      set -euo pipefail
      ${toolchainPath}
      echo "Workspace ${workspaceName}: regenerating Cargo.nix from Cargo.lock..."
      ${crate2nix}/bin/crate2nix generate
      echo "Done. Review the diff and commit Cargo.nix."
    '');
  };

in {
  packages = memberBuilds // {
    default = memberBuilds.${defaultMember};
  };

  devShells.default = (import ../shared/devshell.nix { inherit pkgs; }).mkRustDevShell {
    inherit pkgs devenv nixpkgs;
    devenvModule = ../../devenv/rust-library.nix;
    tools = devTools;
    buildInputs = allBuildInputs;
    nativeBuildInputs = allNativeBuildInputs;
    # ★ `pkgs.crate2nix`, NOT the `crate2nix` INPUT. The input is declared
    # `flake = false` (substrate/flake.nix:38-41), so it is a plain source
    # attrset — `lastModified`/`narHash`/`outPath` and nothing else, no
    # `packages`, no derivation. Putting it in a package list made every
    # library-workspace devShell die with
    #
    #   error: Dependency is not of a valid type: element 7 of buildInputs
    #
    # which is what took mukae's release Test gate red (`nix develop .#default`).
    # The source form is still needed one line down at `import
    # "${crate2nix}/tools.nix"` — that consumer wants the RAW input, so the
    # resolution belongs HERE, at the use site, and not in the caller.
    extraPackages = extraDevInputs ++ [ pkgs.crate2nix ];
    env = allDevEnvVars;
  };

  apps = {
    check-all = mkCheckAllApp;
    regenerate = mkRegenerateApp;
  };
}
