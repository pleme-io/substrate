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
