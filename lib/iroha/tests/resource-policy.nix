# Tests — iroha.resource-policy (mkResourcePolicy: a typed CPU/memory/IO/
# task resource envelope rendered onto systemd units, with eval-time sanity
# assertions — only non-null serviceConfig keys land; cpuQuota int->"<n>%"
# and string passthrough; memoryHigh<=memoryMax + cpuWeight/ioWeight/tasksMax
# range checks emit as config.assertions; class tagging; typed throws).
{ lib, iroha }:
let
  inherit (iroha) mkResourcePolicy;

  # ── stub NixOS option universe ───────────────────────────────────────
  # systemd.services :: attrsOf anything — the overlay lands per unit name.
  # assertions :: listOf attrs — resolved sanity checks land here.
  nixosUniverse =
    { lib, ... }:
    {
      options = {
        systemd.services = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        assertions = lib.mkOption {
          type = lib.types.listOf lib.types.attrs;
          default = [ ];
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

  enable = { systemd.node-budget.enable = true; };

  # ── specs under test ─────────────────────────────────────────────────
  # Canonical: one unit, int cpuQuota + str memoryMax + tasksMax. Asserts
  # only the set fields; other serviceConfig keys absent.
  policy = mkResourcePolicy {
    name = "node-budget";
    description = "node-budget breathe-L2 envelope";
    units = {
      sshd = {
        cpuQuota = 50;
        memoryMax = "2G";
        tasksMax = 100;
      };
    };
  };

  # cpuQuota as a verbatim string ("75%") + allowedCPUs + oomScoreAdjust.
  strQuota = mkResourcePolicy {
    name = "str-quota";
    description = "str quota envelope";
    units = {
      worker = {
        cpuQuota = "75%";
        allowedCPUs = "0-3";
        oomScoreAdjust = -500;
      };
    };
  };

  # cpuWeight + ioWeight + memoryHigh<=memoryMax (sane) — asserts all true.
  weights = mkResourcePolicy {
    name = "weights";
    description = "cgroup-weight envelope";
    units = {
      svc = {
        cpuWeight = 200;
        ioWeight = 100;
        memoryMax = "2G";
        memoryHigh = "1G";
      };
    };
  };

  # sshd-survivability shape: protected floor (memoryMin) + top weights.
  survivability = mkResourcePolicy {
    name = "sshd-survivability";
    description = "sshd resource guarantees";
    units = {
      sshd = {
        cpuWeight = 10000;
        memoryMin = "64M";
        ioWeight = 10000;
      };
    };
  };

  # BAD cpuWeight (0) — the assertion must fire (assertion = false).
  badWeightZero = mkResourcePolicy {
    name = "bad-weight";
    description = "bad cpuWeight";
    units = {
      svc.cpuWeight = 0;
    };
  };

  # BAD cpuWeight (99999, > 10000) — assertion fires.
  badWeightHigh = mkResourcePolicy {
    name = "bad-weight-high";
    description = "bad cpuWeight high";
    units = {
      svc.cpuWeight = 99999;
    };
  };

  # BAD memoryHigh > memoryMax — assertion fires.
  badMemHigh = mkResourcePolicy {
    name = "bad-mem";
    description = "memoryHigh above memoryMax";
    units = {
      svc = {
        memoryMax = "1G";
        memoryHigh = "2G";
      };
    };
  };

  # Multiple units in one policy.
  multi = mkResourcePolicy {
    name = "multi";
    description = "multi-unit envelope";
    units = {
      sshd.tasksMax = 50;
      worker.cpuQuota = 25;
    };
  };

  # extraOptions + custom namespace.
  fancy = mkResourcePolicy {
    name = "fancy-budget";
    description = "fancy envelope";
    namespace = "blackmatter.systemd";
    extraOptions = l: {
      replicas = l.mkOption {
        type = l.types.int;
        default = 4;
      };
    };
    units = {
      svc.tasksMax = 10;
    };
  };
in
{
  # ── set fields land; unset fields ABSENT ─────────────────────────────
  set-fields-land-others-absent = {
    expr =
      let
        sc = (evalNixos [ policy.nixos enable ]).config.systemd.services.sshd.serviceConfig;
      in
      {
        cpuQuota = sc.CPUQuota;
        memoryMax = sc.MemoryMax;
        tasksMax = sc.TasksMax;
        cpuWeight = sc ? CPUWeight;
        memoryHigh = sc ? MemoryHigh;
        ioWeight = sc ? IOWeight;
        allowedCPUs = sc ? AllowedCPUs;
        oomScoreAdjust = sc ? OOMScoreAdjust;
      };
    expected = {
      cpuQuota = "50%";
      memoryMax = "2G";
      tasksMax = 100;
      cpuWeight = false;
      memoryHigh = false;
      ioWeight = false;
      allowedCPUs = false;
      oomScoreAdjust = false;
    };
  };

  # ── cpuQuota string passes through verbatim ──────────────────────────
  cpuquota-string-passthrough = {
    expr = (evalNixos [ strQuota.nixos { systemd.str-quota.enable = true; } ]).config.systemd.services.worker.serviceConfig.CPUQuota;
    expected = "75%";
  };

  # ── allowedCPUs + oomScoreAdjust land verbatim ───────────────────────
  allowed-cpus-and-oom = {
    expr =
      let
        sc = (evalNixos [ strQuota.nixos { systemd.str-quota.enable = true; } ]).config.systemd.services.worker.serviceConfig;
      in
      {
        inherit (sc) AllowedCPUs OOMScoreAdjust;
      };
    expected = {
      AllowedCPUs = "0-3";
      OOMScoreAdjust = -500;
    };
  };

  # ── cpuWeight + ioWeight + memoryHigh land ───────────────────────────
  weights-land = {
    expr =
      let
        sc = (evalNixos [ weights.nixos { systemd.weights.enable = true; } ]).config.systemd.services.svc.serviceConfig;
      in
      {
        inherit (sc) CPUWeight IOWeight MemoryMax MemoryHigh;
      };
    expected = {
      CPUWeight = 200;
      IOWeight = 100;
      MemoryMax = "2G";
      MemoryHigh = "1G";
    };
  };

  # ── mkResourceServiceConfig: the PURE per-unit renderer (no module) ──
  pure-renderer-only-nonnull-fields = {
    expr = iroha.mkResourceServiceConfig {
      cpuQuota = 400;
      memoryHigh = "2G";
      memoryMax = "4G";
      ioWeight = 80;
    };
    expected = {
      CPUQuota = "400%";
      MemoryHigh = "2G";
      MemoryMax = "4G";
      IOWeight = 80;
    };
  };
  pure-renderer-memorymin-and-string-quota = {
    expr = iroha.mkResourceServiceConfig {
      cpuQuota = "75%";
      memoryMin = "64M";
      allowedCPUs = "0-3";
    };
    expected = {
      CPUQuota = "75%";
      MemoryMin = "64M";
      AllowedCPUs = "0-3";
    };
  };
  pure-renderer-empty-policy-empty-config = {
    expr = iroha.mkResourceServiceConfig { };
    expected = { };
  };

  # ── memoryMin (protected floor) lands as MemoryMin (sshd-survivability) ──
  memory-min-lands = {
    expr =
      let
        sc = (evalNixos [ survivability.nixos { systemd.sshd-survivability.enable = true; } ]).config.systemd.services.sshd.serviceConfig;
      in
      {
        inherit (sc) CPUWeight IOWeight MemoryMin;
        hasMemoryMax = sc ? MemoryMax;
      };
    expected = {
      CPUWeight = 10000;
      IOWeight = 10000;
      MemoryMin = "64M";
      hasMemoryMax = false;
    };
  };

  # ── sane envelope: NO assertion fires (all assertions hold) ──────────
  sane-weights-no-failing-assertion = {
    expr =
      let
        asserts = (evalNixos [ weights.nixos { systemd.weights.enable = true; } ]).config.assertions;
      in
      builtins.any (a: a.assertion == false) asserts;
    expected = false;
  };

  # ── canonical policy: tasksMax assertion present + holding ───────────
  tasksmax-assertion-holds = {
    expr =
      let
        asserts = (evalNixos [ policy.nixos enable ]).config.assertions;
      in
      {
        count = builtins.length asserts;
        anyFailing = builtins.any (a: a.assertion == false) asserts;
      };
    expected = {
      count = 1;
      anyFailing = false;
    };
  };

  # ── BAD cpuWeight (0): a FAILING assertion is present ────────────────
  bad-cpuweight-zero-fires = {
    expr =
      let
        asserts = (evalNixos [ badWeightZero.nixos { systemd.bad-weight.enable = true; } ]).config.assertions;
      in
      builtins.any (a: a.assertion == false) asserts;
    expected = true;
  };

  # ── BAD cpuWeight (99999): a FAILING assertion is present ────────────
  bad-cpuweight-high-fires = {
    expr =
      let
        asserts = (evalNixos [ badWeightHigh.nixos { systemd.bad-weight-high.enable = true; } ]).config.assertions;
      in
      builtins.any (a: a.assertion == false) asserts;
    expected = true;
  };

  # ── BAD memoryHigh > memoryMax: a FAILING assertion is present ───────
  bad-memhigh-fires = {
    expr =
      let
        asserts = (evalNixos [ badMemHigh.nixos { systemd.bad-mem.enable = true; } ]).config.assertions;
      in
      builtins.any (a: a.assertion == false) asserts;
    expected = true;
  };

  # ── disabled: NOTHING emitted (no services, no assertions) ───────────
  disabled-emits-no-service = {
    expr = (evalNixos [ policy.nixos ]).config.systemd.services;
    expected = { };
  };
  disabled-emits-no-assertions = {
    expr = (evalNixos [ policy.nixos ]).config.assertions;
    expected = [ ];
  };

  # ── multiple units: each gets its own serviceConfig overlay ──────────
  multiple-units-land = {
    expr =
      let
        svcs = (evalNixos [ multi.nixos { systemd.multi.enable = true; } ]).config.systemd.services;
      in
      {
        sshdTasks = svcs.sshd.serviceConfig.TasksMax;
        workerQuota = svcs.worker.serviceConfig.CPUQuota;
      };
    expected = {
      sshdTasks = 50;
      workerQuota = "25%";
    };
  };

  # ── extraOptions land + are settable; custom namespace ───────────────
  extra-options-default-and-settable = {
    expr = {
      dflt = (evalNixos [ fancy.nixos { blackmatter.systemd.fancy-budget.enable = true; } ]).config.blackmatter.systemd.fancy-budget.replicas;
      set = (evalNixos [
        fancy.nixos
        {
          blackmatter.systemd.fancy-budget.enable = true;
          blackmatter.systemd.fancy-budget.replicas = 9;
        }
      ]).config.blackmatter.systemd.fancy-budget.replicas;
    };
    expected = {
      dflt = 4;
      set = 9;
    };
  };

  # ── meta carries unitCount + paths + kind ────────────────────────────
  meta-fields = {
    expr = multi.meta;
    expected = {
      name = "multi";
      kind = "resource-policy";
      unitCount = 2;
      optionPath = [
        "systemd"
        "multi"
      ];
      enablePath = [
        "systemd"
        "multi"
        "enable"
      ];
    };
  };

  # ── class tagging: the nixos module is rejected under a darwin eval ──
}
// iroha.mkModuleEvalCheck {
  name = "resource-policy-nixos-module-under-darwin-class";
  modules = [ policy.nixos ];
  class = "darwin";
  universe = [
    (
      { lib, ... }:
      {
        options.systemd.services = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        options.assertions = lib.mkOption {
          type = lib.types.listOf lib.types.attrs;
          default = [ ];
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
        (mkResourcePolicy {
          description = "d";
          units = {
            svc.tasksMax = 1;
          };
        }).meta.name
      ).success;
    expected = false;
  };
  missing-units-throws = {
    expr =
      (builtins.tryEval
        (mkResourcePolicy {
          name = "x";
          description = "d";
        }).meta.kind
      ).success;
    expected = false;
  };
  empty-units-throws = {
    expr =
      (builtins.tryEval
        (mkResourcePolicy {
          name = "x";
          description = "d";
          units = { };
        }).meta.kind
      ).success;
    expected = false;
  };
  units-not-attrs-throws = {
    expr =
      (builtins.tryEval
        (mkResourcePolicy {
          name = "x";
          description = "d";
          units = "nope";
        }).meta.kind
      ).success;
    expected = false;
  };
  unit-policy-not-attrs-throws = {
    # a unitPolicy that is a string — surfaced when the serviceConfig
    # overlay forces inside config (deepSeq an enabled eval).
    expr =
      (builtins.tryEval
        (builtins.deepSeq
          (evalNixos [
            (mkResourcePolicy {
              name = "bad";
              description = "d";
              units = {
                svc = "nope";
              };
            }).nixos
            { systemd.bad.enable = true; }
          ]).config.systemd.services
          true)
      ).success;
    expected = false;
  };
  cpuquota-bad-type-throws = {
    # cpuQuota a bool — surfaced when CPUQuota forces inside config.
    expr =
      (builtins.tryEval
        (builtins.deepSeq
          (evalNixos [
            (mkResourcePolicy {
              name = "bad";
              description = "d";
              units = {
                svc.cpuQuota = true;
              };
            }).nixos
            { systemd.bad.enable = true; }
          ]).config.systemd.services
          true)
      ).success;
    expected = false;
  };
}
