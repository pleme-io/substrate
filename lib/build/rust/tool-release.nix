# ============================================================================
# RUST RELEASE BUILDER — unified single-crate + workspace CLI tool builds
# ============================================================================
# Builds a Rust CLI tool for 4 targets from any supported host:
#   - aarch64-apple-darwin
#   - x86_64-apple-darwin          (via Rosetta from aarch64-darwin)
#   - x86_64-unknown-linux-musl    (remote builder, static)
#   - aarch64-unknown-linux-musl   (remote builder, static)
#
# Works for both single-crate tools and workspace members:
#   - Single crate:     omit `packageName`; uses `project.rootCrate`
#   - Workspace member: set `packageName`; uses `project.workspaceMembers.${packageName}`
#
# Usage (single crate):
#   rustTool {
#     toolName = "kindling";
#     src = self;
#     repo = "pleme-io/kindling";
#   }
#
# Usage (workspace member — replaces the old separate workspace-release builder):
#   rustTool {
#     toolName = "mamorigami";
#     packageName = "mamorigami-cli";
#     src = self;
#     repo = "pleme-io/mamorigami";
#   }
#
# Returns: { packages, devShells, apps }
{
  nixpkgs,
  system,
  crate2nix,
  fenix ? null,
  devenv ? null,
  forge ? null,
  # Substrate-bound gen package. When supplied, the resulting
  # consumer flake exposes every Adapter verb as an app:
  # `nix run .#{lock,build-spec,plan,confirm,diff,sbom}`. Single
  # substrate change, six operator verbs in every consumer.
  gen ? null,
}: let
  check = import ../../types/assertions.nix;
  darwinHelpers = import ../../util/darwin.nix;
  rustOverlay = import ./overlay.nix;

  # Host pkgs — used for devShell, apps, and native builds
  hostOverlays = if fenix != null
    then [ (rustOverlay.mkRustOverlay { inherit fenix system; }) ]
    else [];
  hostPkgs = import nixpkgs {
    inherit system;
    overlays = hostOverlays;
  };

  # ============================================================================
  # TARGET PKGS BUILDERS
  # ============================================================================
  # Linux static binaries via pkgsStatic (musl). Darwin binaries via standard
  # pkgs — Rosetta handles x86_64-darwin on aarch64 hosts.
  #
  # When fenix is available we overlay buildRustCrate with a fenix
  # toolchain carrying the musl target's PREBUILT rust-std, so the static
  # build cross-compiles with the host rustc instead of building rustc +
  # LLVM from source under pkgsStatic (the from-source build costs ~30 min
  # and hits a static-link bug on recent nixpkgs/LLVM). The overlay
  # propagates into `.pkgsStatic`, so the static C stdenv (crt-static) is
  # preserved and only the toolchain is swapped. fenix == null keeps the
  # legacy from-source pkgsStatic path (zero impact on non-fenix consumers).
  mkLinuxStaticPkgs = targetSystem: muslTarget:
    if fenix == null
    then (import nixpkgs { system = targetSystem; }).pkgsStatic
    else (import nixpkgs {
      system = targetSystem;
      overlays = [
        (rustOverlay.mkRustOverlay {
          inherit fenix;
          system = targetSystem;
          targets = [ muslTarget ];
        })
      ];
    }).pkgsStatic;
  # Darwin target pkgs MUST use the same fenix toolchain as hostPkgs.
  # On native darwin (target arch == host arch — the common case for
  # operator workstations), the dual-tree dispatch in lockfile-builder
  # compares the target tree's `built.${blake3}` against the host
  # tree's `builtBuild.${blake3}`. Without fenix on the target side,
  # the two buildRustCrate invocations diverge (different rustc
  # version / different default flags), producing different output
  # hashes — even though source + args appear identical. That breaks
  # every native-darwin consumer that uses dual-tree dispatch (proc-
  # macro deps mostly). Match the hostPkgs overlay stack here so
  # native = identical-by-construction.
  mkDarwinPkgs = targetSystem:
    if fenix == null
    then import nixpkgs { system = targetSystem; }
    else import nixpkgs {
      system = targetSystem;
      overlays = [ (rustOverlay.mkRustOverlay { inherit fenix; system = targetSystem; }) ];
    };

  targets = {
    "aarch64-apple-darwin" = {
      pkgs = mkDarwinPkgs "aarch64-darwin";
      isDarwin = true;
    };
    "x86_64-apple-darwin" = {
      pkgs = mkDarwinPkgs "x86_64-darwin";
      isDarwin = true;
    };
    "x86_64-unknown-linux-musl" = {
      pkgs = mkLinuxStaticPkgs "x86_64-linux" "x86_64-unknown-linux-musl";
      isDarwin = false;
    };
    "aarch64-unknown-linux-musl" = {
      pkgs = mkLinuxStaticPkgs "aarch64-linux" "aarch64-unknown-linux-musl";
      isDarwin = false;
    };
  };
in {
  toolName,
  src,
  repo,
  packageName ? null,            # null = single-crate; set = workspace member
  cargoNix ? src + "/Cargo.nix",
  buildInputs ? [],
  nativeBuildInputs ? [],
  crateOverrides ? {},
  # Build-mode switch. `auto` = lockfile-builder when Cargo.build-spec.json
  # exists, else crate2nix Cargo.nix. `lockfile` = force lockfile-builder
  # (errors if spec missing). `cargo-nix` = force the legacy crate2nix path.
  buildMode ? "auto",
  # When `true` AND the outer flake helper supplied `gen`, wrap the
  # native binary so its runtime PATH begins with the pinned gen's
  # bin dir. Closes the substrate bootstrap loop where a fleet-style
  # binary that calls `gen` on PATH ends up calling whatever
  # /etc/profiles holds — usually the OLD gen the binary is supposed
  # to replace via activation. With the wrap, PATH gen IS the gen
  # this binary's flake.lock pinned at build time. Consumers:
  # fleet (calls gen for the pre-rebuild spec sweep); any future
  # tool that shells out to gen at runtime.
  runtimeNeedsGen ? false,
  ...
}:
let
  _ = check.all [
    (check.nonEmptyStr "toolName" toolName)
    (check.nonEmptyStr "repo" repo)
    (check.list "buildInputs" buildInputs)
    (check.list "nativeBuildInputs" nativeBuildInputs)
    (check.attrs "crateOverrides" crateOverrides)
  ];

  # Crate name for defaultCrateOverrides: workspace member when set, else toolName.
  crateKey = if packageName != null then packageName else toolName;

  # ── Build-mode resolution ────────────────────────────────────────
  # Per gen's algorithmic discipline: every consumer auto-uses the
  # lockfile-native pipeline when its Cargo.build-spec.json sidecar
  # exists. No per-consumer opt-in required. Falls back to crate2nix
  # only for unmigrated repos that don't yet have a spec.
  hasBuildSpec = builtins.pathExists (src + "/Cargo.build-spec.json");
  hasCargoNix = builtins.pathExists cargoNix;
  # Auto-mode dispatch (2026-05-30: operator-surface doctrine):
  # `lockfile` is always the right default. lockfile-builder handles
  # the missing-committed-spec case INTERNALLY via mk-build-spec.nix
  # (IFD), so substrate never needs the committed sidecar to dispatch.
  # `cargo-nix` stays as an explicit opt-in for repos that still
  # commit `Cargo.nix` (legacy crate2nix path) — operators flip
  # `buildMode = "cargo-nix"` to opt in.
  #
  # This closes the operator-surface doctrine on the substrate side:
  # only `Cargo.toml` is required as an operator-authored input;
  # every derived artifact (Cargo.lock, Cargo.build-spec.json,
  # Cargo.nix) is substrate-internal and IFD-regenerated as needed.
  effectiveMode =
    if buildMode == "auto"
    then "lockfile"
    else buildMode;
  _modeAssert =
    if effectiveMode == "cargo-nix" && !hasCargoNix
    then throw ''
      substrate/rust-release: buildMode = "cargo-nix" but
      ${toString cargoNix} is missing. Either commit Cargo.nix or
      switch to buildMode = "lockfile" (the default — uses
      lockfile-builder + gen IFD with no committed sidecar required).
    ''
    else null;

  # ============================================================================
  # BINARY BUILDER
  # ============================================================================
  # Triple-aware: pleme-crate-overrides exports a function
  # `triple -> overrides` so substrate-level safety nets (e.g. apple-
  # only feature strip on notify) fire only on the triples they
  # protect. mkBinary specializes per `_targetName` (the triple).
  plemeCrateOverridesFor = import ./pleme-crate-overrides.nix;
  mkBinary = _targetName: targetInfo: let
    targetPkgs = targetInfo.pkgs;
    plemeCrateOverrides = plemeCrateOverridesFor _targetName;
    consumerOverrides = targetPkgs.defaultCrateOverrides // plemeCrateOverrides // {
      ${crateKey} = attrs: {
        buildInputs = (attrs.buildInputs or [])
          ++ buildInputs
          ++ (darwinHelpers.mkDarwinBuildInputs targetPkgs);
        nativeBuildInputs = (attrs.nativeBuildInputs or [])
          ++ (builtins.map (name: targetPkgs.${name}) nativeBuildInputs);
      };
    } // crateOverrides;

    # gen + hostPkgs are the IFD auto-regen pair. Without them
    # mkProject's defaults land on `pkgs.gen or null` (== null) and
    # `pkgs.buildPackages` — which for pkgsStatic targets resolves
    # back to pkgsStatic itself (not the host). The IFD then either
    # never fires or recursively rebuilds gen/cargo/rustc for the
    # target stdenv. tool-release closes both gaps explicitly: gen
    # comes from substrate's flake input pre-bind, hostPkgs is the
    # native build-machine nixpkgs.
    project =
      if effectiveMode == "lockfile"
      then (import ./lockfile-builder.nix { pkgs = targetPkgs; }).mkProject {
        inherit src gen;
        hostPkgs = hostPkgs;
        defaultCrateOverrides = consumerOverrides;
      }
      else import cargoNix {
        pkgs = targetPkgs;
        defaultCrateOverrides = consumerOverrides;
      };
  in
    if packageName != null then
      if project ? workspaceMembers && project.workspaceMembers ? "${packageName}" then
        project.workspaceMembers.${packageName}.build
      else
        builtins.throw ''
          substrate/rust-release: packageName "${packageName}" not found.
          ${if project ? workspaceMembers
            then "Available members: ${builtins.concatStringsSep ", " (builtins.attrNames project.workspaceMembers)}"
            else "Project has no workspaceMembers — is the source a workspace?"}
        ''
    else
      project.rootCrate.build;

  # Build all target binaries
  binaries = builtins.mapAttrs mkBinary targets;

  # Native binary (matches host system)
  nativeTarget =
    if system == "aarch64-darwin" then "aarch64-apple-darwin"
    else if system == "x86_64-darwin" then "x86_64-apple-darwin"
    else if system == "x86_64-linux" then "x86_64-unknown-linux-musl"
    else if system == "aarch64-linux" then "aarch64-unknown-linux-musl"
    else throw "Unsupported system: ${system}";

  nativeBinary = binaries.${nativeTarget};

  # Runtime-pinned-PATH wrapping. Only fires when:
  #   - consumer sets `runtimeNeedsGen = true`, AND
  #   - the outer flake helper supplied a non-null `gen`
  # Otherwise the binary is returned as-is.
  #
  # Implementation: symlinkJoin + wrapProgram. The bin/<x> symlink is
  # replaced with a shell wrapper that runs the original with
  # `PATH=${gen}/bin:$PATH`. Operator `gen` invocations from inside
  # the wrapped binary find the lock-pinned gen first, before
  # /etc/profiles' activation-time gen — eliminating the bootstrap
  # loop where the binary's job IS to activate the new gen.
  wrapWithRuntimeGen = bin:
    if runtimeNeedsGen && gen != null
    then hostPkgs.symlinkJoin {
      name = "${toolName}-with-pinned-gen";
      paths = [ bin ];
      buildInputs = [ hostPkgs.makeWrapper ];
      postBuild = ''
        for f in "$out/bin/"*; do
          if [ -L "$f" ] || [ -x "$f" ]; then
            wrapProgram "$f" --prefix PATH : "${gen}/bin"
          fi
        done
      '';
    }
    else bin;

  wrappedNativeBinary = wrapWithRuntimeGen nativeBinary;

  # ============================================================================
  # HOST-TOOL BINARY — always-native, never pkgsStatic
  # ============================================================================
  # The `host-tool` output is the binary built against the host's native
  # nixpkgs (regular glibc on linux, regular darwin on macOS). It is the
  # variant consumers should use when the binary is consumed AS A BUILD TOOL
  # — most importantly for substrate's gen-IFD wire (mk-build-spec.nix).
  #
  # The default per-target build (and the `default` output) uses pkgsStatic
  # for linux targets — fine for deploy artifacts, but the static-musl
  # cross-build cascade hits real-world crate compat walls (notify v8.2.0
  # mio cfg-conditional, etc.) and is semantically wrong for SDLC tools
  # that never deploy via static-musl in the first place.
  #
  # `host-tool` is system-scoped: on aarch64-darwin it's an aarch64-darwin
  # binary; on x86_64-linux it's a glibc x86_64-linux binary. Consumers
  # reading `gen.packages.${system}.host-tool` always get something
  # natively runnable on `${system}`.
  hostToolBinary = mkBinary "host-tool" {
    pkgs = hostPkgs;
    isDarwin = system == "aarch64-darwin" || system == "x86_64-darwin";
  };

  # ============================================================================
  # APPS (via release-helpers.nix)
  # ============================================================================
  # Resolve forge command — avoid hostPkgs.forge which collides with a removed
  # nixpkgs alias (throws instead of returning missing).
  forgeCmd = if forge != null
    then "${forge}/bin/forge"
    else "forge";

  releaseHelpers = import ../../util/release-helpers.nix;

  releaseApp = releaseHelpers.mkReleaseApp {
    inherit hostPkgs toolName repo forgeCmd;
    language = "rust";
  };

  bumpApp = releaseHelpers.mkBumpApp {
    inherit hostPkgs toolName forgeCmd;
    language = "rust";
  };

  # Regenerate Cargo.nix — delegates to forge tool regenerate
  regenerateApp = {
    type = "app";
    # If forge IS passed by the caller, use its richer `tool regenerate`
    # flow (handles cross-platform locks + sibling registry updates).
    # Otherwise fall back to a direct crate2nix invocation — the canonical
    # operation regenerate-cargo-nix performs. Without the fallback,
    # callers that don't pass `forge` get `exec: forge: not found` per
    # the bug surfaced in pleme-io/kikai during 2026-05-18 engenho-local
    # bring-up (substrate Task #17 in the operator's tracker).
    program = toString (
      if forge != null then
        hostPkgs.writeShellScript "${toolName}-regenerate-cargo-nix" ''
          set -euo pipefail
          exec ${forgeCmd} tool regenerate --language rust
        ''
      else
        hostPkgs.writeShellScript "${toolName}-regenerate-cargo-nix" ''
          set -euo pipefail
          echo "regenerate-cargo-nix: using crate2nix fallback (no forge passed)"
          # rm-then-regenerate to defeat crate2nix's package-version
          # cache (it keys narHashes by `git+url#0.1.0` not by git rev,
          # so a revision-only bump tricks the cache).
          ${hostPkgs.coreutils}/bin/rm -f crate-hashes.json
          exec ${hostPkgs.nix}/bin/nix run nixpkgs#crate2nix -- generate
        ''
    );
  };

  checkAllApp = releaseHelpers.mkCheckAllApp {
    inherit hostPkgs toolName forgeCmd;
    language = "rust";
  };

  lockPlatformApp = releaseHelpers.mkLockPlatformApp {
    inherit hostPkgs toolName forgeCmd;
    language = "rust";
  };

  # Dev tools for devShell
  devTools = if fenix != null then [
    hostPkgs.fenixRustToolchain
  ] else (with hostPkgs; [
    cargo
    rustc
    clippy
    rustfmt
  ]);
in {
  packages = builtins.listToAttrs (
    builtins.map (targetName: {
      name = "${toolName}-${targetName}";
      value = binaries.${targetName};
    }) (builtins.attrNames targets)
  ) // {
    default = wrappedNativeBinary;
    ${toolName} = wrappedNativeBinary;
    # SDLC-tool variant: built against host's regular nixpkgs (no
    # pkgsStatic). Consumed by substrate's gen-IFD wire and by any
    # other "I just need this binary to run on this system" use case.
    host-tool = hostToolBinary;
    # Unwrapped variant for substrate-internal consumers that need
    # the raw rust-crate output (e.g. nix-bundle, source attribution,
    # debugging). Reaches the same store path the binary would have
    # had without the runtime-PATH wrap.
    unwrapped = nativeBinary;
  };

  # Non-interactive-safe devShell. A bare `substrate.rust.<shape> { src = ./.; }`
  # consumer has no `rust-overlay` flake input and no PWD under non-interactive
  # `nix develop` — both of which the devenv path hard-requires
  # (languages.rust.channel = "stable" resolves a consumer rust-overlay input;
  # devenv.root = getEnv "PWD" asserts non-empty). Pass devenv = null so
  # mkRustDevShell takes its plain-fenix `pkgs.mkShell` branch: the fenix toolchain
  # (cargo/rustc/clippy/rustfmt) + rust-analyzer + crate2nix + the darwin frameworks
  # (incl apple-sdk.privateFrameworksHook via mkDarwinBuildInputs), zero consumer
  # wiring. One call site — fixes every substrate.rust.{tool,workspace,library,
  # service,binary} shape at once; the devenv branch stays for direct consumers.
  devShells.default = (import ../shared/devshell.nix { pkgs = hostPkgs; }).mkRustDevShell {
    pkgs = hostPkgs;
    devenv = null;
    tools = devTools ++ [ hostPkgs.rust-analyzer ];
    # No crate2nix in the gen-path devShell: this pipeline builds via gen +
    # lockfile-builder, not crate2nix, so `crate2nix` is vestigial here — and forcing
    # `crate2nix.packages.${system}.default` (tool-release-flake.nix) breaks `nix
    # develop` when the input doesn't resolve a per-system package. Developers use the
    # `gen` verbs; the crate2nix-backed `regenerate-cargo-nix` app keeps its own ref.
    extraPackages = [ ];
    inherit buildInputs;
  };

  apps = {
    default = {
      type = "app";
      program = "${wrappedNativeBinary}/bin/${toolName}";
    };
    release = releaseApp;
    bump = bumpApp;
    regenerate-cargo-nix = regenerateApp;
    check-all = checkAllApp;
    lock-platform = lockPlatformApp;
  } // (
    # Adapter verbs — one app per `gen` verb, auto-wired when substrate
    # supplies `gen`. Each `gen <verb>` runs on the current directory,
    # which (when the operator runs `nix run .#<verb>` from the
    # consumer's workspace) is the manifest root.
    if gen == null then {}
    else (import ./adapter-apps.nix { pkgs = hostPkgs; inherit gen; }).apps
  );

  # `gen confirm` runs in `nix flake check`. Every consumer gets a
  # spec-invariant CI gate for free; substrate emits the check when
  # `gen` is bound. Opt-out with `confirm = false` (TODO when the
  # consumer-facing flag is wired through).
  checks =
    if gen == null then {}
    else {
      gen-confirm = hostPkgs.runCommand "gen-confirm" {
        nativeBuildInputs = [ gen ];
        src = src;
      } ''
        cp -r $src/* .
        chmod -R u+w .
        gen confirm .
        touch $out
      '';
    };
}
