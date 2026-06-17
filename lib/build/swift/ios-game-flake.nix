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
        ((import ../rust/overlay.nix).mkRustOverlay { inherit fenix system; targets = iosTargets; })
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
        ${appName} — the iOS-game SDLC devloop (nix run .#<app>)

        EDIT → PROVE (host) → DEPLOY (VM / phone)

          nix run .#test          run the host test suite (the proven core layers)
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

    runSimApp = mkApp "run-sim" ''
      ${cargo} build --target ${simTarget} ${appPflag}
      : "''${ASOBI_SIM_UDID:?set ASOBI_SIM_UDID to a booted simulator UDID (xcrun simctl list devices booted)}"
      exec ${cargo} run -p ${embarqueCrate} -- sim-run \
        --exe "target/${simTarget}/debug/${appBin}" \
        --app-name ${lib.escapeShellArg appName} \
        --bundle-id ${lib.escapeShellArg bundleId} \
        --udid "$ASOBI_SIM_UDID" \
        --version ${lib.escapeShellArg version} \
        --min-os ${lib.escapeShellArg minOs} \
        --out "target/${appName}-sim.app" \
        ${sceneFlag} \
        ''${ASOBI_SCREENSHOT:+--screenshot "$ASOBI_SCREENSHOT"}
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
        --out "target/${appName}-device.app"
    '';

    gameApp = mkApp "game" ''
      ${cargo} build --target ${simTarget} ${appPflag}
      : "''${ASOBI_SIM_UDID:?set ASOBI_SIM_UDID to a booted simulator UDID (xcrun simctl list devices booted)}"
      exec ${cargo} run -p ${embarqueCrate} -- game \
        --game ${lib.escapeShellArg defgame} \
        --exe "target/${simTarget}/debug/${appBin}" \
        --udid "$ASOBI_SIM_UDID" \
        --out "target/${appName}-game.app" \
        ''${ASOBI_SCREENSHOT:+--screenshot "$ASOBI_SCREENSHOT"}
    '';

    devShell = pkgs.mkShellNoCC {
      name = appName;
      packages = [ toolchain pkgs.cargo-nextest pkgs.git ] ++ (extraPackages pkgs);
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
      test = testApp;
      lint = lintApp;
      build-sim = buildSimApp;
      build-device = buildDeviceApp;
      run-sim = runSimApp;
      game-device = gameDeviceApp;
    } // lib.optionalAttrs (defgame != null) { game = gameApp; };
  })
