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
  # consumer flake exposes every REAL gen verb as an app:
  # `nix run .#{lock,build-spec,confirm}` (see adapter-apps.nix —
  # phantom plan/diff/sbom removed). Single substrate change,
  # the gen operator verbs in every consumer.
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
  # Extra packages for the DEV SHELL only, by nixpkgs attribute name.
  #
  # Distinct from `nativeBuildInputs`, which feeds the derivation: this is for
  # tooling the TESTS need and the build does not. `blue` is the motivating
  # case — one of its tests shells out to `cargo build --target
  # wasm32-unknown-unknown`, which needs `lld`. That test passed on every
  # developer laptop, because a laptop has an ambient toolchain, and failed on
  # the first CI run that ever executed it with `error: linker 'lld' not
  # found`. The devShell must carry what the tests need, or "passes locally"
  # means "passes on machines that happen to have it".
  #
  # Defaults to `[]`, so no existing consumer changes.
  devShellPackages ? [],
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
  # Typed test-gate declaration — see ./test-check.nix. Default ON;
  # `{ enable = false; reason = "…"; }` is the only way to turn it off and
  # a bare boolean is refused. NOTE the availability caveat below: on the
  # DEFAULT `lockfile` build path substrate cannot run tests at all yet, so
  # this declaration only bites for `buildMode = "cargo-nix"` consumers.
  tests ? {},
  testCrateFlags ? [],
  testInputs ? [],
  # The `substrate.rust.<shape>` entry point this consumer came through,
  # forwarded by mk-rust-tool-flake.nix. It does NOT select a builder — all
  # five shapes land here — but it travels into `who` below so every
  # diagnostic names the shape the consumer asked for instead of a generic
  # "rust-release". See ./shape.nix for the full statement and the fleet
  # counts behind that decision.
  shape ? "tool",
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

        # Strip the shipped executable. Default-on: the highest posture has to be
        # what you get without asking.
        #
        # Cargo's `[profile.release] strip = true` is INERT on this path.
        # gen/lockfile-builder and crate2nix drive rustc directly and never read
        # Cargo profiles, so a crate can declare strip, build here, and still ship
        # a full symbol table. hanabi is the live case: its Cargo.toml sets
        # strip = true and the musl artifact still came out
        # "static-pie linked, not stripped", which is what failed the camelot
        # web-ui image's hardened conformance check once the Go shim was removed
        # and the check finally looked at the Rust binary.
        #
        # stdenv's fixupPhase is already running; its default stripDebugList takes
        # debug symbols (-S) out of bin/ and deliberately KEEPS .symtab.
        # stripAllList escalates that same phase to --strip-all, and stays
        # cross-aware by using the TARGET's binutils — which a bare `strip` in
        # postInstall would not do for a musl triple.
        #
        # Scoped to this crate's override deliberately. A global
        # `-Cstrip=symbols` would also strip dependency rlibs, whose symbols the
        # final link needs; that breaks the build instead of hardening it.
        #
        # Complements static-spa-image.nix's own strip rather than replacing it:
        # this fixes the PRODUCER, so every gen-built tool ships stripped, while
        # that one holds the image-level promise for a `server` built by some
        # other flake with its own substrate pin.
        stripAllList = (attrs.stripAllList or []) ++ [ "bin" ];
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

  # The one typed surface deciding which checks this builder emits.
  testCheck = import ./test-check.nix { inherit (hostPkgs) lib; };

  # Validates `shape` against the closed set and yields the identity the
  # check surface reports under. Evaluating this is what makes an unknown
  # shape a throw rather than a silently-ignored argument.
  shapeSpec = import ./shape.nix { inherit (hostPkgs) lib; };
  resolvedShape = shapeSpec.resolve toolName shape;

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
  # `nix run .#<toolName>` needs to know WHICH binary to exec. With no
  # `apps.<toolName>` (this builder's apps are the SDLC verbs), nix falls back
  # to the package and guesses the program from the derivation's pname — which
  # is `rust_<packageName>`. That guess is wrong for exactly the pattern this
  # builder documents: `toolName = "mamorigami"`, `packageName =
  # "mamorigami-cli"`, `[[bin]] name = "mamorigami"`. The guess produced
  # `bin/mamorigami-cli`, which does not exist, and `nix run` failed with
  # "unable to execute … No such file or directory".
  #
  # `meta.mainProgram` is the answer nix looks for first, and `toolName` is by
  # definition the binary name. Applied to every package variant so
  # `nix run .#<toolName>-<target>` works too.
  withMainProgram = drv:
    drv // { meta = (drv.meta or {}) // { mainProgram = toolName; }; };
in {
  packages = builtins.listToAttrs (
    builtins.map (targetName: {
      name = "${toolName}-${targetName}";
      value = withMainProgram binaries.${targetName};
    }) (builtins.attrNames targets)
  ) // {
    default = withMainProgram wrappedNativeBinary;
    ${toolName} = withMainProgram wrappedNativeBinary;
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
    # Consumer-declared dev-shell tooling, resolved by name against the host
    # package set the shell is actually built from. See `devShellPackages`.
    extraPackages = builtins.map (name: hostPkgs.${name}) devShellPackages;
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

  # `gen confirm --if-present` runs in `nix flake check`. Every consumer
  # gets a free CI gate that its committed `Cargo.gen.lock` (the slim
  # delta) is FRESH against the workspace's `Cargo.lock` — substrate
  # emits it whenever `gen` is bound. Opt-out with `confirm = false`
  # (TODO when the consumer-facing flag is wired through).
  #
  # WHY `gen confirm --if-present` — the DELTA-FRESHNESS gate
  # (tier-honest — verified offline in the check sandbox, 2026-07-24):
  #   * This check runs in a plain `runCommand`: NO network and NO
  #     `~/.cargo` registry, and `src` excludes the gitignored
  #     `Cargo.build-spec.json` (delta-only doctrine commits the slim
  #     `Cargo.gen.lock` instead).
  #   * `gen confirm` is a PURE offline verb (gen bd36597+): it reads
  #     ONLY `Cargo.lock` + `Cargo.gen.lock`, recomputes
  #     `sha256(Cargo.lock)` (== `builtins.hashFile "sha256"`) and
  #     compares it to the delta's recorded `cargo_lock_sha256` — the
  #     D2 freshness tie. It is NOT `Adapter::confirm` (which regenerates
  #     the spec via `cargo metadata` — no cargo/registry/net here).
  #   * `--if-present` = gate a delta that EXISTS but is stale/untied
  #     (`rc=1`), TOLERATE a consumer that legitimately commits no delta
  #     (the IFD reconstruction path — ~10 fleet consumers today).
  #     Without it, a strict `gen confirm` would REGRESS every consumer
  #     not on the delta-only doctrine (missing delta → `rc=1`). The
  #     interim `gen check` (manifest-parse only) never gated freshness;
  #     this is strictly stronger for delta-committed consumers and
  #     regression-free for the rest.
  #   * The gate this gives is DELTA FRESHNESS: a `cargo update` landed
  #     without a `gen build` (Cargo.lock changed, Cargo.gen.lock did
  #     not) is caught offline. The I1/I2/I3 build-spec invariants still
  #     need the generated spec (`cargo metadata`, unavailable offline)
  #     and are out of scope here. The attr name stays `gen-confirm` so
  #     the fleet wiring is unchanged. (Note: consumers WITH a committed
  #     delta also hit substrate's eval-time `lockfile-delta.nix` D2
  #     guard, which throws on a stale delta during build-graph
  #     reconstruction — this check is the explicit, isolated
  #     nix-flake-check surface of the same tie.)
  #
  # ── checks.build + checks.tests (2026-07-27) ──────────────────────────
  #
  # `gen-confirm` above was, until this change, the ONLY thing a
  # tool-release consumer's `nix flake check` ever BUILT. Everything else
  # — packages, devShells, apps — is merely EVALUATED by that command
  # (nix prints "(build skipped)"). So a consumer whose flake exposed no
  # other check was green over a crate that had never been compiled:
  # measured on `forge`, `nix flake check` returned exit 0 in 8.66s with
  # a `compile_error!` in its test module AND with literal non-Rust
  # garbage in a function body.
  #
  #   checks.build — the SHIPPED artifact compiles. This is the same
  #     derivation as `packages.default`/`unwrapped`, so a consumer that
  #     also builds `.#default` in CI pays for it exactly once. It is the
  #     floor: after this, no substrate-built Rust flake can be green over
  #     an unbuilt crate.
  #
  #   checks.tests — ABSENT on the default `lockfile` build path, and that
  #     absence is deliberate rather than an oversight. gen's build spec
  #     carries no dev-dependency graph (a crate record has
  #     `runtime_dependencies` + `build_dependencies` only, and
  #     spec-invariants.nix REJECTS a `kind = "dev"` edge appearing in
  #     either), and nixpkgs' bare `buildRustCrate` has no `runTests`
  #     argument at all — only `buildTests`, which compiles test targets
  #     without dev-dep externs and never runs them. 12 of 13 surveyed
  #     consumers declare `[dev-dependencies]`, so a test target simply
  #     cannot be compiled here today. Emitting an always-green
  #     `checks.tests` that ran nothing would be strictly worse than
  #     emitting none — a guard over an empty subject set reports the
  #     tier it does not have (UNREPRESENTABILITY §II.3, tier ⊥).
  #     The load-bearing fix is UPSTREAM in gen-cargo (emit
  #     `dev_dependencies` edges into the spec, per the ★★ GEN TYPED-SPEC
  #     CONTRACT) plus a substrate-side test-runner derivation; a Nix-side
  #     re-derivation of cargo's dev-dep feature resolution would be a
  #     second, untested copy of the resolver.
  #     Tracked: `pending-rust-test-check: lockfile-dev-deps`.
  #     On `buildMode = "cargo-nix"` the generated Cargo.nix DOES carry
  #     devDependencies + crate2nix's `crateWithTest`, so `checks.tests`
  #     is emitted there and genuinely runs the crate's tests.
  #
  # Until that lands, the real-test leg for a lockfile-path consumer is
  # the `cargo test` job in substrate's own `cargo-ci.yml` (inside this
  # flake's devShell, on the CI runner) — named there, not implied here.
  checks = testCheck.surface {
    # Names the shape as well as the crate: a `substrate.rust.library`
    # consumer reading a diagnostic can see it was built by the tool-release
    # builder, which is the fact that used to be invisible.
    who = resolvedShape.who;
    decl = tests;
    mode = effectiveMode;
    buildDrv = nativeBinary;
    mkTests = _: nativeBinary.override {
      runTests = true;
      inherit testCrateFlags testInputs;
    };
    extra =
      if gen == null then {}
      else {
        gen-confirm = hostPkgs.runCommand "gen-confirm" {
          nativeBuildInputs = [ gen ];
          src = src;
        } ''
          cp -r $src/* .
          chmod -R u+w .
          gen confirm . --if-present
          touch $out
        '';
      };
  };
}
