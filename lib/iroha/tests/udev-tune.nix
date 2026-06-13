# Tests — iroha.udev-tune (DEVICE-APPEAR-DRIVEN tuning module emitter:
# typed udev MATCH attrs -> rule line, action RUN+= vs tuneService oneshot
# trigger, the emitted Type=oneshot tuning services, deterministic
# name-sorted concatenation, meta.ruleCount, extraOptions, class tag, throws).
{ lib, iroha }:
let
  inherit (iroha) mkUdevTune;

  # ── stub NixOS option universe ───────────────────────────────────────
  # services.udev.extraRules is a lines/str sink; systemd.services is an
  # attrsOf-anything landing pad for the triggered oneshots.
  nixosUniverse =
    { lib, ... }:
    {
      options = {
        services.udev.extraRules = lib.mkOption {
          type = lib.types.lines;
          default = "";
        };
        systemd.services = lib.mkOption {
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

  # ── specs under test ─────────────────────────────────────────────────
  # net / i40e rule -> tuneService oneshot template; nvme rule -> verbatim
  # action. Two rules; deterministic name-sorted concatenation.
  nic = mkUdevTune {
    name = "i40e-tune";
    description = "Intel X710 10GbE i40e link-up tuning";
    rules = {
      # 'a-link-up' sorts before 'z-...' — proves name-sorted determinism.
      a-link-up = {
        match = {
          SUBSYSTEM = "net";
          ATTRS.driver = "i40e";
        };
        tuneService = "i40e-tune";
        tuning = {
          command = "/run/current-system/sw/bin/seibi nic-tune --driver i40e %i";
          after = [ "network-pre.target" ];
          path = [ "/run/current-system/sw/bin" ];
        };
      };
    };
  };

  # nvme rule with verbatim action (queue scheduler), nested ATTR brace key.
  # The action is emitted VERBATIM inside RUN+="…" (the caller owns the
  # command + any escaping), so the test action carries no inner quotes.
  nvme = mkUdevTune {
    name = "nvme-tune";
    namespace = "blackmatter.hardware";
    description = "NVMe queue tuning";
    rules = {
      sched = {
        match = {
          KERNEL = "nvme0n1";
          ATTR.queue.scheduler = "none";
        };
        action = "/run/current-system/sw/bin/nvme-tune nvme0n1";
      };
    };
  };

  # multi-rule: two action rules, deterministic ordering + concatenation.
  multi = mkUdevTune {
    name = "multi";
    description = "multi";
    rules = {
      # intentionally out of declared order to prove sort-by-name.
      zeta = {
        match.KERNEL = "nvme2n1";
        action = "/bin/z";
      };
      alpha = {
        match.KERNEL = "nvme1n1";
        action = "/bin/a";
      };
    };
  };

  # extra typed options + custom systemctlPath for the tuneService trigger.
  fancy = mkUdevTune {
    name = "gw-tune";
    description = "gateway tune";
    namespace = "blackmatter.hardware";
    systemctlPath = "/custom/bin/systemctl";
    extraOptions = l: {
      ring = l.mkOption {
        type = l.types.int;
        default = 4096;
      };
    };
    rules = {
      up = {
        match.ATTRS.driver = "igc";
        tuneService = "igc-tune";
        tuning.command = "/bin/igc-tune %i";
      };
    };
  };
in
{
  # ── net/i40e rule: extraRules has SUBSYSTEM + driver match + start cmd ─
  # Match keys render in stable lexicographic order (ATTRS before SUBSYSTEM),
  # per the renderer's documented determinism guarantee.
  net-i40e-rule-line = {
    expr = (evalNixos [ nic.nixos { hardware.i40e-tune.enable = true; } ]).config.services.udev.extraRules;
    expected = ''
      # i40e-tune
      ATTRS{driver}=="i40e", SUBSYSTEM=="net", RUN+="/run/current-system/sw/bin/systemctl start i40e-tune@a-link-up"
    '';
  };

  # ── net/i40e rule emits the triggered oneshot (Type=oneshot) ──────────
  net-i40e-tuning-oneshot = {
    expr =
      let
        s = (evalNixos [ nic.nixos { hardware.i40e-tune.enable = true; } ]).config.systemd.services."i40e-tune@";
      in
      {
        type = s.serviceConfig.Type;
        execStart = s.serviceConfig.ExecStart;
        remain = s.serviceConfig.RemainAfterExit;
        after = s.after;
        path = s.path;
      };
    expected = {
      type = "oneshot";
      execStart = "/run/current-system/sw/bin/seibi nic-tune --driver i40e %i";
      remain = true;
      after = [ "network-pre.target" ];
      path = [ "/run/current-system/sw/bin" ];
    };
  };

  # ── nvme rule with verbatim action + nested ATTR{queue/scheduler} ─────
  # Lexicographic match order: ATTR{queue/scheduler} before KERNEL. The
  # nested ATTR.queue.scheduler renders the udev path form ATTR{queue/scheduler}.
  nvme-action-rule-line = {
    expr = (evalNixos [ nvme.nixos { blackmatter.hardware.nvme-tune.enable = true; } ]).config.services.udev.extraRules;
    expected = ''
      # nvme-tune
      ATTR{queue/scheduler}=="none", KERNEL=="nvme0n1", RUN+="/run/current-system/sw/bin/nvme-tune nvme0n1"
    '';
  };

  # ── action rule emits NO triggered oneshot (systemd.services stays {}) ─
  action-rule-no-oneshot = {
    expr = (evalNixos [ nvme.nixos { blackmatter.hardware.nvme-tune.enable = true; } ]).config.systemd.services;
    expected = { };
  };

  # ── disabled: nothing emitted ────────────────────────────────────────
  disabled-emits-nothing = {
    expr =
      let
        c = (evalNixos [ nic.nixos ]).config;
      in
      {
        rules = c.services.udev.extraRules;
        services = c.systemd.services;
      };
    expected = {
      rules = "";
      services = { };
    };
  };

  # ── multiple rules concatenate deterministically (sorted by name) ────
  multi-rules-sorted-concatenation = {
    expr = (evalNixos [ multi.nixos { hardware.multi.enable = true; } ]).config.services.udev.extraRules;
    expected = ''
      # multi
      KERNEL=="nvme1n1", RUN+="/bin/a"
      KERNEL=="nvme2n1", RUN+="/bin/z"
    '';
  };

  # ── custom systemctlPath threads into the tuneService start command ──
  custom-systemctl-path-in-trigger = {
    expr = (evalNixos [ fancy.nixos { blackmatter.hardware.gw-tune.enable = true; } ]).config.services.udev.extraRules;
    expected = ''
      # gw-tune
      ATTRS{driver}=="igc", RUN+="/custom/bin/systemctl start igc-tune@up"
    '';
  };

  # ── extraOptions land + are settable ─────────────────────────────────
  extra-options-default-and-settable = {
    expr = {
      dflt = (evalNixos [ fancy.nixos { blackmatter.hardware.gw-tune.enable = true; } ]).config.blackmatter.hardware.gw-tune.ring;
      set = (evalNixos [
        fancy.nixos
        {
          blackmatter.hardware.gw-tune.enable = true;
          blackmatter.hardware.gw-tune.ring = 8192;
        }
      ]).config.blackmatter.hardware.gw-tune.ring;
    };
    expected = {
      dflt = 4096;
      set = 8192;
    };
  };

  # ── meta ─────────────────────────────────────────────────────────────
  meta-fields = {
    expr = nvme.meta;
    expected = {
      name = "nvme-tune";
      kind = "udev-tune";
      ruleCount = 1;
      optionPath = [
        "blackmatter"
        "hardware"
        "nvme-tune"
      ];
      enablePath = [
        "blackmatter"
        "hardware"
        "nvme-tune"
        "enable"
      ];
    };
  };
  meta-rulecount-multi = {
    expr = multi.meta.ruleCount;
    expected = 2;
  };
}
# ── class tagging: the nixos module is rejected under a darwin eval ──
// iroha.mkModuleEvalCheck {
  name = "udev-tune-nixos-module-under-darwin-class";
  modules = [ nic.nixos ];
  class = "darwin";
  universe = [
    (
      { lib, ... }:
      {
        options.services.udev.extraRules = lib.mkOption {
          type = lib.types.lines;
          default = "";
        };
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
        (mkUdevTune {
          description = "d";
          rules.r = {
            match.KERNEL = "x";
            action = "/x";
          };
        }).meta.name
      ).success;
    expected = false;
  };
  missing-description-throws = {
    expr =
      (builtins.tryEval
        (lib.getAttrFromPath [ "options" "hardware" "x" "enable" "description" ] (evalNixos [
          (mkUdevTune {
            name = "x";
            rules.r = {
              match.KERNEL = "x";
              action = "/x";
            };
          }).nixos
        ]))
      ).success;
    expected = false;
  };
  missing-rules-throws = {
    expr =
      (builtins.tryEval
        (mkUdevTune {
          name = "x";
          description = "d";
        }).meta.ruleCount
      ).success;
    expected = false;
  };
  empty-rules-throws = {
    expr =
      (builtins.tryEval
        (mkUdevTune {
          name = "x";
          description = "d";
          rules = { };
        }).meta.ruleCount
      ).success;
    expected = false;
  };
  rule-no-action-or-tuneservice-throws = {
    # neither action nor tuneService — force the rule line via an eval.
    expr =
      (builtins.tryEval
        (evalNixos [
          (mkUdevTune {
            name = "x";
            description = "d";
            rules.r.match.KERNEL = "x";
          }).nixos
          { hardware.x.enable = true; }
        ]).config.services.udev.extraRules
      ).success;
    expected = false;
  };
  rule-both-action-and-tuneservice-throws = {
    expr =
      (builtins.tryEval
        (evalNixos [
          (mkUdevTune {
            name = "x";
            description = "d";
            rules.r = {
              match.KERNEL = "x";
              action = "/a";
              tuneService = "t";
              tuning.command = "/c";
            };
          }).nixos
          { hardware.x.enable = true; }
        ]).config.services.udev.extraRules
      ).success;
    expected = false;
  };
  tuneservice-without-tuning-throws = {
    expr =
      (builtins.tryEval
        (evalNixos [
          (mkUdevTune {
            name = "x";
            description = "d";
            rules.r = {
              match.KERNEL = "x";
              tuneService = "t";
            };
          }).nixos
          { hardware.x.enable = true; }
        ]).config.services.udev.extraRules
      ).success;
    expected = false;
  };
  rule-empty-match-throws = {
    expr =
      (builtins.tryEval
        (evalNixos [
          (mkUdevTune {
            name = "x";
            description = "d";
            rules.r = {
              match = { };
              action = "/a";
            };
          }).nixos
          { hardware.x.enable = true; }
        ]).config.services.udev.extraRules
      ).success;
    expected = false;
  };
}
