# Tests — iroha.scheduled-job (SCHEDULED/periodic system job module emitter:
# option surface + oneshot systemd.services + systemd.timers (interval/
# calendar) + minimal launchd.daemons periodic projection, persistent +
# randomizedDelay, env/user, class tagging, typed throws).
{ lib, iroha }:
let
  inherit (iroha) mkScheduledJob mkScheduledUnit;

  # ── mkScheduledUnit (the PURE systemd-unit renderer) ──────────────────
  # A bespoke module reaches for this INSIDE its config block: it owns the
  # option surface + reads cfg, and farms only the systemd service+timer
  # SHAPE. Modelled on attic-store-push: Type override via serviceConfigExtra,
  # service-level passthrough (path / restartIfChanged) via serviceExtra,
  # calendar string + non-persistent timer.
  atticUnit = mkScheduledUnit {
    description = "Push full Nix store to Attic binary cache";
    execStart = "/nix/store/x/bin/seibi attic-push --token-file /run/t --best-effort --json";
    schedule.calendar = "*-*-* 04:00:00";
    after = [ "network-online.target" "nix-maintenance.service" "atticd.service" ];
    wants = [ "network-online.target" "atticd.service" ];
    persistent = false;
    randomizedDelaySec = "30m";
    serviceConfigExtra = {
      Type = "simple";
      SyslogIdentifier = "attic-store-push";
      RuntimeMaxSec = "3h";
    };
    serviceExtra = {
      restartIfChanged = false;
      path = [ "ATTIC_CLIENT_DRV" "NIX_DRV" ];
    };
  };

  # interval form via the pure renderer (command + args escaped).
  intervalUnit = mkScheduledUnit {
    description = "interval unit";
    command = "/bin/tend";
    args = [ "fetch" "--all" ];
    schedule.interval = 300;
  };

  # ── stub option universes ────────────────────────────────────────────
  nixosUniverse =
    { lib, ... }:
    {
      options = {
        systemd.services = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        systemd.timers = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
      };
    };
  darwinUniverse =
    { lib, ... }:
    {
      options = {
        launchd.daemons = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
      };
    };

  evalNixos =
    modules:
    lib.evalModules {
      class = "nixos";
      modules = [
        nixosUniverse
        { _module.args.pkgs = { }; }
      ]
      ++ modules;
    };
  evalDarwin =
    modules:
    lib.evalModules {
      class = "darwin";
      modules = [
        darwinUniverse
        { _module.args.pkgs = { }; }
      ]
      ++ modules;
    };

  # ── specs under test ─────────────────────────────────────────────────
  # interval form, command + args, env + user/group.
  fetch = mkScheduledJob {
    name = "fleet-fetch";
    description = "nightly fleet fetch";
    command = "/nix/store/x/bin/tend";
    args = [ "fetch" "--all" ];
    schedule.interval = 300;
    environment = {
      ZOEKT_URL = "http://localhost:6070";
    };
    user = "tend";
    group = "tend";
    environmentFile = "/run/secrets/tend.env";
  };

  # calendar form, command, dual systemd/launchd.
  nightly = mkScheduledJob {
    name = "flake-update";
    description = "nightly flake update";
    command = "/bin/flake-update";
    schedule.calendar = {
      systemd = "*-*-* 03:00:00";
      launchd = {
        Hour = 3;
        Minute = 0;
      };
    };
  };

  # execStart verbatim, all defaults, non-persistent + jitter.
  warmer = mkScheduledJob {
    name = "cache-warmer";
    description = "cache warmer";
    execStart = "/bin/warm cache";
    schedule.interval = 3600;
    persistent = false;
    randomizedDelaySec = 120;
  };

  # command form with spaces — ExecStart must be systemd-escaped.
  spaced = mkScheduledJob {
    name = "spaced";
    description = "spaced";
    command = "/bin/echo";
    args = [ "hello world" "--flag" ];
    schedule.interval = 60;
  };

  # extra typed options + custom namespace.
  tuned = mkScheduledJob {
    name = "nic-tune";
    description = "rio NIC tune";
    namespace = "blackmatter.scheduled";
    extraOptions = l: {
      iface = l.mkOption {
        type = l.types.str;
        default = "eth0";
      };
    };
    command = "/bin/nic-tune";
    schedule.calendar = {
      systemd = "*-*-* *:00/15:00";
      launchd = {
        Minute = 0;
      };
    };
  };
in
{
  # ── interval: oneshot service + timer OnUnitActiveSec ────────────────
  interval-service-oneshot-and-execstart = {
    expr =
      let
        sc = (evalNixos [ fetch.nixos { services.fleet-fetch.enable = true; } ]).config.systemd.services.fleet-fetch.serviceConfig;
      in
      {
        inherit (sc) Type ExecStart;
      };
    expected = {
      Type = "oneshot";
      ExecStart = ''"/nix/store/x/bin/tend" "fetch" "--all"'';
    };
  };
  interval-timer-onunitactivesec-and-persistent = {
    expr =
      let
        t = (evalNixos [ fetch.nixos { services.fleet-fetch.enable = true; } ]).config.systemd.timers.fleet-fetch;
      in
      {
        wantedBy = t.wantedBy;
        onBoot = t.timerConfig.OnBootSec;
        onActive = t.timerConfig.OnUnitActiveSec;
        persistent = t.timerConfig.Persistent;
      };
    expected = {
      wantedBy = [ "timers.target" ];
      onBoot = "300s";
      onActive = "300s";
      persistent = true;
    };
  };

  # ── service power fields: env / user / group / environmentFile ───────
  interval-service-env-user-group = {
    expr =
      let
        s = (evalNixos [ fetch.nixos { services.fleet-fetch.enable = true; } ]).config.systemd.services.fleet-fetch;
      in
      {
        env = s.environment;
        user = s.serviceConfig.User;
        group = s.serviceConfig.Group;
        envFile = s.serviceConfig.EnvironmentFile;
      };
    expected = {
      env = {
        ZOEKT_URL = "http://localhost:6070";
      };
      user = "tend";
      group = "tend";
      envFile = "/run/secrets/tend.env";
    };
  };

  # ── calendar: timer OnCalendar string + no interval keys ─────────────
  calendar-timer-oncalendar-string = {
    expr =
      let
        t = (evalNixos [ nightly.nixos { services.flake-update.enable = true; } ]).config.systemd.timers.flake-update;
      in
      {
        onCalendar = t.timerConfig.OnCalendar;
        hasOnActive = t.timerConfig ? OnUnitActiveSec;
        persistent = t.timerConfig.Persistent;
      };
    expected = {
      onCalendar = "*-*-* 03:00:00";
      hasOnActive = false;
      persistent = true;
    };
  };

  # ── persistent=false + randomizedDelay reflected in timer ────────────
  persistent-false-and-randomized-delay = {
    expr =
      let
        t = (evalNixos [ warmer.nixos { services.cache-warmer.enable = true; } ]).config.systemd.timers.cache-warmer;
      in
      {
        persistent = t.timerConfig.Persistent;
        delay = t.timerConfig.RandomizedDelaySec;
      };
    expected = {
      persistent = false;
      delay = 120;
    };
  };
  randomized-delay-absent-by-default = {
    expr = (evalNixos [ fetch.nixos { services.fleet-fetch.enable = true; } ]).config.systemd.timers.fleet-fetch.timerConfig ? RandomizedDelaySec;
    expected = false;
  };

  # ── disabled: neither service nor timer emitted ──────────────────────
  disabled-emits-nothing = {
    expr =
      let
        c = (evalNixos [ fetch.nixos ]).config;
      in
      {
        services = c.systemd.services;
        timers = c.systemd.timers;
      };
    expected = {
      services = { };
      timers = { };
    };
  };

  # ── execStart verbatim vs escaped command form ───────────────────────
  execstart-verbatim-when-given = {
    expr = (evalNixos [ warmer.nixos { services.cache-warmer.enable = true; } ]).config.systemd.services.cache-warmer.serviceConfig.ExecStart;
    expected = "/bin/warm cache";
  };
  command-form-systemd-escapes-spaces = {
    expr = (evalNixos [ spaced.nixos { services.spaced.enable = true; } ]).config.systemd.services.spaced.serviceConfig.ExecStart;
    expected = ''"/bin/echo" "hello world" "--flag"'';
  };

  # ── extraOptions land + are settable ─────────────────────────────────
  extra-options-default-and-settable = {
    expr = {
      dflt = (evalNixos [ tuned.nixos { blackmatter.scheduled.nic-tune.enable = true; } ]).config.blackmatter.scheduled.nic-tune.iface;
      set = (evalNixos [
        tuned.nixos
        {
          blackmatter.scheduled.nic-tune.enable = true;
          blackmatter.scheduled.nic-tune.iface = "eth1";
        }
      ]).config.blackmatter.scheduled.nic-tune.iface;
    };
    expected = {
      dflt = "eth0";
      set = "eth1";
    };
  };

  # ── darwin projection: StartInterval + RunAtLoad/KeepAlive false ─────
  darwin-startinterval-runatload-keepalive = {
    expr =
      let
        sc = (evalDarwin [ fetch.darwin { services.fleet-fetch.enable = true; } ]).config.launchd.daemons.fleet-fetch.serviceConfig;
      in
      {
        prog = sc.ProgramArguments;
        interval = sc.StartInterval;
        runAtLoad = sc.RunAtLoad;
        keepAlive = sc.KeepAlive;
        env = sc.EnvironmentVariables;
      };
    expected = {
      prog = [
        "/nix/store/x/bin/tend"
        "fetch"
        "--all"
      ];
      interval = 300;
      runAtLoad = false;
      keepAlive = false;
      env = {
        ZOEKT_URL = "http://localhost:6070";
      };
    };
  };
  darwin-startcalendarinterval-verbatim = {
    expr =
      let
        sc = (evalDarwin [ nightly.darwin { services.flake-update.enable = true; } ]).config.launchd.daemons.flake-update.serviceConfig;
      in
      {
        cal = sc.StartCalendarInterval;
        hasInterval = sc ? StartInterval;
      };
    expected = {
      cal = {
        Hour = 3;
        Minute = 0;
      };
      hasInterval = false;
    };
  };
  darwin-shell-wrap-for-execstart = {
    expr = (evalDarwin [ warmer.darwin { services.cache-warmer.enable = true; } ]).config.launchd.daemons.cache-warmer.serviceConfig.ProgramArguments;
    expected = [
      "/bin/sh"
      "-c"
      "/bin/warm cache"
    ];
  };
  darwin-disabled-emits-nothing = {
    expr = (evalDarwin [ fetch.darwin ]).config.launchd.daemons;
    expected = { };
  };

  # ── meta ─────────────────────────────────────────────────────────────
  meta-interval = {
    expr = fetch.meta;
    expected = {
      name = "fleet-fetch";
      kind = "scheduled-job";
      scheduleKind = "interval";
      optionPath = [
        "services"
        "fleet-fetch"
      ];
      enablePath = [
        "services"
        "fleet-fetch"
        "enable"
      ];
    };
  };
  meta-scheduleKind-calendar = {
    expr = tuned.meta.scheduleKind;
    expected = "calendar";
  };

  # ── mkScheduledUnit: Type override + service-level passthrough ─────────
  unit-type-override-via-serviceconfigextra = {
    # serviceConfigExtra wins last over the oneshot default — the attic
    # Type=simple wedge fix is expressible by construction.
    expr = atticUnit.service.serviceConfig.Type;
    expected = "simple";
  };
  unit-serviceconfigextra-fields-land = {
    expr = {
      inherit (atticUnit.service.serviceConfig) SyslogIdentifier RuntimeMaxSec;
      execStart = atticUnit.service.serviceConfig.ExecStart;
    };
    expected = {
      SyslogIdentifier = "attic-store-push";
      RuntimeMaxSec = "3h";
      execStart = "/nix/store/x/bin/seibi attic-push --token-file /run/t --best-effort --json";
    };
  };
  unit-serviceextra-is-service-level-not-serviceconfig = {
    # path + restartIfChanged sit at the SERVICE level (siblings of
    # serviceConfig), never inside it.
    expr = {
      restartIfChanged = atticUnit.service.restartIfChanged;
      path = atticUnit.service.path;
      pathLeakedIntoServiceConfig = atticUnit.service.serviceConfig ? path;
    };
    expected = {
      restartIfChanged = false;
      path = [ "ATTIC_CLIENT_DRV" "NIX_DRV" ];
      pathLeakedIntoServiceConfig = false;
    };
  };
  unit-service-deps-and-description = {
    expr = {
      inherit (atticUnit.service) description after wants;
    };
    expected = {
      description = "Push full Nix store to Attic binary cache";
      after = [ "network-online.target" "nix-maintenance.service" "atticd.service" ];
      wants = [ "network-online.target" "atticd.service" ];
    };
  };
  unit-timer-calendar-nonpersistent-jitter = {
    expr = {
      inherit (atticUnit.timer) wantedBy;
      onCalendar = atticUnit.timer.timerConfig.OnCalendar;
      persistent = atticUnit.timer.timerConfig.Persistent;
      delay = atticUnit.timer.timerConfig.RandomizedDelaySec;
      hasOnActive = atticUnit.timer.timerConfig ? OnUnitActiveSec;
    };
    expected = {
      wantedBy = [ "timers.target" ];
      onCalendar = "*-*-* 04:00:00";
      persistent = false;
      delay = "30m";
      hasOnActive = false;
    };
  };
  unit-scheduleKind-calendar = {
    expr = atticUnit.scheduleKind;
    expected = "calendar";
  };
  unit-interval-onunitactivesec-and-escaped-exec = {
    expr = {
      onActive = intervalUnit.timer.timerConfig.OnUnitActiveSec;
      onBoot = intervalUnit.timer.timerConfig.OnBootSec;
      execStart = intervalUnit.service.serviceConfig.ExecStart;
      type = intervalUnit.service.serviceConfig.Type;
      scheduleKind = intervalUnit.scheduleKind;
      programArguments = intervalUnit.programArguments;
    };
    expected = {
      onActive = "300s";
      onBoot = "300s";
      execStart = ''"/bin/tend" "fetch" "--all"'';
      type = "oneshot";
      scheduleKind = "interval";
      programArguments = [ "/bin/tend" "fetch" "--all" ];
    };
  };
  unit-serviceextra-absent-by-default-leaves-bare-service = {
    expr = {
      hasRestartIfChanged = intervalUnit.service ? restartIfChanged;
      hasPath = intervalUnit.service ? path;
    };
    expected = {
      hasRestartIfChanged = false;
      hasPath = false;
    };
  };

  # ── mkScheduledJob: serviceExtra passthrough reaches the emitted unit ──
  job-serviceextra-reaches-systemd-service = {
    expr =
      let
        j = mkScheduledJob {
          name = "with-extra";
          description = "with extra";
          command = "/bin/x";
          schedule.interval = 60;
          serviceExtra = {
            restartIfChanged = false;
            path = [ "P" ];
          };
        };
        s = (evalNixos [ j.nixos { services.with-extra.enable = true; } ]).config.systemd.services.with-extra;
      in
      {
        restartIfChanged = s.restartIfChanged;
        path = s.path;
      };
    expected = {
      restartIfChanged = false;
      path = [ "P" ];
    };
  };

  # ── mkScheduledUnit typed throws ──────────────────────────────────────
  unit-missing-description-throws = {
    expr =
      (builtins.tryEval (mkScheduledUnit {
        execStart = "/x";
        schedule.interval = 60;
      }).service.description).success;
    expected = false;
  };
  unit-missing-schedule-throws = {
    expr =
      (builtins.tryEval (mkScheduledUnit {
        description = "d";
        execStart = "/x";
      }).timer.timerConfig).success;
    expected = false;
  };
  unit-calendar-must-be-string-throws = {
    expr =
      (builtins.tryEval (mkScheduledUnit {
        description = "d";
        execStart = "/x";
        schedule.calendar = {
          systemd = "*-*-* 03:00:00";
        };
      }).timer.timerConfig.OnCalendar).success;
    expected = false;
  };
}
# ── class tagging: the nixos module is rejected under a darwin eval ──
// iroha.mkModuleEvalCheck {
  name = "scheduled-nixos-module-under-darwin-class";
  modules = [ fetch.nixos ];
  class = "darwin";
  universe = [
    (
      { lib, ... }:
      {
        options.systemd.services = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        options.systemd.timers = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        config._module.args.pkgs = { };
      }
    )
  ];
  expectClassReject = true;
}
// {
  # ── typed throws (lazy — force the field that throws) ───────────────
  missing-name-throws = {
    expr =
      (builtins.tryEval
        (mkScheduledJob {
          description = "d";
          command = "/x";
          schedule.interval = 60;
        }).meta.name
      ).success;
    expected = false;
  };
  missing-description-throws = {
    expr =
      (builtins.tryEval
        (lib.getAttrFromPath [ "options" "services" "x" "enable" "description" ] (evalNixos [
          (mkScheduledJob {
            name = "x";
            command = "/x";
            schedule.interval = 60;
          }).nixos
        ]))
      ).success;
    expected = false;
  };
  missing-exec-throws = {
    expr =
      (builtins.tryEval
        (evalNixos [
          (mkScheduledJob {
            name = "x";
            description = "d";
            schedule.interval = 60;
          }).nixos
          { services.x.enable = true; }
        ]).config.systemd.services.x.serviceConfig.ExecStart
      ).success;
    expected = false;
  };
  both-exec-and-command-throws = {
    expr =
      (builtins.tryEval
        (evalNixos [
          (mkScheduledJob {
            name = "x";
            description = "d";
            execStart = "/a";
            command = "/b";
            schedule.interval = 60;
          }).nixos
          { services.x.enable = true; }
        ]).config.systemd.services.x.serviceConfig.ExecStart
      ).success;
    expected = false;
  };
  missing-schedule-throws = {
    expr =
      (builtins.tryEval
        (mkScheduledJob {
          name = "x";
          description = "d";
          command = "/x";
        }).meta.scheduleKind
      ).success;
    expected = false;
  };
  schedule-both-interval-and-calendar-throws = {
    expr =
      (builtins.tryEval
        (mkScheduledJob {
          name = "x";
          description = "d";
          command = "/x";
          schedule = {
            interval = 60;
            calendar = {
              systemd = "*-*-* 03:00:00";
              launchd = {
                Hour = 3;
              };
            };
          };
        }).meta.scheduleKind
      ).success;
    expected = false;
  };
  schedule-non-int-interval-throws = {
    expr =
      (builtins.tryEval
        (mkScheduledJob {
          name = "x";
          description = "d";
          command = "/x";
          schedule.interval = "300";
        }).meta.scheduleKind
      ).success;
    expected = false;
  };
  schedule-calendar-missing-half-throws = {
    expr =
      (builtins.tryEval
        (mkScheduledJob {
          name = "x";
          description = "d";
          command = "/x";
          schedule.calendar = {
            launchd = {
              Hour = 3;
            };
          };
        }).meta.scheduleKind
      ).success;
    expected = false;
  };
}
