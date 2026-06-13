# Tests — kata.users (registry -> NixOS module; evalModules with a stub
# universe mirroring the option paths the module touches).
{
  lib,
  iroha,
  kata,
}:
let
  registry = {
    users = {
      ops = {
        kind = "interactive";
        uid = 1000;
        keys = [ "ssh-ed25519 OPSKEY" ];
        identitySecret.sopsPath = "ops/ssh/private-key";
      };
      legacy = {
        kind = "interactive";
        uid = 1001;
        description = "legacy interactive user";
      };
      robot = {
        kind = "automation";
        uid = 990;
        keys = [ "ssh-ed25519 ROBOTKEY" ];
      };
    };
    groups.media = 980;
  };

  u = kata.mkUsers registry;

  universe =
    { lib, ... }:
    {
      options = {
        users.users = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        users.groups = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        sops.secrets = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        systemd.tmpfiles.rules = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        services.openssh.extraConfig = lib.mkOption {
          type = lib.types.lines;
          default = "";
        };
        system.activationScripts = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
      };
    };

  stubPkgs.bashInteractive = "BASH_DRV";

  cfg =
    (lib.evalModules {
      modules = [
        universe
        { _module.args.pkgs = stubPkgs; }
        u.module
      ];
    }).config;
in
{
  uids-projection = {
    expr = u.uids;
    expected = {
      ops = 1000;
      legacy = 1001;
      robot = 990;
    };
  };
  gids-include-standalone-groups = {
    expr = u.gids.media;
    expected = 980;
  };
  registry-partitions-by-kind = {
    expr = u.registry;
    expected = {
      interactive = [
        "legacy"
        "ops"
      ];
      automation = [ "robot" ];
    };
  };
  interactive-user-shape = {
    expr = {
      normal = cfg.users.users.ops.isNormalUser;
      uid = cfg.users.users.ops.uid;
      home = cfg.users.users.ops.home;
      keys = cfg.users.users.ops.openssh.authorizedKeys.keys;
      shellForced = cfg.users.users.ops.shell;
    };
    expected = {
      normal = true;
      uid = 1000;
      home = "/home/ops";
      keys = [ "ssh-ed25519 OPSKEY" ];
      shellForced = "BASH_DRV";
    };
  };
  automation-user-shape = {
    expr = {
      system = cfg.users.users.robot.isSystemUser;
      home = cfg.users.users.robot.home;
      groups = cfg.users.users.robot.extraGroups;
    };
    expected = {
      system = true;
      home = "/var/lib/robot";
      groups = [ "wheel" ];
    };
  };
  per-user-group-and-standalone-group = {
    expr = {
      ops = cfg.users.groups.ops.gid;
      media = cfg.users.groups.media.gid;
    };
    expected = {
      ops = 1000;
      media = 980;
    };
  };
  identity-secret-lands = {
    expr = cfg.sops.secrets."ops/ssh/private-key";
    expected = {
      owner = "ops";
      group = "ops";
      mode = "0600";
      path = "/home/ops/.ssh/id_ed25519";
    };
  };
  tmpfiles-only-for-identity-users = {
    expr = cfg.systemd.tmpfiles.rules;
    expected = [ "d /home/ops/.ssh 0700 ops ops -" ];
  };
  sshd-hardening-for-automation = {
    expr = lib.hasInfix "Match User robot" cfg.services.openssh.extraConfig
    && lib.hasInfix "PermitTTY no" cfg.services.openssh.extraConfig;
    expected = true;
  };
  uid-migration-script-covers-every-user = {
    expr =
      let
        t = cfg.system.activationScripts.kataUsersUidMigrate.text;
      in
      lib.hasInfix "migrate_home ops 1000" t
      && lib.hasInfix "migrate_home legacy 1001" t
      && lib.hasInfix "migrate_home robot 990 990 /var/lib/robot" t;
    expected = true;
  };
  uid-migration-can-be-disabled = {
    expr =
      (lib.evalModules {
        modules = [
          universe
          { _module.args.pkgs = stubPkgs; }
          (kata.mkUsers (registry // { uidMigration = false; })).module
        ];
      }).config.system.activationScripts ? kataUsersUidMigrate;
    expected = false;
  };
  fleet-shell-override = {
    expr =
      (lib.evalModules {
        modules = [
          universe
          { _module.args.pkgs = stubPkgs; }
          (kata.mkUsers (registry // { shell = "FROST_DRV"; })).module
        ];
      }).config.users.users.ops.shell;
    expected = "FROST_DRV";
  };
  node-override-beats-mkDefault = {
    expr =
      (lib.evalModules {
        modules = [
          universe
          { _module.args.pkgs = stubPkgs; }
          u.module
          { users.users.ops.extraGroups = [ "only-this" ]; }
        ];
      }).config.users.users.ops.extraGroups;
    expected = [ "only-this" ];
  };
  invariants-pass = {
    expr = (iroha.mkEvalChecks { name = "u"; tests = u.invariants; }).passed;
    expected = true;
  };
  invariants-fail-on-duplicate-uid = {
    expr =
      (iroha.mkEvalChecks {
        name = "bad";
        tests =
          (kata.mkUsers {
            users = {
              a = {
                kind = "interactive";
                uid = 1000;
              };
              b = {
                kind = "interactive";
                uid = 1000;
                gid = 1001;
              };
            };
          }).invariants;
      }).passed;
    expected = false;
  };
  invariants-fail-on-automation-uid-in-normal-range = {
    expr =
      (iroha.mkEvalChecks {
        name = "bad";
        tests =
          (kata.mkUsers {
            users.bot = {
              kind = "automation";
              uid = 2000;
            };
          }).invariants;
      }).passed;
    expected = false;
  };
  missing-kind-throws = {
    expr = (builtins.tryEval (kata.mkUsers { users.x.uid = 1000; })).success;
    expected = false;
  };
  unknown-kind-throws = {
    expr =
      (builtins.tryEval (kata.mkUsers {
        users.x = {
          kind = "wizard";
          uid = 1000;
        };
      })).success;
    expected = false;
  };
  empty-users-throws = {
    expr = (builtins.tryEval (kata.mkUsers { users = { }; })).success;
    expected = false;
  };
}
