# Tests — iroha.fleet-inventory (machines × services × instances placement:
# membership union + dedup, per-machine module projection, settings overlay
# semantics, tag queries, throw-free invariants, registry).
{ lib, iroha }:
let
  inherit (iroha) mkFleetInventory mkEvalChecks;

  inv = mkFleetInventory {
    machines = {
      plo = {
        tags = [
          "k3s"
          "server"
        ];
      };
      zek = {
        tags = [ "k3s" ];
      };
      cid = {
        tags = [ "darwin" ];
      };
    };
    services = {
      vpn.roles = {
        server = args: { svc = args; };
        client = args: { cli = args; };
      };
      # A service with no instances — registry.byService still keys it.
      dns.roles = { };
    };
    instances = {
      prod-vpn = {
        service = "vpn";
        roles = {
          server.machines.plo = {
            port = 51820;
          };
          client = {
            tags = [ "k3s" ];
            settings = {
              mtu = 1420;
            };
          };
        };
      };
    };
  };

  # plo holds BOTH roles of the instance: server by explicit placement AND
  # client by tag "k3s" — a machine can hold several roles at once.
  prodMembers = {
    client = [
      "plo"
      "zek"
    ];
    server = [ "plo" ];
  };

  ploModules = inv.modulesFor "plo";
  serverArgs =
    (lib.findFirst (m: m ? svc) (throw "test fixture: no server module for plo") ploModules).svc;

  # Overlay semantics: zek is BOTH tag-matched and explicitly placed (dedup
  # proof) and carries a per-machine overlay; plo is tag-matched only.
  ovr = mkFleetInventory {
    machines = {
      plo.tags = [ "k3s" ];
      zek.tags = [ "k3s" ];
    };
    services.vpn.roles.client = args: { cli = args; };
    instances.net = {
      service = "vpn";
      roles.client = {
        tags = [ "k3s" ];
        settings = {
          mtu = 1420;
          nest = {
            a = 1;
            b = 2;
          };
        };
        machines.zek = {
          mtu = 9000;
          nest = {
            a = 9;
          };
        };
      };
    };
  };
  ovrSettingsFor = m: (builtins.head (ovr.modulesFor m)).cli.settings;

  # Typed-throw / invariant-failure inventories (each violation isolated).
  badService = mkFleetInventory {
    machines.plo = { };
    services.vpn.roles.server = args: { svc = args; };
    instances.bad = {
      service = "nope";
      roles.server = { };
    };
  };
  badRole = mkFleetInventory {
    machines.plo = { };
    services.vpn.roles.server = args: { svc = args; };
    instances.i = {
      service = "vpn";
      roles.gateway = { };
    };
  };
  ghost = mkFleetInventory {
    machines.plo = { };
    services.vpn.roles.server = args: { svc = args; };
    instances.i = {
      service = "vpn";
      roles.server.machines.ghost = { };
    };
  };
  noTag = mkFleetInventory {
    machines.plo.tags = [ "k3s" ];
    services.vpn.roles.client = args: { cli = args; };
    instances.i = {
      service = "vpn";
      roles.client.tags = [ "windows" ];
    };
  };
in
{
  # ── membersOf ──────────────────────────────────────────────────────────
  members-of-unions-explicit-and-tag = {
    expr = inv.membersOf "prod-vpn";
    expected = prodMembers;
  };
  members-dedup-explicit-and-tag = {
    # zek is explicit AND tag-matched — appears exactly once.
    expr = (ovr.membersOf "net").client;
    expected = [
      "plo"
      "zek"
    ];
  };
  members-of-unknown-instance-throws = {
    expr = (builtins.tryEval (inv.membersOf "nope")).success;
    expected = false;
  };

  # ── modulesFor ─────────────────────────────────────────────────────────
  modules-for-zek-single-client-module = {
    # ONE module; its args carry the role settings, the machine name, and
    # the membership of EVERY role of the instance.
    expr = inv.modulesFor "zek";
    expected = [
      {
        cli = {
          instanceName = "prod-vpn";
          roleName = "client";
          machineName = "zek";
          settings = {
            mtu = 1420;
          };
          members = prodMembers;
        };
      }
    ];
  };
  modules-for-plo-two-modules = {
    expr = builtins.length ploModules;
    expected = 2;
  };
  modules-for-plo-deterministic-role-order = {
    # Instances and roles project in sorted attrName order: client < server.
    expr = (builtins.head ploModules) ? cli;
    expected = true;
  };
  modules-for-plo-server-explicit-overlay = {
    # Explicit per-machine settings merged over (empty) role settings.
    expr = {
      inherit (serverArgs) machineName roleName settings;
    };
    expected = {
      machineName = "plo";
      roleName = "server";
      settings = {
        port = 51820;
      };
    };
  };
  modules-for-cid-empty = {
    expr = inv.modulesFor "cid";
    expected = [ ];
  };
  modules-for-unknown-machine-throws = {
    expr = (builtins.tryEval (ghost.modulesFor "ghost")).success;
    expected = false;
  };

  # ── settings overlay semantics ─────────────────────────────────────────
  per-machine-overlay-wins = {
    expr = (ovrSettingsFor "zek").mtu;
    expected = 9000;
  };
  overlay-merge-is-shallow = {
    # `//` by design: the overlay replaces a nested attr WHOLESALE
    # (nest.b from the role settings is gone).
    expr = (ovrSettingsFor "zek").nest;
    expected = {
      a = 9;
    };
  };
  non-overlaid-machine-keeps-role-settings = {
    expr = ovrSettingsFor "plo";
    expected = {
      mtu = 1420;
      nest = {
        a = 1;
        b = 2;
      };
    };
  };

  # ── machinesWithTag ────────────────────────────────────────────────────
  machines-with-tag-k3s = {
    expr = inv.machinesWithTag "k3s";
    expected = [
      "plo"
      "zek"
    ];
  };
  machines-with-tag-darwin = {
    expr = inv.machinesWithTag "darwin";
    expected = [ "cid" ];
  };
  machines-with-tag-unknown-empty = {
    expr = inv.machinesWithTag "nope";
    expected = [ ];
  };

  # ── typed throws (lazy — force the placement) ──────────────────────────
  unknown-instance-service-throws = {
    expr = (builtins.tryEval (builtins.deepSeq (badService.membersOf "bad") true)).success;
    expected = false;
  };
  unknown-role-throws = {
    expr = (builtins.tryEval (builtins.deepSeq (badRole.membersOf "i") true)).success;
    expected = false;
  };

  # ── invariants (throw-free reporting view) ─────────────────────────────
  invariants-pass-for-good-inventory = {
    expr =
      (mkEvalChecks {
        name = "fleet-inventory-good";
        tests = inv.invariants;
      }).passed;
    expected = true;
  };
  unknown-service-invariant-reports-as-data = {
    expr = badService.invariants.every-instance-service-exists.expr;
    expected = [ "bad" ];
  };
  unknown-role-invariant-reports-as-data = {
    expr = badRole.invariants.every-instance-role-exists-in-its-service.expr;
    expected = [ "i.gateway" ];
  };
  invariants-fail-for-unknown-explicit-machine = {
    expr =
      (mkEvalChecks {
        name = "fleet-inventory-ghost";
        tests = ghost.invariants;
      }).passed;
    expected = false;
  };
  ghost-machine-invariant-reports-as-data = {
    expr = ghost.invariants.every-explicit-role-machine-exists.expr;
    expected = [ "i.server.ghost" ];
  };
  invariants-fail-for-unmatched-tag = {
    expr =
      (mkEvalChecks {
        name = "fleet-inventory-no-tag";
        tests = noTag.invariants;
      }).passed;
    expected = false;
  };
  unmatched-tag-invariant-reports-as-data = {
    expr = noTag.invariants.every-tag-reference-matches-a-machine.expr;
    expected = [ "i.client:windows" ];
  };

  # ── registry ───────────────────────────────────────────────────────────
  registry-pure-data = {
    expr = inv.registry;
    expected = {
      machineCount = 3;
      instanceCount = 1;
      byService = {
        dns = [ ];
        vpn = [ "prod-vpn" ];
      };
    };
  };
}
