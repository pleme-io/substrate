# Regression tests for lib/module-trio.nix.
#
# ── Why this file exists ───────────────────────────────────────────────────
# `mkModuleTrio` is the macro that emits the NixOS + nix-darwin + home-manager
# modules for a large part of the fleet, and it had NO tests. That is how
# `withShikumiConfig` came to mean "home-manager only" without anyone noticing:
# the flag read as a whole-trio feature at every call site, and the system arms
# silently omitted it. A consumer shipping a privileged system daemon with a
# shikumi-typed config surface got the daemon options and no way to feed them.
#
# These tests pin the behaviour that was ambiguous, so the next person to touch
# the macro finds out from a red test rather than from a daemon reading
# prescribed defaults in production.
#
# Run: nix build .#checks.<system>.module-trio
# IFD-free: evaluates the emitted modules against a stub universe. It never
# builds a package and never needs a real nixpkgs module tree.
{ pkgs, lib ? pkgs.lib }:

let
  trioLib = import ../module-trio.nix { inherit lib; };

  # A spec exercising the shape that regressed: a privileged SYSTEM daemon
  # (no subcommand) carrying a shikumi config surface.
  daemonSpec = {
    name = "testd";
    description = "test daemon";
    withSystemDaemon = true;
    daemonSubcommand = "";
    withShikumiConfig = true;
    shikumiDefaults = {
      metrics = { port = 9101; };
      logging = { format = "json"; };
    };
  };

  trio = trioLib.mkModuleTrio daemonSpec;

  # A spec with the flag OFF, to prove the option is genuinely conditional
  # rather than always-present-and-empty.
  plainTrio = trioLib.mkModuleTrio {
    name = "plaind";
    description = "plain daemon";
    withSystemDaemon = true;
  };

  dummyPkg = pkgs.runCommand "testd" { } "mkdir -p $out/bin; touch $out/bin/testd; chmod +x $out/bin/testd";

  anyAttrs = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = {}; };
  anyList = lib.mkOption { type = lib.types.listOf lib.types.anything; default = []; };

  # The system universe, stubbed: `environment.etc` and `systemd.services`
  # are declared locally so we never import nixpkgs' whole NixOS module set —
  # that keeps this eval in milliseconds and IFD-free.
  systemStubs = {
    options = {
      environment.etc = anyAttrs;
      environment.systemPackages = anyList;
      systemd.services = anyAttrs;
      launchd.daemons = anyAttrs;
    };
  };

  # The home-manager universe, stubbed the same way.
  hmStubs = {
    options = {
      home.homeDirectory = lib.mkOption { type = lib.types.str; default = "/home/test"; };
      home.packages = anyList;
      home.file = anyAttrs;
      home.activation = anyAttrs;
      launchd.agents = anyAttrs;
      systemd.user.services = anyAttrs;
      blackmatter.components.anvil.mcp.servers = anyAttrs;
    };
  };

  # The HM daemon arm branches on `pkgs.stdenv.isDarwin`; both branches are
  # exercised from whichever host runs the check.
  pkgsOn = isDarwin: pkgs // { stdenv = pkgs.stdenv // { inherit isDarwin; }; };

  evalSystem = module: settings: lib.evalModules {
    modules = [
      module
      systemStubs
      ({ ... }: {
        services.testd = {
          enable = true;
          package = dummyPkg;
          daemon.enable = true;
        } // lib.optionalAttrs (settings != null) { inherit settings; };
      })
    ];
    specialArgs = { inherit pkgs; };
  };

  withSettings = evalSystem trio.nixosModule {
    metrics = { port = 9201; };
  };
  withoutSettings = evalSystem trio.nixosModule null;

  etcOf = e: e.config.environment.etc;
  unitOf = e: e.config.systemd.services."testd-daemon" or null;

  anvilTrio = trioLib.mkModuleTrio {
    name = "anvild";
    description = "anvil mcp";
    withAnvilMcp = true;
  };

  anvilEntry = (lib.evalModules {
    modules = [
      anvilTrio.homeManagerModule
      hmStubs
      { services.anvild.mcp = { enable = true; package = dummyPkg; }; }
    ];
    specialArgs = { pkgs = pkgsOn true; };
  }).config.blackmatter.components.anvil.mcp.servers.anvild;

  # ── Restart policy fixtures ────────────────────────────────────────
  # A tool that names its policy once, in its spec; every arm inherits it.
  policyTrio = trioLib.mkModuleTrio {
    name = "policyd";
    description = "policy daemon";
    withSystemDaemon = true;
    withUserDaemon = true;
    daemonRestartPolicy = "on-failure";
  };

  evalPolicySystem = module: daemon: lib.evalModules {
    modules = [
      module
      systemStubs
      { services.policyd = { enable = true; package = dummyPkg; daemon = { enable = true; } // daemon; }; }
    ];
    specialArgs = { inherit pkgs; };
  };

  evalPolicyHome = isDarwin: daemon: lib.evalModules {
    modules = [
      policyTrio.homeManagerModule
      hmStubs
      { programs.policyd = { enable = true; package = dummyPkg; daemon = { enable = true; } // daemon; }; }
    ];
    specialArgs = { pkgs = pkgsOn isDarwin; };
  };

  nixosRestartOf = e: e.config.systemd.services."policyd-daemon".serviceConfig.Restart;
  launchdKeepAliveOf = e: e.config.launchd.daemons."policyd-daemon".serviceConfig.KeepAlive;
  agentKeepAliveOf = e: e.config.launchd.agents."policyd-daemon".config.KeepAlive;
  userUnitRestartOf = e: e.config.systemd.user.services."policyd-daemon".Service.Restart;

  onFailureKeepAlive = { SuccessfulExit = false; Crashed = true; };
  restartPolicy = import ../hm/restart-policy.nix { inherit lib; };

  # ── User-daemon scheduling class and config-change restart (2026-09-28) ──
  # A user daemon with a config surface, so its rendered config has a digest.
  digestTrio = trioLib.mkModuleTrio {
    name = "digestd";
    description = "digest daemon";
    withUserDaemon = true;
    hmNamespace = "services";
    withShikumiConfig = true;
    shikumiDefaults = { port = 1; };
  };
  evalDigest = daemon: settings: lib.evalModules {
    modules = [
      digestTrio.homeManagerModule
      hmStubs
      { services.digestd = { enable = true; package = dummyPkg; daemon = { enable = true; } // daemon; inherit settings; }; }
    ];
    specialArgs = { pkgs = pkgsOn true; };
  };
  digestOf = e: e.config.launchd.agents."digestd-daemon".config.EnvironmentVariables.PLEME_CONFIG_DIGEST or null;
  agentProcessTypeOf = e: e.config.launchd.agents."policyd-daemon".config.ProcessType;

  workloadClasses = import ../hm/workload-class.nix { inherit lib; };

  classTrio = trioLib.mkModuleTrio {
    name = "classd";
    description = "class daemon";
    withSystemDaemon = true;
    withUserDaemon = true;
  };

  declaredTrio = trioLib.mkModuleTrio {
    name = "declaredd";
    description = "declared daemon";
    withSystemDaemon = true;
    withUserDaemon = true;
    daemonWorkloadClass = "background";
    userDaemonWorkloadClass = "session-host";
  };

  evalClassHome = { isDarwin, daemon, warnLib ? lib, trio ? classTrio, ns ? "classd" }: lib.evalModules {
    modules = [
      trio.homeManagerModule
      hmStubs
      { programs.${ns} = { enable = true; package = dummyPkg; daemon = { enable = true; } // daemon; }; }
    ];
    specialArgs = { pkgs = pkgsOn isDarwin; lib = warnLib; };
  };

  evalClassSystem = { module, daemon, trio ? classTrio, ns ? "classd" }: lib.evalModules {
    modules = [
      trio.${module}
      systemStubs
      { services.${ns} = { enable = true; package = dummyPkg; daemon = { enable = true; } // daemon; }; }
    ];
    specialArgs = { inherit pkgs; };
  };

  launchdKeys = [ "ProcessType" "Nice" "LowPriorityIO" ];
  systemdKeys = [ "Nice" "CPUWeight" "IOWeight" ];
  pick = keys: lib.filterAttrs (k: _: builtins.elem k keys);

  agentConfigOf = ns: e: e.config.launchd.agents."${ns}-daemon".config;
  userServiceOf = ns: e: e.config.systemd.user.services."${ns}-daemon".Service;
  launchdDaemonOf = ns: e: e.config.launchd.daemons."${ns}-daemon".serviceConfig;
  nixosServiceOf = ns: e: e.config.systemd.services."${ns}-daemon".serviceConfig;

  agentSchedOf = class: pick launchdKeys (agentConfigOf "classd" (evalClassHome { isDarwin = true; daemon = { workloadClass = class; }; }));
  userUnitSchedOf = class: pick systemdKeys (userServiceOf "classd" (evalClassHome { isDarwin = false; daemon = { workloadClass = class; }; }));
  launchdDaemonSchedOf = class: pick launchdKeys (launchdDaemonOf "classd" (evalClassSystem { module = "darwinModule"; daemon = { workloadClass = class; }; }));
  nixosUnitSchedOf = class: pick systemdKeys (nixosServiceOf "classd" (evalClassSystem { module = "nixosModule"; daemon = { workloadClass = class; }; }));

  pinnedLaunchd = {
    session-host   = { ProcessType = "Interactive"; Nice = 0;  LowPriorityIO = false; };
    latency-server = { ProcessType = "Interactive"; Nice = 0;  LowPriorityIO = false; };
    service        = { ProcessType = "Standard";    Nice = 0;  LowPriorityIO = false; };
    background     = { ProcessType = "Background";  Nice = 10; LowPriorityIO = true; };
    xpc-adaptive   = { ProcessType = "Adaptive"; };
  };
  pinnedSystemd = {
    session-host   = { Nice = 0;  CPUWeight = 100; IOWeight = 100; };
    latency-server = { Nice = 0;  CPUWeight = 200; IOWeight = 200; };
    service        = { Nice = 0;  CPUWeight = 100; IOWeight = 100; };
    background     = { Nice = 10; CPUWeight = 20;  IOWeight = 20; };
    xpc-adaptive   = { };
  };

  silentLib = lib // { warn = _: v: v; };
  throwingLib = lib // { warn = msg: _: throw "warned: ${msg}"; };
  pinnedWarning = "io.pleme.classd.daemon: workloadClass \"session-host\" renders ProcessType \"Interactive\"; processType \"Background\" beside it is not rendered";
  onlyPinnedLib = lib // { warn = msg: v: if msg == pinnedWarning then v else throw "unexpected warning: ${msg}"; };

  tearShapedTrio = trioLib.mkModuleTrio {
    name = "hostd";
    description = "session host";
    withUserDaemon = true;
    daemonWorkloadClass = "session-host";
  };

  sessionHostBesideBackground = warnLib: evalClassHome {
    isDarwin = true;
    inherit warnLib;
    daemon = { workloadClass = "session-host"; processType = "Background"; };
  };
  rendersWithoutThrow = rendersWithoutThrowIn "classd";
  rendersWithoutThrowIn = ns: e: (builtins.tryEval (builtins.deepSeq (agentConfigOf ns e) true)).success;

  # The env the daemon unit was given, wherever mkNixOSService put it.
  daemonEnvOf = e:
    let u = unitOf e;
    in if u == null then {} else (u.environment or (u.serviceConfig.Environment or {}));

  results = lib.runTests {
    # ── ★ THE REGRESSION ───────────────────────────────────────────────
    # The whole point: a system module with withShikumiConfig must render the
    # YAML AND point the daemon at it. Before this, both were absent.
    testSystemRendersShikumiYaml = {
      expr = (etcOf withSettings) ? "testd/testd.yaml";
      expected = true;
    };

    testSystemDaemonGetsConfigEnvVar = {
      expr = (daemonEnvOf withSettings).TESTD_CONFIG or null;
      expected = "/etc/testd/testd.yaml";
    };

    # `settings` must EXIST as an option on the system arm — the missing
    # option was the user-visible face of the bug.
    testSystemExposesSettingsOption = {
      expr = builtins.hasAttr "settings" withSettings.options.services.testd;
      expected = true;
    };

    # ...and must NOT exist when the flag is off, or "conditional" is a lie
    # and every consumer grows a meaningless knob.
    testSettingsAbsentWhenFlagOff = {
      expr =
        let e = lib.evalModules {
          modules = [
            plainTrio.nixosModule
            systemStubs
            { services.plaind = { enable = true; package = dummyPkg; }; }
          ];
          specialArgs = { inherit pkgs; };
        };
        in builtins.hasAttr "settings" e.options.services.plaind;
      expected = false;
    };

    # ── Empty settings must write NOTHING ──────────────────────────────
    # A present-but-empty YAML is worse than no file: the binary would resolve
    # its `Custom` tier against a document with no keys instead of resolving
    # the prescribed tier.
    testEmptySettingsRendersNoFile = {
      expr = (etcOf withoutSettings) ? "testd/testd.yaml";
      expected = false;
    };

    testEmptySettingsSetsNoEnvVar = {
      expr = (daemonEnvOf withoutSettings) ? "TESTD_CONFIG";
      expected = false;
    };

    # ── The operator still wins ────────────────────────────────────────
    # An explicit daemon.environment entry must override the module's own
    # render — a consumer pointing the tool at a sops-rendered path must not
    # be silently overridden.
    testOperatorEnvOverridesModuleRender = {
      expr =
        let e = lib.evalModules {
          modules = [
            trio.nixosModule
            systemStubs
            { services.testd = {
                enable = true; package = dummyPkg;
                settings = { metrics.port = 9201; };
                daemon = { enable = true; environment.TESTD_CONFIG = "/run/secrets/testd.yaml"; };
              };
            }
          ];
          specialArgs = { inherit pkgs; };
        };
        in (daemonEnvOf e).TESTD_CONFIG or null;
      expected = "/run/secrets/testd.yaml";
    };

    # ── An empty daemonSubcommand yields ZERO argv entries ─────────────
    # A literal "" reaches clap on Darwin as an unexpected argument. This is
    # already documented in the macro; it was never tested.
    testEmptyDaemonSubcommandAddsNoArg = {
      expr =
        let cmd = (unitOf withSettings).serviceConfig.ExecStart or "";
        in lib.hasInfix "  " (toString cmd) || lib.hasSuffix " " (toString cmd);
      expected = false;
    };

    # ── Restart policy ─────────────────────────────────────────────────
    # A spec that names no policy renders exactly what it rendered before
    # the option existed: each service manager keeps its own default.
    testNoPolicyKeepsNixosRestartAlways = {
      expr = (unitOf withSettings).serviceConfig.Restart;
      expected = "always";
    };
    testNoPolicyKeepsLaunchdKeepAliveTrue = {
      expr = (evalSystem trio.darwinModule null).config.launchd.daemons."testd-daemon".serviceConfig.KeepAlive;
      expected = true;
    };

    # The spec's policy reaches all four renderings.
    testSpecPolicyReachesNixos = {
      expr = nixosRestartOf (evalPolicySystem policyTrio.nixosModule {});
      expected = "on-failure";
    };
    testSpecPolicyReachesLaunchdDaemon = {
      expr = launchdKeepAliveOf (evalPolicySystem policyTrio.darwinModule {});
      expected = onFailureKeepAlive;
    };
    testSpecPolicyReachesLaunchdAgent = {
      expr = agentKeepAliveOf (evalPolicyHome true {});
      expected = onFailureKeepAlive;
    };
    testSpecPolicyReachesUserUnit = {
      expr = userUnitRestartOf (evalPolicyHome false {});
      expected = "on-failure";
    };

    # The host overrides the tool's default, in both directions.
    testOperatorPolicyWinsOnNixos = {
      expr = nixosRestartOf (evalPolicySystem policyTrio.nixosModule { restartPolicy = "always"; });
      expected = "always";
    };
    testOperatorPolicyWinsOnAgent = {
      expr = agentKeepAliveOf (evalPolicyHome true { restartPolicy = "always"; });
      expected = true;
    };
    testOperatorNullRestoresServiceManagerDefault = {
      expr = nixosRestartOf (evalPolicySystem policyTrio.nixosModule { restartPolicy = null; });
      expected = "always";
    };

    # A policy outside the closed set is an eval error, not a unit with a
    # value systemd ignores.
    testUnknownPolicyIsRejected = {
      expr = (builtins.tryEval (nixosRestartOf
        (evalPolicySystem policyTrio.nixosModule { restartPolicy = "sometimes"; }))).success;
      expected = false;
    };

    # The scheduling class: unchanged by default, and settable, because a
    # daemon that runs work must not hand its children the background band
    # (cid's engenho model server, 2026-09-28).
    testUserDaemonProcessTypeDefaultsToAdaptive = {
      expr = agentProcessTypeOf (evalPolicyHome true {});
      expected = "Adaptive";
    };
    testUserDaemonProcessTypeIsSettable = {
      expr = agentProcessTypeOf (evalPolicyHome true { processType = "Interactive"; });
      expected = "Interactive";
    };
    testUnknownProcessTypeIsRejected = {
      expr = (builtins.tryEval (agentProcessTypeOf (evalPolicyHome true { processType = "Fast"; }))).success;
      expected = false;
    };

    testPinnedRowsCoverEveryClass = {
      expr = [ (builtins.attrNames pinnedLaunchd) (builtins.attrNames pinnedSystemd) ];
      expected = [ workloadClasses.classes workloadClasses.classes ];
    };
    testEveryClassRendersOnLaunchdAgent = {
      expr = lib.genAttrs workloadClasses.classes agentSchedOf;
      expected = pinnedLaunchd;
    };
    testEveryClassRendersOnUserUnit = {
      expr = lib.genAttrs workloadClasses.classes userUnitSchedOf;
      expected = pinnedSystemd;
    };
    testEveryClassRendersOnLaunchdDaemon = {
      expr = lib.genAttrs workloadClasses.classes launchdDaemonSchedOf;
      expected = pinnedLaunchd;
    };
    testEveryClassRendersOnNixosUnit = {
      expr = lib.genAttrs workloadClasses.classes nixosUnitSchedOf;
      expected = pinnedSystemd;
    };
    testUnknownClassIsRejected = {
      expr = (builtins.tryEval (agentSchedOf "realtime")).success;
      expected = false;
    };

    testNoClassRendersTodaysScheduling = {
      expr = [
        (agentSchedOf null)
        (userUnitSchedOf null)
        (launchdDaemonSchedOf null)
        (nixosUnitSchedOf null)
      ];
      expected = [ { ProcessType = "Adaptive"; } { } { ProcessType = "Adaptive"; } { } ];
    };
    testXpcAdaptiveRendersTodaysUnitsExactly = {
      expr =
        let
          both = f: map f [ {} { workloadClass = "xpc-adaptive"; } ];
          same = l: builtins.elemAt l 0 == builtins.elemAt l 1;
        in [
          (same (both (d: agentConfigOf "classd" (evalClassHome { isDarwin = true; daemon = d; }))))
          (same (both (d: userServiceOf "classd" (evalClassHome { isDarwin = false; daemon = d; }))))
          (same (both (d: launchdDaemonOf "classd" (evalClassSystem { module = "darwinModule"; daemon = d; }))))
          (same (both (d: nixosServiceOf "classd" (evalClassSystem { module = "nixosModule"; daemon = d; }))))
        ];
      expected = [ true true true true ];
    };
    testNoClassIsTheDefault = {
      expr = (evalClassHome { isDarwin = true; daemon = {}; }).config.programs.classd.daemon.workloadClass;
      expected = null;
    };

    testSpecClassReachesEveryArm = {
      expr = [
        (pick launchdKeys (agentConfigOf "declaredd" (evalClassHome { isDarwin = true; daemon = {}; trio = declaredTrio; ns = "declaredd"; })))
        (pick systemdKeys (userServiceOf "declaredd" (evalClassHome { isDarwin = false; daemon = {}; trio = declaredTrio; ns = "declaredd"; })))
        (pick launchdKeys (launchdDaemonOf "declaredd" (evalClassSystem { module = "darwinModule"; daemon = {}; trio = declaredTrio; ns = "declaredd"; })))
        (pick systemdKeys (nixosServiceOf "declaredd" (evalClassSystem { module = "nixosModule"; daemon = {}; trio = declaredTrio; ns = "declaredd"; })))
      ];
      expected = [
        { ProcessType = "Interactive"; Nice = 0; LowPriorityIO = false; }
        { Nice = 0; CPUWeight = 100; IOWeight = 100; }
        { ProcessType = "Background"; Nice = 10; LowPriorityIO = true; }
        { Nice = 10; CPUWeight = 20; IOWeight = 20; }
      ];
    };
    testUserClassDefaultsToTheDaemonClass = {
      expr = pick launchdKeys (agentConfigOf "hostd" (evalClassHome { isDarwin = true; daemon = {}; trio = tearShapedTrio; ns = "hostd"; }));
      expected = { ProcessType = "Interactive"; Nice = 0; LowPriorityIO = false; };
    };
    testOperatorClassWinsOverTheSpec = {
      expr = pick launchdKeys (agentConfigOf "hostd" (evalClassHome { isDarwin = true; daemon = { workloadClass = "xpc-adaptive"; }; trio = tearShapedTrio; ns = "hostd"; }));
      expected = { ProcessType = "Adaptive"; };
    };

    testSessionHostBesideBackgroundRendersInteractive = {
      expr = pick launchdKeys (agentConfigOf "classd" (sessionHostBesideBackground silentLib));
      expected = { ProcessType = "Interactive"; Nice = 0; LowPriorityIO = false; };
    };
    testSessionHostBesideBackgroundWarns = {
      expr = rendersWithoutThrow (sessionHostBesideBackground throwingLib);
      expected = false;
    };
    testTheWarningNamesBothValues = {
      expr = rendersWithoutThrow (sessionHostBesideBackground onlyPinnedLib);
      expected = true;
    };
    testTheWarningIsTheTablesMessage = {
      expr = workloadClasses.besideProcessType { daemon = "io.pleme.classd.daemon"; class = "session-host"; processType = "Background"; };
      expected = pinnedWarning;
    };
    testSpecProcessTypeBesideTheSpecClassWarns = {
      expr = rendersWithoutThrowIn "hostd" (evalClassHome { isDarwin = true; warnLib = throwingLib; daemon = { processType = lib.mkDefault "Interactive"; }; trio = tearShapedTrio; ns = "hostd"; });
      expected = false;
    };
    testClassAloneDoesNotWarn = {
      expr = rendersWithoutThrow (evalClassHome { isDarwin = true; warnLib = throwingLib; daemon = { workloadClass = "session-host"; }; });
      expected = true;
    };
    testProcessTypeAloneDoesNotWarnAndRenders = {
      expr =
        let e = evalClassHome { isDarwin = true; warnLib = throwingLib; daemon = { processType = "Background"; }; };
        in [ (rendersWithoutThrow e) (agentConfigOf "classd" e).ProcessType ];
      expected = [ true "Background" ];
    };
    testUserUnitBesideProcessTypeDoesNotWarn = {
      expr = (builtins.tryEval (builtins.deepSeq (userServiceOf "classd"
        (evalClassHome { isDarwin = false; warnLib = throwingLib; daemon = { workloadClass = "session-host"; processType = "Background"; }; })) true)).success;
      expected = true;
    };

    # A config change is a unit change, so the daemon restarts on it: the
    # digest is present, follows the config, is stable when it is not
    # changed, and is absent when turned off.
    testConfigDigestPresent = {
      expr = digestOf (evalDigest {} { port = 2; }) != null;
      expected = true;
    };
    testConfigDigestFollowsTheConfig = {
      expr = digestOf (evalDigest {} { port = 2; }) == digestOf (evalDigest {} { port = 3; });
      expected = false;
    };
    testConfigDigestIsStable = {
      expr = digestOf (evalDigest {} { port = 2; }) == digestOf (evalDigest {} { port = 2; });
      expected = true;
    };
    testConfigDigestOffWhenDisabled = {
      expr = digestOf (evalDigest { restartOnConfigChange = false; } { port = 2; });
      expected = null;
    };

    testAnvilCommandIsTheBareBinaryInPackageForm = {
      expr = anvilEntry.command;
      expected = "anvild";
    };
    testAnvilEntryCarriesThePackage = {
      expr = anvilEntry.package.outPath;
      expected = dummyPkg.outPath;
    };
    testAnvilResolvedPathHasOneStorePrefix = {
      expr = builtins.length (lib.splitString "/nix/store/" "${anvilEntry.package}/bin/${anvilEntry.command}");
      expected = 2;
    };

    # Every policy has a spelling on every service manager.
    testProjectionsAreTotal = {
      expr = builtins.all
        (p: (builtins.tryEval (builtins.deepSeq
          [ (restartPolicy.launchdKeepAlive p) (restartPolicy.systemdRestart p) ] true)).success)
        restartPolicy.policies;
      expected = true;
    };
  };
in
pkgs.runCommand "module-trio-test"
  {
    passthru.results = results;
  }
  (if results == [ ] then ''
    echo "module-trio: all regression tests passed"
    touch $out
  '' else ''
    echo "module-trio FAILED:"
    cat <<'EOF'
    ${builtins.toJSON results}
    EOF
    exit 1
  '')
