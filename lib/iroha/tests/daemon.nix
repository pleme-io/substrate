# Tests — iroha.daemon (one spec, four platform projections).
{ lib, iroha }:
let
  inherit (iroha) mkDaemonUnit;

  # Keep-alive daemon, all defaults.
  daemon = mkDaemonUnit {
    name = "tend";
    command = "/nix/store/x/bin/tend";
  };

  # Exit-tolerated service.
  relaxed = mkDaemonUnit {
    name = "tend";
    command = "/nix/store/x/bin/tend";
    keepAlive = false;
  };

  # Args with spaces — ExecStart must be systemd-escaped (toJSON quoting),
  # NOT shell-escaped: systemd's unit parser is not sh.
  spaced = mkDaemonUnit {
    name = "echoer";
    command = "/bin/echo";
    args = [
      "hello world"
      "--flag"
    ];
  };

  # Args carrying % and $ — systemd expands `%` specifiers and `$VAR`
  # substitutions in Exec lines BEFORE word splitting; quoting does not
  # protect them. They must be doubled (%% / $$) per nixpkgs
  # escapeSystemdExecArg semantics.
  specifiers = mkDaemonUnit {
    name = "fetcher";
    command = "/bin/tool";
    args = [
      "https://api.example.com/a%20b"
      "--fmt"
      "%Y-%m-%d"
      "--pass"
      "p$wd"
    ];
  };

  withExtras = mkDaemonUnit {
    name = "k3s";
    command = "/bin/k3s";
    args = [ "server" ];
    systemdExtra = {
      Type = "notify";
      Delegate = "yes";
      KillMode = "process";
      RestartSec = 5;
    };
    systemdUserExtra.RestartSec = 5;
    launchdExtra = {
      UserName = "root";
      ProcessType = "Adaptive";
    };
  };

  orderedUser = mkDaemonUnit {
    name = "late";
    command = "/bin/late";
    after = [ "graphical-session.target" ];
  };

  withEnv = mkDaemonUnit {
    name = "envy";
    command = "/bin/envy";
    env = {
      ZOEKT_URL = "http://localhost:6070";
      CACHE = "/tmp/c";
    };
  };

  periodic = mkDaemonUnit {
    name = "sweeper";
    command = "/bin/sweep";
    schedule.interval = 300;
  };

  bareCal = mkDaemonUnit {
    name = "nightly";
    command = "/bin/nightly";
    schedule.calendar = {
      Hour = 3;
      Minute = 0;
    };
  };

  dualCal = mkDaemonUnit {
    name = "nightly";
    command = "/bin/nightly";
    schedule.calendar = {
      launchd = {
        Hour = 3;
        Minute = 0;
      };
      systemd = "*-*-* 03:00:00";
    };
  };

  logged = mkDaemonUnit {
    name = "tend";
    command = "/bin/tend";
    logDir = "/var/log/pleme";
  };

  housed = mkDaemonUnit {
    name = "tend";
    command = "/bin/tend";
    workingDir = "/srv/tend";
  };
in
{
  # ── keep-alive daemon mode ──────────────────────────────────────────
  keepalive-systemd-restart-always-and-wantedby = {
    expr = {
      restart = daemon.systemd.serviceConfig.Restart;
      wantedBy = daemon.systemd.wantedBy;
    };
    expected = {
      restart = "always";
      wantedBy = [ "multi-user.target" ];
    };
  };
  keepalive-launchd-keepalive-and-runatload-true = {
    expr = {
      inherit (daemon.launchdDaemon.serviceConfig) KeepAlive RunAtLoad;
    };
    expected = {
      KeepAlive = true;
      RunAtLoad = true;
    };
  };
  keepalive-timers-null = {
    expr = daemon.systemdTimer == null && daemon.systemdUserTimer == null;
    expected = true;
  };
  keepalive-false-restart-on-failure = {
    expr = {
      system = relaxed.systemd.serviceConfig.Restart;
      user = relaxed.systemdUser.Service.Restart;
    };
    expected = {
      system = "on-failure";
      user = "on-failure";
    };
  };
  keepalive-false-launchd-false = {
    expr = relaxed.launchdDaemon.serviceConfig.KeepAlive;
    expected = false;
  };

  # ── ExecStart / ProgramArguments ────────────────────────────────────
  execstart-systemd-escapes-args-with-spaces = {
    expr = spaced.systemd.serviceConfig.ExecStart;
    expected = ''"/bin/echo" "hello world" "--flag"'';
  };
  execstart-doubles-percent-and-dollar = {
    expr = specifiers.systemd.serviceConfig.ExecStart;
    expected = ''"/bin/tool" "https://api.example.com/a%%20b" "--fmt" "%%Y-%%m-%%d" "--pass" "p$$wd"'';
  };
  execstart-identical-in-user-unit = {
    expr = spaced.systemdUser.Service.ExecStart == spaced.systemd.serviceConfig.ExecStart;
    expected = true;
  };
  execstart-rejects-non-stringlike-args = {
    expr =
      (builtins.tryEval
        (mkDaemonUnit {
          name = "bad";
          command = "/bin/x";
          args = [ { bad = true; } ];
        }).systemd.serviceConfig.ExecStart
      ).success;
    expected = false;
  };
  launchd-programarguments-stay-a-list = {
    expr = spaced.launchdDaemon.serviceConfig.ProgramArguments;
    expected = [
      "/bin/echo"
      "hello world"
      "--flag"
    ];
  };

  # ── env in all four shapes ──────────────────────────────────────────
  env-systemd-attrs = {
    expr = withEnv.systemd.environment;
    expected = {
      CACHE = "/tmp/c";
      ZOEKT_URL = "http://localhost:6070";
    };
  };
  env-systemd-user-kv-list = {
    expr = withEnv.systemdUser.Service.Environment;
    expected = [
      "CACHE=/tmp/c"
      "ZOEKT_URL=http://localhost:6070"
    ];
  };
  env-launchd-environmentvariables = {
    expr = withEnv.launchdDaemon.serviceConfig.EnvironmentVariables;
    expected = {
      CACHE = "/tmp/c";
      ZOEKT_URL = "http://localhost:6070";
    };
  };
  env-empty-omitted-everywhere = {
    expr =
      !(daemon.systemd ? environment)
      && !(daemon.systemdUser.Service ? Environment)
      && !(daemon.launchdDaemon.serviceConfig ? EnvironmentVariables);
    expected = true;
  };
  launchd-agent-mirrors-daemon-config = {
    expr = withEnv.launchdAgent == {
      enable = true;
      config = withEnv.launchdDaemon.serviceConfig;
    };
    expected = true;
  };

  # ── periodic: interval ──────────────────────────────────────────────
  interval-launchd-startinterval-no-keepalive = {
    expr = {
      inherit (periodic.launchdDaemon.serviceConfig) StartInterval KeepAlive RunAtLoad;
    };
    expected = {
      StartInterval = 300;
      KeepAlive = false;
      RunAtLoad = false;
    };
  };
  interval-systemd-oneshot-no-restart-no-wantedby = {
    expr =
      periodic.systemd.serviceConfig.Type == "oneshot"
      && !(periodic.systemd.serviceConfig ? Restart)
      && !(periodic.systemd ? wantedBy);
    expected = true;
  };
  interval-systemd-timer = {
    expr = periodic.systemdTimer;
    expected = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "300s";
        OnUnitActiveSec = "300s";
      };
    };
  };
  interval-user-timer-install-and-onactive = {
    expr = {
      wantedBy = periodic.systemdUserTimer.Install.WantedBy;
      onActive = periodic.systemdUserTimer.Timer.OnUnitActiveSec;
    };
    expected = {
      wantedBy = [ "timers.target" ];
      onActive = "300s";
    };
  };
  interval-user-service-oneshot-no-install = {
    expr =
      periodic.systemdUser.Service.Type == "oneshot"
      && !(periodic.systemdUser ? Install)
      && !(periodic.systemdUser.Service ? Restart);
    expected = true;
  };

  # ── periodic: calendar (bare vs dual) ───────────────────────────────
  calendar-bare-launchd-verbatim = {
    expr = bareCal.launchdDaemon.serviceConfig.StartCalendarInterval;
    expected = {
      Hour = 3;
      Minute = 0;
    };
  };
  calendar-bare-systemd-timers-throw = {
    expr =
      (builtins.tryEval bareCal.systemdTimer).success
      || (builtins.tryEval bareCal.systemdUserTimer).success;
    expected = false;
  };
  calendar-dual-oncalendar-string = {
    expr = {
      system = dualCal.systemdTimer.timerConfig.OnCalendar;
      user = dualCal.systemdUserTimer.Timer.OnCalendar;
    };
    expected = {
      system = "*-*-* 03:00:00";
      user = "*-*-* 03:00:00";
    };
  };
  calendar-dual-launchd-attrs = {
    expr = dualCal.launchdDaemon.serviceConfig.StartCalendarInterval;
    expected = {
      Hour = 3;
      Minute = 0;
    };
  };

  # ── logDir / workingDir ─────────────────────────────────────────────
  logdir-sets-both-launchd-paths = {
    expr = {
      out = logged.launchdDaemon.serviceConfig.StandardOutPath;
      err = logged.launchdAgent.config.StandardErrorPath;
    };
    expected = {
      out = "/var/log/pleme/tend.log";
      err = "/var/log/pleme/tend.err";
    };
  };
  logdir-null-omits-launchd-paths = {
    expr = !(daemon.launchdDaemon.serviceConfig ? StandardOutPath);
    expected = true;
  };
  workingdir-lands-in-all-four = {
    expr = {
      system = housed.systemd.serviceConfig.WorkingDirectory;
      user = housed.systemdUser.Service.WorkingDirectory;
      ldDaemon = housed.launchdDaemon.serviceConfig.WorkingDirectory;
      ldAgent = housed.launchdAgent.config.WorkingDirectory;
    };
    expected = {
      system = "/srv/tend";
      user = "/srv/tend";
      ldDaemon = "/srv/tend";
      ldAgent = "/srv/tend";
    };
  };

  # ── defaults + meta ─────────────────────────────────────────────────
  description-defaults-to-name = {
    expr = {
      system = daemon.systemd.description;
      user = daemon.systemdUser.Unit.Description;
    };
    expected = {
      system = "tend";
      user = "tend";
    };
  };
  after-defaults-to-network-target-system-only = {
    # The default ordering applies to the SYSTEM unit only; the user
    # instance has no network.target, so the default there would be a
    # silently-inert dependency — emitted only when the caller passes
    # `after` explicitly.
    expr = {
      system = daemon.systemd.after;
      userHasAfter = daemon.systemdUser.Unit ? After;
    };
    expected = {
      system = [ "network.target" ];
      userHasAfter = false;
    };
  };
  after-explicit-flows-to-user-unit = {
    expr = orderedUser.systemdUser.Unit.After;
    expected = [ "graphical-session.target" ];
  };

  # ── typed escape hatches (power fields) ─────────────────────────────
  systemd-extra-merges-power-fields = {
    expr = {
      inherit (withExtras.systemd.serviceConfig)
        Type
        Delegate
        KillMode
        RestartSec
        Restart
        ;
    };
    expected = {
      Type = "notify";
      Delegate = "yes";
      KillMode = "process";
      RestartSec = 5;
      Restart = "always";
    };
  };
  systemd-user-extra-merges = {
    expr = withExtras.systemdUser.Service.RestartSec;
    expected = 5;
  };
  launchd-extra-merges = {
    expr = {
      inherit (withExtras.launchdDaemon.serviceConfig) UserName ProcessType;
    };
    expected = {
      UserName = "root";
      ProcessType = "Adaptive";
    };
  };
  meta-kind-daemon = {
    expr = daemon.meta;
    expected = {
      name = "tend";
      kind = "daemon";
    };
  };
  meta-kind-periodic = {
    expr = periodic.meta.kind;
    expected = "periodic";
  };

  # ── typed throws (lazy — force the field that throws) ──────────────
  missing-name-throws = {
    expr = (builtins.tryEval (mkDaemonUnit { command = "/x"; }).meta.name).success;
    expected = false;
  };
  missing-command-throws = {
    expr =
      (builtins.tryEval
        (mkDaemonUnit { name = "x"; }).systemd.serviceConfig.ExecStart
      ).success;
    expected = false;
  };
  schedule-empty-attrs-throws = {
    expr =
      (builtins.tryEval
        (mkDaemonUnit {
          name = "x";
          command = "/x";
          schedule = { };
        }).meta.kind
      ).success;
    expected = false;
  };
  schedule-non-int-interval-throws = {
    expr =
      (builtins.tryEval
        (mkDaemonUnit {
          name = "x";
          command = "/x";
          schedule.interval = "300";
        }).meta.kind
      ).success;
    expected = false;
  };
  schedule-both-interval-and-calendar-throws = {
    expr =
      (builtins.tryEval
        (mkDaemonUnit {
          name = "x";
          command = "/x";
          schedule = {
            interval = 60;
            calendar = {
              Hour = 1;
            };
          };
        }).meta.kind
      ).success;
    expected = false;
  };
}
