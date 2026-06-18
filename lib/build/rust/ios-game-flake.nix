# ios-game-flake.nix — the iOS-game SDLC as a distribution of `nix run` apps.
#
# Extracts the asobi devloop (cross-compile Rust → iOS, test/lint on the host,
# deploy to the simulator "VM" or a tethered phone) into ONE reusable substrate
# builder, so any pure-Rust iOS game/app gets the whole guided SDLC from a small
# typed config. Pillar 9 (SDLC) for the Apple target: the peer of
# `rust-tool-release-flake.nix` (CLI tools) and `service/product-sdlc.nix`
# (web/backend products).
#
# Consumer flake (the entire footprint):
#
#   {
#     inputs.substrate.url = "github:pleme-io/substrate";
#     inputs.nixpkgs.follows  = "substrate/nixpkgs";
#     inputs.fenix.follows    = "substrate/fenix";
#     inputs.flake-utils.follows = "substrate/flake-utils";
#     outputs = i: (import "${i.substrate}/lib/build/swift/ios-game-flake.nix" {
#       inherit (i) nixpkgs fenix flake-utils;
#     }) {
#       src = ./.;
#       appCrate = "asobi-smoke";
#       bundleId = "io.pleme.asobi";
#       hostTestCrates = [ "asobi" "asobi-ecs" "asobi-merge" /* … */ ];
#       sceneDelegate = "AsobiSceneDelegate";
#       defgame = "examples/game.lisp";
#     };
#   }
#
# Produces (per darwin system):
#   devShells.default        — the impure-toolchain devshell
#   apps.sdlc                — the guided devloop (start here)
#   apps.test / apps.lint    — host cargo test / clippy over `hostTestCrates`
#   apps.build-sim / build-device — cross-compile the app for the sim / device
#   apps.run-sim             — deploy to the iOS Simulator (the "VM")
#   apps.game-device         — sign + deploy to a tethered iPhone
#   apps.game                — (defgame …)-driven deploy (only if `defgame` set)
#
# THE IMPURITY BOUNDARY (the one sanctioned filesystem reach): the iOS SDK, the
# Metal compiler, the linker, and codesign live inside the system Xcode toolchain.
# Apps + devshell append /usr/bin + set DEVELOPER_DIR so xcrun/clang resolve, but
# never export SDKROOT (rustc discovers the correct SDK per --target via xcrun).
# Mirrors `build/swift/sdk-helpers.nix`.
#
# TIER-HONEST: the multi-step deploy apps (run-sim/game-device) are thin glue —
# they set the impure env, cross-compile, and `exec` the typed `embarque`
# executor (the real bundle/sign/install/launch logic is Rust, never shell). The
# named destination is a single `embarque sim` / `embarque device` verb that owns
# the build + target-resolution too, collapsing each wrapper to a one-line exec.
{ nixpkgs, fenix, flake-utils }:

{
  # ── required ──
  appCrate,                       # the iOS app crate (`cargo … -p <appCrate>`)
  bundleId,                       # CFBundleIdentifier for the raw sim/device path
  # An iOS DEVLOOP is inherently impure (Xcode toolchain / sim / device — the
  # impurity boundary) and operates on the operator's LIVE working tree (the apps
  # `cd` to the git root at runtime to build + deploy the current checkout), not
  # an immutable store copy. `src` is accepted for API symmetry with the other
  # substrate flake builders but is not read at eval — there is no pure iOS build.
  src ? null,
  # ── host SDLC ──
  hostTestCrates ? [ ],           # crates `test`/`lint` exercise on the host
  # ── app identity ──
  appBin ? appCrate,              # built exe name: target/<triple>/debug/<appBin>
  appName ? appCrate,             # CFBundleDisplayName
  embarqueCrate ? "embarque",     # the typed deploy executor crate
  version ? "0.1.0",
  minOs ? "14.0",
  sceneDelegate ? null,           # UISceneDelegate subclass → UIApplicationSceneManifest
  defgame ? null,                 # repo-relative (defgame …) lisp → the `game` app
  goldenScreenshot ? null,        # repo-relative golden PNG → `integ-sim` default
  # ── platform ──
  iosTargets ? [ "aarch64-apple-ios" "aarch64-apple-ios-sim" ],
  systems ? [ "aarch64-darwin" ], # iOS build host is darwin-only
  extraPackages ? (_pkgs: [ ]),   # extra devshell tools
}:

flake-utils.lib.eachSystem systems (system:
  let
    pkgs = import nixpkgs {
      inherit system;
      overlays = [
        ((import ./overlay.nix).mkRustOverlay { inherit fenix system; targets = iosTargets; })
      ];
    };
    inherit (pkgs) lib;
    toolchain = pkgs.fenixRustToolchain;
    cargo = "${toolchain}/bin/cargo";

    simTarget = "aarch64-apple-ios-sim";
    devTarget = "aarch64-apple-ios";

    pflags = lib.concatMapStringsSep " " (c: "-p ${c}") hostTestCrates;
    appPflag = "-p ${lib.escapeShellArg appCrate}";
    sceneFlag = lib.optionalString (sceneDelegate != null) "--scene-delegate ${lib.escapeShellArg sceneDelegate}";

    # The ONE sanctioned impurity: reach the system Xcode toolchain for xcrun SDK
    # discovery + the clang linker + codesign. Never export SDKROOT.
    impureEnv = ''
      export DEVELOPER_DIR="''${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
      case ":$PATH:" in *":/usr/bin:"*) ;; *) export PATH="$PATH:/usr/bin" ;; esac
      export PATH="${toolchain}/bin:$PATH"
      cd "$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
    '';

    mkApp = name: body: {
      type = "app";
      program = toString (pkgs.writeShellScript "${appName}-${name}" ''
        set -euo pipefail
        ${impureEnv}
        ${body}
      '');
    };

    # ── apps ──────────────────────────────────────────────────────────────
    # The guide is a pure text artifact (writeText) the app just `cat`s — no
    # heredoc (indented-string stripping would un-terminate it), no shell logic.
    sdlcGuideText =
      ''
        ${appName} — the iOS-game SDLC devloop (nix run .#<app>), 100% LOCAL.
        Deploy targets the simulator / phone attached to THIS machine; there is
        no remote CI in the delivery path — the gate is a local verb too.

        EDIT → CHECK (local gate) → DEPLOY (VM / phone) — live or one-shot

          nix run .#mcp           AI surface: an MCP server (the agent drives the
                                  SDLC + SEES the sim via screenshots) — register it
                                  in .mcp.json as `nix run .#mcp`
          nix run .#watch-sim     LIVE: rebuild + redeploy to the sim on every edit
          nix run .#watch         re-run the host tests on every change (TDD loop)
          nix run .#check         the local gate: lint + test + build-sim
          nix run .#integ-sim     on-device integration: deploy + golden screenshot
          nix run .#test          the host test suite (the proven core layers)
          nix run .#lint          clippy -D warnings over the host crates
          nix run .#build-sim     cross-compile ${appCrate} → ${simTarget}
          nix run .#build-device  cross-compile ${appCrate} → ${devTarget}
          nix run .#run-sim       deploy + launch on the iOS Simulator (the "VM")
          nix run .#game-device   sign + deploy + launch on a tethered iPhone
      ''
      + lib.optionalString (defgame != null)
        "  nix run .#game          (defgame …)-driven deploy from ${defgame}\n"
      + ''

        DEPLOY ENV (set before run-sim / game-device):
          run-sim     ASOBI_SIM_UDID   a booted simulator UDID
                        xcrun simctl list devices booted
                      ASOBI_SCREENSHOT (optional) PNG path to capture
          game-device ASOBI_DEVICE     tethered device UDID (xcrun xctrace list devices)
                      ASOBI_IDENTITY   codesign identity (security find-identity -p codesigning)
                      ASOBI_TEAM       Apple development Team ID
                      ASOBI_PROFILE    .mobileprovision path

        Everything runs through the impure Xcode toolchain automatically
        (DEVELOPER_DIR + /usr/bin); the deploy logic itself is the typed
        `${embarqueCrate}` executor — no shell beyond this env glue.
      '';
    sdlcGuide = mkApp "sdlc"
      "exec ${pkgs.coreutils}/bin/cat ${pkgs.writeText "${appName}-sdlc-guide.txt" sdlcGuideText}";

    testApp = mkApp "test" "exec ${cargo} test ${pflags}";
    lintApp = mkApp "lint" "exec ${cargo} clippy ${pflags} --all-targets -- -D warnings";
    buildSimApp = mkApp "build-sim" "exec ${cargo} build --target ${simTarget} ${appPflag}";
    buildDeviceApp = mkApp "build-device" "exec ${cargo} build --target ${devTarget} ${appPflag}";

    # The LOCAL gate — the "CI" for a local-delivery devloop. There is no remote
    # CI in the iOS delivery path (the VM/phone are attached to THIS machine), so
    # the regression gate is a local `nix run` verb, run before deploying.
    checkApp = mkApp "check" ''
      echo "▶ lint";      ${cargo} clippy ${pflags} --all-targets -- -D warnings
      echo "▶ test";      ${cargo} test ${pflags}
      echo "▶ build-sim"; ${cargo} build --target ${simTarget} ${appPflag}
      echo "✓ check passed — lint + test + build-sim (ready to deploy locally)"
    '';

    # The inner TDD loop: re-run the host tests on every source change. The
    # continuous-convergence shape of the devloop — edit, see green, deploy.
    watchApp = mkApp "watch" ''
      exec ${pkgs.watchexec}/bin/watchexec --clear --restart \
        --exts rs,lisp,toml \
        -- ${cargo} test ${pflags}
    '';

    # Shared run-sim implementation: build the app, then deploy + launch it on the
    # booted simulator via the typed embarque executor. `run-sim` (one-shot),
    # `watch-sim` (re-run on every change — the live code-flow loop), and
    # `integ-sim` (golden assertion) all drive THIS exact script, so the live loop,
    # a manual deploy, and the integration gate are byte-identical. Optional env:
    # ASOBI_SCREENSHOT (capture a PNG), ASOBI_GOLDEN + ASOBI_TOLERANCE (on-device
    # visual-regression assertion — embarque diffs the shot against the golden and
    # exits non-zero past the tolerance).
    runSimScript = pkgs.writeShellScript "${appName}-run-sim-impl" ''
      set -euo pipefail
      ${impureEnv}
      ${cargo} build --target ${simTarget} ${appPflag}
      ASOBI_SIM_UDID="''${ASOBI_SIM_UDID:-$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[0-9A-Fa-f-]{36}' | head -1)}"
      : "''${ASOBI_SIM_UDID:?no booted simulator found — boot one (xcrun simctl boot <device> / open Simulator.app), or set ASOBI_SIM_UDID}"
      exec ${cargo} run -p ${embarqueCrate} -- sim-run \
        --exe "target/${simTarget}/debug/${appBin}" \
        --app-name ${lib.escapeShellArg appName} \
        --bundle-id ${lib.escapeShellArg bundleId} \
        --udid "$ASOBI_SIM_UDID" \
        --version ${lib.escapeShellArg version} \
        --min-os ${lib.escapeShellArg minOs} \
        --out "target/${appName}-sim.app" \
        ${sceneFlag} \
        ''${ASOBI_SCREENSHOT:+--screenshot "$ASOBI_SCREENSHOT"} \
        ''${ASOBI_GOLDEN:+--golden "$ASOBI_GOLDEN" --tolerance "''${ASOBI_TOLERANCE:-0.02}"}
    '';
    runSimApp = { type = "app"; program = toString runSimScript; };

    # LIVE CODE FLOW → the virtual phone: watch the source tree; on every change to
    # a .rs/.lisp/.metal/.toml file, rebuild + redeploy to the simulator. The
    # warm-reload loop (app relaunches each cycle, ~2s) — the realistic
    # best-in-class live loop for a native iOS app; true state-preserving hot
    # reload is the named frontier (see docs/live-dev.md).
    watchSimApp = mkApp "watch-sim" ''
      ASOBI_SIM_UDID="''${ASOBI_SIM_UDID:-$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[0-9A-Fa-f-]{36}' | head -1)}"
      : "''${ASOBI_SIM_UDID:?no booted simulator found — boot one (xcrun simctl boot <device> / open Simulator.app), or set ASOBI_SIM_UDID}"
      echo "live reload → simulator $ASOBI_SIM_UDID — edit any .rs/.lisp/.metal/.toml to redeploy"
      exec ${pkgs.watchexec}/bin/watchexec --restart --clear \
        --exts rs,lisp,metal,toml \
        -- ${runSimScript}
    '';

    # ON-DEVICE INTEGRATION: deploy + launch on the simulator, capture a screenshot,
    # and assert it matches a committed golden within ASOBI_TOLERANCE (default 2%).
    # Proves the WHOLE render pipeline on the real Metal GPU — a visual-regression
    # integration test that host `check` cannot reach. ASOBI_GOLDEN required.
    integSimApp = mkApp "integ-sim" ''
      ASOBI_SIM_UDID="''${ASOBI_SIM_UDID:-$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[0-9A-Fa-f-]{36}' | head -1)}"
      : "''${ASOBI_SIM_UDID:?no booted simulator found — boot one (xcrun simctl boot <device> / open Simulator.app), or set ASOBI_SIM_UDID}"
      export ASOBI_GOLDEN="''${ASOBI_GOLDEN:-${lib.optionalString (goldenScreenshot != null) goldenScreenshot}}"
      : "''${ASOBI_GOLDEN:?set ASOBI_GOLDEN (or the goldenScreenshot config) to the golden PNG to assert against}"
      export ASOBI_SCREENSHOT="''${ASOBI_SCREENSHOT:-target/${appName}-integ.png}"
      echo "on-device integration → diff vs $ASOBI_GOLDEN (tol ''${ASOBI_TOLERANCE:-0.02})"
      exec ${runSimScript}
    '';

    gameDeviceApp = mkApp "game-device" ''
      ${cargo} build --target ${devTarget} ${appPflag}
      : "''${ASOBI_DEVICE:?set ASOBI_DEVICE to the tethered device UDID (xcrun xctrace list devices)}"
      : "''${ASOBI_IDENTITY:?set ASOBI_IDENTITY to a codesign identity (security find-identity -p codesigning)}"
      : "''${ASOBI_TEAM:?set ASOBI_TEAM to the Apple development Team ID}"
      : "''${ASOBI_PROFILE:?set ASOBI_PROFILE to the .mobileprovision path}"
      exec ${cargo} run -p ${embarqueCrate} -- device-run \
        --exe "target/${devTarget}/debug/${appBin}" \
        --device "$ASOBI_DEVICE" \
        --identity "$ASOBI_IDENTITY" \
        --team-id "$ASOBI_TEAM" \
        --profile "$ASOBI_PROFILE" \
        --bundle-id ${lib.escapeShellArg bundleId} \
        --app-name ${lib.escapeShellArg appName} \
        --version ${lib.escapeShellArg version} \
        --min-os ${lib.escapeShellArg minOs} \
        --out "target/${appName}-device.app" \
        ${sceneFlag}
    '';

    gameApp = mkApp "game" ''
      ${cargo} build --target ${simTarget} ${appPflag}
      ASOBI_SIM_UDID="''${ASOBI_SIM_UDID:-$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[0-9A-Fa-f-]{36}' | head -1)}"
      : "''${ASOBI_SIM_UDID:?no booted simulator found — boot one (xcrun simctl boot <device> / open Simulator.app), or set ASOBI_SIM_UDID}"
      exec ${cargo} run -p ${embarqueCrate} -- game \
        --game ${lib.escapeShellArg defgame} \
        --exe "target/${simTarget}/debug/${appBin}" \
        --udid "$ASOBI_SIM_UDID" \
        --out "target/${appName}-game.app" \
        ''${ASOBI_SCREENSHOT:+--screenshot "$ASOBI_SCREENSHOT"}
    '';

    # AI-ACCESSIBLE by default: an MCP server (JSON-RPC over stdio) exposing the
    # whole SDLC + the virtual phone to any agent — list/screenshot the sim (the
    # screenshot returns AS AN IMAGE so the agent SEES it), run host tests, deploy,
    # and the on-device golden integration. Register it via a repo `.mcp.json`
    # whose command is `nix run .#mcp`. The app config is wired in here so the
    # tools are turnkey. (`cargo run` builds embarque once at startup, then serves;
    # cargo chatter is stderr — stdout stays pure JSON-RPC.)
    mcpFlags = lib.concatStringsSep " " (
      [
        "--app-crate ${lib.escapeShellArg appCrate}"
        "--app-bin ${lib.escapeShellArg appBin}"
        "--app-name ${lib.escapeShellArg appName}"
        "--bundle-id ${lib.escapeShellArg bundleId}"
        "--sim-target ${simTarget}"
        "--version ${lib.escapeShellArg version}"
        "--min-os ${lib.escapeShellArg minOs}"
      ]
      ++ lib.optional (sceneDelegate != null) "--scene-delegate ${lib.escapeShellArg sceneDelegate}"
      ++ lib.optional (goldenScreenshot != null) "--golden ${lib.escapeShellArg goldenScreenshot}"
      ++ map (c: "--host-test-crate ${lib.escapeShellArg c}") hostTestCrates
    );
    mcpApp = mkApp "mcp" ''
      exec ${cargo} run -q -p ${embarqueCrate} -- mcp ${mcpFlags}
    '';

    devShell = pkgs.mkShellNoCC {
      name = appName;
      packages = [ toolchain pkgs.cargo-nextest pkgs.git pkgs.watchexec ] ++ (extraPackages pkgs);
      shellHook = ''
        export DEVELOPER_DIR="''${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
        case ":$PATH:" in *":/usr/bin:"*) ;; *) export PATH="$PATH:/usr/bin" ;; esac
        echo "${appName} devshell — $(rustc --version 2>/dev/null || echo 'rustc?')"
        echo "  ios-sim SDK: $(/usr/bin/xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || echo MISSING)"
        echo "  SDLC: nix run .#sdlc   (the guided devloop)"
      '';
    };
  in {
    devShells.default = devShell;
    apps = {
      sdlc = sdlcGuide;
      mcp = mcpApp;
      watch = watchApp;
      watch-sim = watchSimApp;
      check = checkApp;
      integ-sim = integSimApp;
      test = testApp;
      lint = lintApp;
      build-sim = buildSimApp;
      build-device = buildDeviceApp;
      run-sim = runSimApp;
      game-device = gameDeviceApp;
    } // lib.optionalAttrs (defgame != null) { game = gameApp; };
  })
