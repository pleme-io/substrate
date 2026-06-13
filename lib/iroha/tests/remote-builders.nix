# Tests — iroha.remote-builders (typed remote build machines → a sorted
# nix.buildMachines list + nix.distributedBuilds + programs.ssh.extraConfig
# Host blocks, class tagging, deterministic ordering, typed throws).
{ lib, iroha }:
let
  inherit (iroha) mkRemoteBuilders;

  # ── stub NixOS option universe (only the touched paths) ──────────────
  nixosUniverse =
    { lib, ... }:
    {
      options = {
        nix.buildMachines = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = [ ];
        };
        nix.distributedBuilds = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
        programs.ssh.extraConfig = lib.mkOption {
          type = lib.types.lines;
          default = "";
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

  enable = { nix.remote-builders.enable = true; };

  # ── specs under test ─────────────────────────────────────────────────
  # Two builders, intentionally declared out of sorted order (zeta before
  # alpha) to prove the emitted list sorts by name. alpha uses `systems`,
  # carries features + sshUser/sshKey + publicHostKey; zeta uses `system`,
  # carries a wake-aware proxyCommand.
  two = mkRemoteBuilders {
    builders = {
      zeta = {
        hostName = "zeta-builder-ssm";
        system = "aarch64-linux";
        proxyCommand = "cordel builder-wake --config /etc/zeta.yaml %p";
        maxJobs = 4;
      };
      alpha = {
        hostName = "alpha.builder.quero.lol";
        systems = [ "x86_64-linux" ];
        maxJobs = 8;
        speedFactor = 2;
        sshUser = "builder";
        sshKey = "/run/secrets/builder-key";
        supportedFeatures = [
          "kvm"
          "big-parallel"
        ];
        mandatoryFeatures = [ "big-parallel" ];
        publicHostKey = "AAAAC3NzaC1lZDI1NTE5";
      };
    };
  };

  # Single plain builder — no proxyCommand, no sshUser/sshKey: minimal block.
  plain = mkRemoteBuilders {
    name = "rb";
    builders = {
      solo = {
        hostName = "solo.example.com";
        system = "x86_64-linux";
      };
    };
  };

  # Custom namespace + extra typed options.
  fancy = mkRemoteBuilders {
    name = "fleet";
    namespace = "blackmatter.nix";
    extraOptions = l: {
      replicas = l.mkOption {
        type = l.types.int;
        default = 3;
      };
    };
    builders = {
      one = {
        hostName = "one.host";
        system = "x86_64-linux";
      };
    };
  };
in
{
  # ── two builders: buildMachines has both, SORTED by name ─────────────
  two-buildmachines-sorted-hosts = {
    expr = map (m: m.hostName) (evalNixos [ two.nixos enable ]).config.nix.buildMachines;
    expected = [
      "alpha.builder.quero.lol"
      "zeta-builder-ssm"
    ];
  };
  two-distributedbuilds-true = {
    expr = (evalNixos [ two.nixos enable ]).config.nix.distributedBuilds;
    expected = true;
  };

  # ── systems normalization: `system` → [system]; `systems` verbatim ───
  systems-vs-system-both-become-lists = {
    expr =
      let
        bms = (evalNixos [ two.nixos enable ]).config.nix.buildMachines;
        alpha = builtins.head bms; # sorted → alpha first
        zeta = builtins.elemAt bms 1;
      in
      {
        alpha = alpha.systems;
        zeta = zeta.systems;
      };
    expected = {
      alpha = [ "x86_64-linux" ];
      zeta = [ "aarch64-linux" ];
    };
  };

  # ── per-builder fields carried (maxJobs/speedFactor/protocol/features) ─
  builder-fields-carried = {
    expr =
      let
        alpha = builtins.head (evalNixos [ two.nixos enable ]).config.nix.buildMachines;
      in
      {
        inherit (alpha)
          maxJobs
          speedFactor
          protocol
          supportedFeatures
          mandatoryFeatures
          sshUser
          sshKey
          publicHostKey
          ;
      };
    expected = {
      maxJobs = 8;
      speedFactor = 2;
      protocol = "ssh-ng";
      supportedFeatures = [
        "kvm"
        "big-parallel"
      ];
      mandatoryFeatures = [ "big-parallel" ];
      sshUser = "builder";
      sshKey = "/run/secrets/builder-key";
      publicHostKey = "AAAAC3NzaC1lZDI1NTE5";
    };
  };

  # ── optional builder fields are ABSENT when unset (not null-valued) ──
  optional-fields-absent-on-plain = {
    expr =
      let
        solo = builtins.head (evalNixos [ plain.nixos { nix.rb.enable = true; } ]).config.nix.buildMachines;
      in
      {
        sshUser = solo ? sshUser;
        sshKey = solo ? sshKey;
        publicHostKey = solo ? publicHostKey;
      };
    expected = {
      sshUser = false;
      sshKey = false;
      publicHostKey = false;
    };
  };

  # ── ssh extraConfig: proxyCommand → Host block WITH ProxyCommand ─────
  ssh-proxycommand-block-emitted = {
    expr =
      let
        cfg = (evalNixos [ two.nixos enable ]).config.programs.ssh.extraConfig;
      in
      {
        hasZetaHost = lib.hasInfix "Host zeta-builder-ssm" cfg;
        hasProxy = lib.hasInfix "ProxyCommand cordel builder-wake --config /etc/zeta.yaml %p" cfg;
      };
    expected = {
      hasZetaHost = true;
      hasProxy = true;
    };
  };
  # ── ssh extraConfig: no proxyCommand → block WITHOUT a ProxyCommand ──
  ssh-no-proxycommand-block-plain = {
    expr =
      let
        cfg = (evalNixos [ plain.nixos { nix.rb.enable = true; } ]).config.programs.ssh.extraConfig;
      in
      {
        hasHost = lib.hasInfix "Host solo.example.com" cfg;
        hasProxy = lib.hasInfix "ProxyCommand" cfg;
      };
    expected = {
      hasHost = true;
      hasProxy = false;
    };
  };
  # ── ssh extraConfig: User + IdentityFile lines for the alpha block ──
  ssh-user-and-identityfile-lines = {
    expr =
      let
        cfg = (evalNixos [ two.nixos enable ]).config.programs.ssh.extraConfig;
      in
      {
        host = lib.hasInfix "Host alpha.builder.quero.lol" cfg;
        user = lib.hasInfix "User builder" cfg;
        identity = lib.hasInfix "IdentityFile /run/secrets/builder-key" cfg;
      };
    expected = {
      host = true;
      user = true;
      identity = true;
    };
  };

  # ── disabled: emits nothing into any of the three surfaces ───────────
  disabled-buildmachines-empty = {
    expr = (evalNixos [ two.nixos ]).config.nix.buildMachines;
    expected = [ ];
  };
  disabled-distributedbuilds-false = {
    expr = (evalNixos [ two.nixos ]).config.nix.distributedBuilds;
    expected = false;
  };
  disabled-ssh-extraconfig-empty = {
    expr = (evalNixos [ two.nixos ]).config.programs.ssh.extraConfig;
    expected = "";
  };

  # ── extraOptions land under a custom namespace + are settable ────────
  extra-options-default-and-settable = {
    expr = {
      dflt = (evalNixos [ fancy.nixos { blackmatter.nix.fleet.enable = true; } ]).config.blackmatter.nix.fleet.replicas;
      set = (evalNixos [
        fancy.nixos
        {
          blackmatter.nix.fleet.enable = true;
          blackmatter.nix.fleet.replicas = 7;
        }
      ]).config.blackmatter.nix.fleet.replicas;
    };
    expected = {
      dflt = 3;
      set = 7;
    };
  };

  # ── meta: builderCount + deduped systems + paths + kind ──────────────
  meta-fields = {
    expr = two.meta;
    expected = {
      name = "remote-builders";
      builderCount = 2;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      optionPath = [
        "nix"
        "remote-builders"
      ];
      enablePath = [
        "nix"
        "remote-builders"
        "enable"
      ];
      kind = "remote-builders";
    };
  };
  meta-systems-deduped = {
    # Two builders sharing one system collapse to a single unique entry.
    expr =
      (mkRemoteBuilders {
        builders = {
          a = {
            hostName = "a";
            system = "x86_64-linux";
          };
          b = {
            hostName = "b";
            system = "x86_64-linux";
          };
        };
      }).meta.systems;
    expected = [ "x86_64-linux" ];
  };
}
# ── class tagging: the nixos module is rejected under a darwin eval ──
// iroha.mkModuleEvalCheck {
  name = "remote-builders-nixos-module-under-darwin-class";
  modules = [ two.nixos ];
  class = "darwin";
  universe = [
    (
      { lib, ... }:
      {
        options.nix.buildMachines = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = [ ];
        };
        options.nix.distributedBuilds = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
        options.programs.ssh.extraConfig = lib.mkOption {
          type = lib.types.lines;
          default = "";
        };
        config._module.args.pkgs = { };
      }
    )
  ];
  expectClassReject = true;
}
// {
  # ── typed throws (lazy — force the field that throws) ───────────────
  missing-builders-throws = {
    expr = (builtins.tryEval (mkRemoteBuilders { }).meta.builderCount).success;
    expected = false;
  };
  empty-builders-throws = {
    expr = (builtins.tryEval (mkRemoteBuilders { builders = { }; }).meta.builderCount).success;
    expected = false;
  };
  missing-hostname-throws = {
    # hostName feeds the buildMachines list (lazy) — force the entry's
    # hostName via an eval of the emitted module.
    expr =
      (builtins.tryEval
        (builtins.deepSeq
          (evalNixos [
            (mkRemoteBuilders {
              builders.bad = {
                system = "x86_64-linux";
              };
            }).nixos
            enable
          ]).config.nix.buildMachines
          true
        )
      ).success;
    expected = false;
  };
  missing-system-and-systems-throws = {
    expr =
      (builtins.tryEval
        (builtins.deepSeq
          (evalNixos [
            (mkRemoteBuilders {
              builders.bad = {
                hostName = "h";
              };
            }).nixos
            enable
          ]).config.nix.buildMachines
          true
        )
      ).success;
    expected = false;
  };
  both-system-and-systems-throws = {
    expr =
      (builtins.tryEval
        (builtins.deepSeq
          (evalNixos [
            (mkRemoteBuilders {
              builders.bad = {
                hostName = "h";
                system = "x86_64-linux";
                systems = [ "aarch64-linux" ];
              };
            }).nixos
            enable
          ]).config.nix.buildMachines
          true
        )
      ).success;
    expected = false;
  };
}
