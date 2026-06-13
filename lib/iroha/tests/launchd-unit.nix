# Tests — iroha.launchd-unit (pure nix-darwin launchd unit renderer:
# command|programArguments exec, startInterval|startCalendarInterval schedule,
# RunAtLoad/KeepAlive/std-paths/EnvironmentVariables, command-shortcut +
# daemonExtra passthrough, scheduleKind, typed throws).
{ lib, iroha }:
let
  inherit (iroha) mkLaunchdUnit;

  # Canonical: darwin/gitops shape — `command` shortcut + StartInterval + std
  # paths + EnvironmentVariables.
  gitops = mkLaunchdUnit {
    label = "com.pleme.gitops";
    command = ''"/run/current-system/sw/bin/darwin-rebuild" "switch"'';
    startInterval = 60;
    runAtLoad = true;
    standardOutPath = "/var/log/pleme-gitops/stdout.log";
    standardErrorPath = "/var/log/pleme-gitops/stderr.log";
    environment = {
      PATH = "/run/current-system/sw/bin:/usr/bin";
      NIX_CONFIG = "experimental-features = nix-command flakes";
    };
  };

  # programArguments form + calendar schedule + keepAlive.
  caltick = mkLaunchdUnit {
    label = "com.pleme.caltick";
    programArguments = [ "/bin/tick" "--once" ];
    startCalendarInterval = {
      Hour = 3;
      Minute = 0;
    };
    keepAlive = false;
  };

  # minimal: run-at-load only (no schedule), default runAtLoad.
  minimal = mkLaunchdUnit {
    label = "com.pleme.minimal";
    command = "/bin/run";
  };
in
{
  # ── command shortcut is daemon-level (sibling of serviceConfig) ──────
  gitops-command-is-daemon-level = {
    expr = {
      command = gitops.daemon.command;
      inServiceConfig = gitops.daemon.serviceConfig ? command;
    };
    expected = {
      command = ''"/run/current-system/sw/bin/darwin-rebuild" "switch"'';
      inServiceConfig = false;
    };
  };

  # ── serviceConfig fields land (Label / StartInterval / RunAtLoad / paths) ──
  gitops-serviceconfig = {
    expr =
      let
        sc = gitops.daemon.serviceConfig;
      in
      {
        inherit (sc) Label StartInterval RunAtLoad StandardOutPath StandardErrorPath;
      };
    expected = {
      Label = "com.pleme.gitops";
      StartInterval = 60;
      RunAtLoad = true;
      StandardOutPath = "/var/log/pleme-gitops/stdout.log";
      StandardErrorPath = "/var/log/pleme-gitops/stderr.log";
    };
  };
  gitops-environment-variables = {
    expr = gitops.daemon.serviceConfig.EnvironmentVariables;
    expected = {
      PATH = "/run/current-system/sw/bin:/usr/bin";
      NIX_CONFIG = "experimental-features = nix-command flakes";
    };
  };
  gitops-schedule-kind = {
    expr = gitops.scheduleKind;
    expected = "interval";
  };
  # command form has NO ProgramArguments.
  gitops-no-program-arguments = {
    expr = gitops.daemon.serviceConfig ? ProgramArguments;
    expected = false;
  };

  # ── programArguments form + calendar + keepAlive ─────────────────────
  caltick-program-arguments = {
    expr = caltick.daemon.serviceConfig.ProgramArguments;
    expected = [ "/bin/tick" "--once" ];
  };
  caltick-calendar-and-keepalive = {
    expr =
      let
        sc = caltick.daemon.serviceConfig;
      in
      {
        cal = sc.StartCalendarInterval;
        keepAlive = sc.KeepAlive;
        hasInterval = sc ? StartInterval;
        scheduleKind = caltick.scheduleKind;
      };
    expected = {
      cal = {
        Hour = 3;
        Minute = 0;
      };
      keepAlive = false;
      hasInterval = false;
      scheduleKind = "calendar";
    };
  };
  # command form has no top-level command on caltick (it used programArguments).
  caltick-no-command-shortcut = {
    expr = caltick.daemon ? command;
    expected = false;
  };

  # ── minimal: run-at-load default, no schedule, no optional keys ──────
  minimal-defaults = {
    expr =
      let
        sc = minimal.daemon.serviceConfig;
      in
      {
        runAtLoad = sc.RunAtLoad;
        scheduleKind = minimal.scheduleKind;
        hasKeepAlive = sc ? KeepAlive;
        hasStdOut = sc ? StandardOutPath;
        hasEnv = sc ? EnvironmentVariables;
      };
    expected = {
      runAtLoad = true;
      scheduleKind = "none";
      hasKeepAlive = false;
      hasStdOut = false;
      hasEnv = false;
    };
  };

  # ── serviceConfigExtra + daemonExtra passthrough (win last) ──────────
  extras-passthrough = {
    expr =
      let
        u = mkLaunchdUnit {
          label = "com.pleme.x";
          command = "/bin/x";
          serviceConfigExtra = { ProcessType = "Background"; };
          daemonExtra = { managedBy = "pleme"; };
        };
      in
      {
        processType = u.daemon.serviceConfig.ProcessType;
        managedBy = u.daemon.managedBy;
      };
    expected = {
      processType = "Background";
      managedBy = "pleme";
    };
  };

  # ── serviceConfig export = the bare plist (HM launchd.agents.config) ─
  bare-serviceconfig-for-hm-agent = {
    # the top-level serviceConfig is the daemon's serviceConfig, unwrapped —
    # what an HM launchd agent's `config` consumes directly.
    expr = caltick.serviceConfig == caltick.daemon.serviceConfig;
    expected = true;
  };
  bare-serviceconfig-has-program-arguments = {
    expr = caltick.serviceConfig.ProgramArguments;
    expected = [ "/bin/tick" "--once" ];
  };

  # ── typed throws (lazy — force the field that throws) ────────────────
  missing-label-throws = {
    expr = (builtins.tryEval (mkLaunchdUnit { command = "/x"; }).daemon.serviceConfig.Label).success;
    expected = false;
  };
  missing-exec-throws = {
    expr = (builtins.tryEval (mkLaunchdUnit { label = "l"; }).daemon).success;
    expected = false;
  };
  both-exec-forms-throws = {
    expr =
      (builtins.tryEval
        (mkLaunchdUnit {
          label = "l";
          command = "/a";
          programArguments = [ "/b" ];
        }).daemon
      ).success;
    expected = false;
  };
  both-schedules-throws = {
    expr =
      (builtins.tryEval
        (mkLaunchdUnit {
          label = "l";
          command = "/x";
          startInterval = 60;
          startCalendarInterval = { Hour = 3; };
        }).daemon
      ).success;
    expected = false;
  };
  non-int-interval-throws = {
    expr =
      (builtins.tryEval
        (mkLaunchdUnit {
          label = "l";
          command = "/x";
          startInterval = "60";
        }).daemon
      ).success;
    expected = false;
  };
}
