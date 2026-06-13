# Tests — iroha.scheduled-job (SCHEDULED/periodic system job module emitter:
# option surface + oneshot systemd.services + systemd.timers (interval/
# calendar) + minimal launchd.daemons periodic projection, persistent +
# randomizedDelay, env/user, class tagging, typed throws).
{ lib, iroha }:
let
  inherit (iroha) mkScheduledJob;

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
