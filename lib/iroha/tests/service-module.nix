# Tests — iroha.service-module (full SYSTEM-class service module emitter:
# option surface + complete systemd.services + minimal launchd.daemons,
# the system power fields daemon.nix excludes, class tagging, typed throws).
{ lib, iroha }:
let
  inherit (iroha) mkServiceModule;

  # ── stub NixOS option universe ───────────────────────────────────────
  nixosUniverse =
    { lib, ... }:
    {
      options = {
        systemd.services = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        # option-root landing pad for the emitted enable + extras (the
        # emitted module declares these via mkOptionSurface, so they need
        # no stub — but services.* must exist for arbitrary extraOptions
        # paths; everything the module touches it declares itself).
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

  enable = { services.tend.enable = true; };

  # ── specs under test ─────────────────────────────────────────────────
  # Canonical: command + args form, full set of system power fields.
  svc = mkServiceModule {
    name = "tend";
    description = "tend repo daemon";
    service = {
      command = "/nix/store/x/bin/tend";
      args = [ "daemon" ];
      type = "notify";
      environment = {
        ZOEKT_URL = "http://localhost:6070";
      };
      environmentFile = "/run/secrets/tend.env";
      stateDirectory = "tend";
      runtimeDirectory = "tend";
      workingDirectory = "/srv/tend";
      user = "tend";
      group = "tend";
      restartSec = 5;
      hardening = {
        ProtectSystem = "strict";
        NoNewPrivileges = true;
      };
      serviceConfigExtra = {
        LimitNOFILE = 65536;
      };
    };
  };

  # Minimal: execStart verbatim, all defaults.
  bare = mkServiceModule {
    name = "echoer";
    description = "echoer";
    service.execStart = "/bin/echo hi";
  };

  # command form with spaces — ExecStart must be systemd-escaped.
  spaced = mkServiceModule {
    name = "echoer";
    description = "echoer";
    service = {
      command = "/bin/echo";
      args = [
        "hello world"
        "--flag"
      ];
    };
  };

  # oneshot + remainAfterExit.
  oneshot = mkServiceModule {
    name = "migrate";
    description = "migrate";
    service = {
      command = "/bin/migrate";
      type = "oneshot";
      remainAfterExit = true;
    };
  };

  # extra typed options + execStartPre/Post + custom namespace.
  fancy = mkServiceModule {
    name = "gw";
    description = "gateway";
    namespace = "blackmatter.services";
    extraOptions = l: {
      replicas = l.mkOption {
        type = l.types.int;
        default = 3;
      };
    };
    service = {
      command = "/bin/gw";
      execStartPre = [ "/bin/prep" ];
      execStartPost = [ "/bin/notify" ];
      wants = [ "redis.service" ];
      requires = [ "postgres.service" ];
      before = [ "nginx.service" ];
    };
  };
in
{
  # ── enabled: serviceConfig has the core triple + set power fields ────
  enabled-serviceconfig-core-triple = {
    expr =
      let
        sc = (evalNixos [ svc.nixos enable ]).config.systemd.services.tend.serviceConfig;
      in
      {
        inherit (sc) ExecStart Type Restart;
      };
    expected = {
      ExecStart = ''"/nix/store/x/bin/tend" "daemon"'';
      Type = "notify";
      Restart = "on-failure";
    };
  };
  enabled-serviceconfig-power-fields = {
    expr =
      let
        sc = (evalNixos [ svc.nixos enable ]).config.systemd.services.tend.serviceConfig;
      in
      {
        inherit (sc)
          RestartSec
          EnvironmentFile
          StateDirectory
          RuntimeDirectory
          WorkingDirectory
          User
          Group
          ;
      };
    expected = {
      RestartSec = 5;
      EnvironmentFile = "/run/secrets/tend.env";
      StateDirectory = "tend";
      RuntimeDirectory = "tend";
      WorkingDirectory = "/srv/tend";
      User = "tend";
      Group = "tend";
    };
  };
  enabled-environment-and-description = {
    expr =
      let
        s = (evalNixos [ svc.nixos enable ]).config.systemd.services.tend;
      in
      {
        inherit (s) description environment;
      };
    expected = {
      description = "tend repo daemon";
      environment = {
        ZOEKT_URL = "http://localhost:6070";
      };
    };
  };

  # ── disabled: systemd.services stays empty ───────────────────────────
  disabled-emits-no-service = {
    expr = (evalNixos [ svc.nixos ]).config.systemd.services;
    expected = { };
  };

  # ── hardening + serviceConfigExtra merge into serviceConfig ──────────
  hardening-and-extra-merge = {
    expr =
      let
        sc = (evalNixos [ svc.nixos enable ]).config.systemd.services.tend.serviceConfig;
      in
      {
        inherit (sc) ProtectSystem NoNewPrivileges LimitNOFILE;
      };
    expected = {
      ProtectSystem = "strict";
      NoNewPrivileges = true;
      LimitNOFILE = 65536;
    };
  };

  # ── null fields are absent (not emitted with a null value) ───────────
  null-fields-absent-on-bare = {
    expr =
      let
        sc = (evalNixos [ bare.nixos { services.echoer.enable = true; } ]).config.systemd.services.echoer.serviceConfig;
      in
      {
        envFile = sc ? EnvironmentFile;
        stateDir = sc ? StateDirectory;
        user = sc ? User;
        restartSec = sc ? RestartSec;
        remain = sc ? RemainAfterExit;
      };
    expected = {
      envFile = false;
      stateDir = false;
      user = false;
      restartSec = false;
      remain = false;
    };
  };

  # ── execStart verbatim vs escaped command form ───────────────────────
  execstart-verbatim-when-given = {
    expr = (evalNixos [ bare.nixos { services.echoer.enable = true; } ]).config.systemd.services.echoer.serviceConfig.ExecStart;
    expected = "/bin/echo hi";
  };
  command-form-systemd-escapes-spaces = {
    expr = (evalNixos [ spaced.nixos { services.echoer.enable = true; } ]).config.systemd.services.echoer.serviceConfig.ExecStart;
    expected = ''"/bin/echo" "hello world" "--flag"'';
  };

  # ── default Type / Restart / wantedBy / after ────────────────────────
  defaults-type-simple-and-wantedby = {
    expr =
      let
        s = (evalNixos [ bare.nixos { services.echoer.enable = true; } ]).config.systemd.services.echoer;
      in
      {
        type = s.serviceConfig.Type;
        wantedBy = s.wantedBy;
        after = s.after;
      };
    expected = {
      type = "simple";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
    };
  };

  # ── oneshot + remainAfterExit ────────────────────────────────────────
  oneshot-remain-after-exit = {
    expr =
      let
        sc = (evalNixos [ oneshot.nixos { services.migrate.enable = true; } ]).config.systemd.services.migrate.serviceConfig;
      in
      {
        inherit (sc) Type RemainAfterExit;
      };
    expected = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };

  # ── ordering / dep lists land + ExecStartPre/Post ────────────────────
  ordering-deps-and-execstart-hooks = {
    expr =
      let
        s = (evalNixos [ fancy.nixos { blackmatter.services.gw.enable = true; } ]).config.systemd.services.gw;
      in
      {
        wants = s.wants;
        requires = s.requires;
        before = s.before;
        pre = s.serviceConfig.ExecStartPre;
        post = s.serviceConfig.ExecStartPost;
      };
    expected = {
      wants = [ "redis.service" ];
      requires = [ "postgres.service" ];
      before = [ "nginx.service" ];
      pre = [ "/bin/prep" ];
      post = [ "/bin/notify" ];
    };
  };

  # ── extraOptions land + are settable ─────────────────────────────────
  extra-options-default-and-settable = {
    expr = {
      dflt = (evalNixos [ fancy.nixos { blackmatter.services.gw.enable = true; } ]).config.blackmatter.services.gw.replicas;
      set = (evalNixos [
        fancy.nixos
        {
          blackmatter.services.gw.enable = true;
          blackmatter.services.gw.replicas = 7;
        }
      ]).config.blackmatter.services.gw.replicas;
    };
    expected = {
      dflt = 3;
      set = 7;
    };
  };

  # ── darwin projection: ProgramArguments from command + args ──────────
  darwin-programarguments-from-command = {
    expr =
      let
        sc = (evalDarwin [ svc.darwin enable ]).config.launchd.daemons.tend.serviceConfig;
      in
      {
        prog = sc.ProgramArguments;
        keepAlive = sc.KeepAlive;
        runAtLoad = sc.RunAtLoad;
        env = sc.EnvironmentVariables;
        workdir = sc.WorkingDirectory;
      };
    expected = {
      prog = [
        "/nix/store/x/bin/tend"
        "daemon"
      ];
      keepAlive = true;
      runAtLoad = true;
      env = {
        ZOEKT_URL = "http://localhost:6070";
      };
      workdir = "/srv/tend";
    };
  };
  darwin-programarguments-shell-wrap-for-execstart = {
    # Only execStart given (no command): launchd cannot word-split a bare
    # string, so it is wrapped in /bin/sh -c, documented in the header.
    expr = (evalDarwin [ bare.darwin { services.echoer.enable = true; } ]).config.launchd.daemons.echoer.serviceConfig.ProgramArguments;
    expected = [
      "/bin/sh"
      "-c"
      "/bin/echo hi"
    ];
  };
  darwin-oneshot-keepalive-false = {
    expr = (evalDarwin [ oneshot.darwin { services.migrate.enable = true; } ]).config.launchd.daemons.migrate.serviceConfig.KeepAlive;
    expected = false;
  };
  darwin-disabled-emits-nothing = {
    expr = (evalDarwin [ svc.darwin ]).config.launchd.daemons;
    expected = { };
  };

  # ── meta ─────────────────────────────────────────────────────────────
  meta-fields = {
    expr = fancy.meta;
    expected = {
      name = "gw";
      kind = "system-service";
      optionPath = [
        "blackmatter"
        "services"
        "gw"
      ];
      enablePath = [
        "blackmatter"
        "services"
        "gw"
        "enable"
      ];
    };
  };

  # ── class tagging: the nixos module is rejected under a darwin eval ──
  # (an emitted nixos-class module placed in a class="darwin" evalModules
  # throws — the _class mismatch is itself a tested behavior).
}
// iroha.mkModuleEvalCheck {
  name = "service-nixos-module-under-darwin-class";
  modules = [ svc.nixos ];
  class = "darwin";
  universe = [
    (
      { lib, ... }:
      {
        options.systemd.services = lib.mkOption {
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
        (mkServiceModule {
          description = "d";
          service.execStart = "/x";
        }).meta.name
      ).success;
    expected = false;
  };
  missing-description-throws = {
    # description feeds mkEnableOption (lazy) — force the enable option's
    # rendered `description` from the emitted module's option metadata,
    # where the missing-`description` throw lives.
    expr =
      (builtins.tryEval
        (lib.getAttrFromPath [ "options" "services" "x" "enable" "description" ] (evalNixos [
          (mkServiceModule {
            name = "x";
            service.execStart = "/x";
          }).nixos
        ]))
      ).success;
    expected = false;
  };
  missing-exec-throws = {
    # neither execStart nor command — force ExecStart via an eval.
    expr =
      (builtins.tryEval
        (evalNixos [
          (mkServiceModule {
            name = "x";
            description = "d";
            service = { };
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
          (mkServiceModule {
            name = "x";
            description = "d";
            service = {
              execStart = "/a";
              command = "/b";
            };
          }).nixos
          { services.x.enable = true; }
        ]).config.systemd.services.x.serviceConfig.ExecStart
      ).success;
    expected = false;
  };
  bad-type-throws = {
    expr =
      (builtins.tryEval
        (evalNixos [
          (mkServiceModule {
            name = "x";
            description = "d";
            service = {
              command = "/b";
              type = "bogus";
            };
          }).nixos
          { services.x.enable = true; }
        ]).config.systemd.services.x.serviceConfig.Type
      ).success;
    expected = false;
  };
}
