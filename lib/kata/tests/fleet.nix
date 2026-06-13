# Tests — kata.fleet (mkFleet: blanks -> full fleet surface, with stub
# universes per the iroha.mkHostMatrix contract).
{
  lib,
  iroha,
  kata,
}:
let
  universes = {
    nixosSystem = args: {
      kind = "nixos";
      inherit args;
    };
    darwinSystem = args: {
      kind = "darwin";
      inherit args;
    };
  };

  blanks = {
    name = "demo";
    domains = {
      tld = "demo.io";
      locations = {
        rio = "bristol";
        cid = "mobile";
      };
      sshUsers.rio = "ops";
      defaultSshUser = "admin";
    };
    users.users = {
      ops = {
        kind = "interactive";
        uid = 1000;
      };
      robot = {
        kind = "automation";
        uid = 990;
      };
    };
    trust = {
      fleetKeys = [ "ssh-ed25519 FLEET" ];
      automationKeys = [ "ssh-ed25519 AUTO" ];
    };
    nodes = {
      rio = {
        class = "nixos";
        system = "x86_64-linux";
        tags = [ "k3s" ];
        profiles = [ "server-base" ];
        deploy = { };
      };
      cid = {
        class = "darwin";
        system = "aarch64-darwin";
        profiles = [ ];
      };
    };
    caches = [
      {
        url = "https://cache.demo.io";
        publicKey = "cache.demo.io-1:KEY";
      }
    ];
  };

  profileTable.server-base = {
    _file = "<test:profile:server-base>";
  };

  f = kata.mkFleet {
    config = blanks;
    inherit universes;
    profiles = profileTable;
  };

  rioModules = f.nixosConfigurations.rio.args.modules;
in
{
  validated-config-surfaces = {
    expr = f.config.name;
    expected = "demo";
  };
  domains-helpers-live = {
    expr = f.domains.fqdn "rio";
    expected = "rio.bristol.demo.io";
  };
  trust-keys-threaded-into-users = {
    expr = {
      ops = (kata.mkUsers {
        users.x = {
          kind = "interactive";
          uid = 1000;
        };
      }).uids.x;
      # the real assertion: mkFleet's users module carries the fleet keys
      fromFleet =
        (lib.evalModules {
          modules = [
            (
              { lib, ... }:
              {
                options.users.users = lib.mkOption {
                  type = lib.types.attrsOf lib.types.anything;
                  default = { };
                };
                options.users.groups = lib.mkOption {
                  type = lib.types.attrsOf lib.types.anything;
                  default = { };
                };
                options.sops.secrets = lib.mkOption {
                  type = lib.types.attrsOf lib.types.anything;
                  default = { };
                };
                options.systemd.tmpfiles.rules = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                };
                options.services.openssh.extraConfig = lib.mkOption {
                  type = lib.types.lines;
                  default = "";
                };
                options.system.activationScripts = lib.mkOption {
                  type = lib.types.attrsOf lib.types.anything;
                  default = { };
                };
              }
            )
            { _module.args.pkgs.bashInteractive = "BASH"; }
            f.users.module
          ];
        }).config.users.users.ops.openssh.authorizedKeys.keys;
    };
    expected = {
      ops = 1000;
      fromFleet = [ "ssh-ed25519 FLEET" ];
    };
  };
  host-matrix-projects-both-classes = {
    expr = {
      rio = f.nixosConfigurations.rio.kind;
      cid = f.darwinConfigurations.cid.kind;
    };
    expected = {
      rio = "nixos";
      cid = "darwin";
    };
  };
  ssh-user-defaults-from-domains = {
    expr = {
      rio = f.registry.rio.deploy.sshUser or f.deployRs.nodes.rio.sshUser;
      cid = f.registry.cid.sshUser or "absent";
    };
    expected = {
      rio = "ops";
      cid = "absent";
    };
  };
  profile-names-resolve-into-modules = {
    expr = builtins.elem profileTable.server-base rioModules;
    expected = true;
  };
  unknown-profile-name-throws = {
    # The throw lives in a list ELEMENT — force each element to WHNF
    # (tryEval alone only reaches the list spine).
    expr =
      (builtins.tryEval (
        builtins.all (m: builtins.seq m true)
          (kata.mkFleet {
            config = blanks // {
              nodes.rio = blanks.nodes.rio // {
                profiles = [ "ghost" ];
              };
            };
            inherit universes;
            profiles = profileTable;
          }).nixosConfigurations.rio.args.modules
      )).success;
    expected = false;
  };
  users-module-baked-into-nixos-base = {
    # Function equality is not reliable in Nix — the users module is the
    # only FUNCTION-valued module in this fixture's list (profiles,
    # hostname, caches fragments are attrsets), so assert exactly one.
    expr = builtins.length (builtins.filter builtins.isFunction rioModules);
    expected = 1;
  };
  users-module-external-placement-omits-baked-module = {
    # placement "external": the consumer's profiles own account
    # materialization — the function-valued users module must NOT appear
    # in the node module list (it stays exported as f.users.module).
    expr =
      builtins.length (
        builtins.filter builtins.isFunction
          (kata.mkFleet {
            config = blanks;
            inherit universes;
            profiles = profileTable;
            usersModulePlacement = "external";
          }).nixosConfigurations.rio.args.modules
      );
    expected = 0;
  };
  unknown-users-module-placement-throws = {
    expr =
      (builtins.tryEval
        (kata.mkFleet {
          config = blanks;
          inherit universes;
          profiles = profileTable;
          usersModulePlacement = "everywhere";
        }).config.name
      ).success;
    expected = false;
  };
  caches-module-present = {
    expr =
      builtins.any (
        m: (m.nix.settings.extra-substituters or [ ]) == [ "https://cache.demo.io" ]
      ) (builtins.filter builtins.isAttrs rioModules);
    expected = true;
  };
  manifest-null-when-no-apps = {
    expr = f.manifest;
    expected = null;
  };
  by-tag-projection = {
    expr = f.byTag "k3s";
    expected = [ "rio" ];
  };
  invariants-aggregate-passes = {
    expr = (iroha.mkEvalChecks { name = "f"; tests = f.invariants; }).passed;
    expected = true;
  };
  invariants-fail-when-deployed-node-lacks-domain = {
    expr =
      let
        bad = kata.mkFleet {
          config = blanks // {
            domains = {
              tld = "demo.io";
              locations.cid = "mobile";
            };
          };
          inherit universes;
          profiles = profileTable;
        };
      in
      (iroha.mkEvalChecks { name = "bad"; tests = bad.invariants; }).passed;
    expected = false;
  };
  schema-violation-is-typed = {
    expr =
      (builtins.tryEval
        (kata.mkFleet {
          config = blanks // {
            nodez = { };
          };
          inherit universes;
        }).config.name
      ).success;
    expected = false;
  };
  checks-for-shape = {
    expr =
      let
        stubPkgs = {
          runCommand = n: env: script: {
            stub = n;
          };
        };
      in
      builtins.attrNames (f.checksFor stubPkgs);
    expected = [ "kata-fleet-demo" ];
  };
}
