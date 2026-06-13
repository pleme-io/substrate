# Tests — iroha.config-owner (mkConfigOwner: a single typed owner of a
# contended config region — owned leaves banded at a HIGH priority so the
# owner wins over plain competitors; band arithmetic proven against both a
# stronger owner and a deliberately weaker one; assertions; class tagging;
# typed throws).
{ lib, iroha }:
let
  inherit (iroha) mkConfigOwner;

  # ── stub option universe with CONTENDED leaves ───────────────────────
  # nix.settings.post-build-hook :: str — the canonical contended leaf a
  # competitor module also sets at plain priority. A nested attrsOf surface
  # (boot.kernel.sysctl) for the sysctl-override collision case. An
  # arbitrary numeric leaf (system.k) to prove weak-band loses to a node.
  # assertions option so resolved assertions land somewhere typed.
  nixosUniverse =
    { lib, ... }:
    {
      options = {
        nix.settings.post-build-hook = lib.mkOption {
          type = lib.types.str;
          default = "";
        };
        boot.kernel.sysctl = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        system.k = lib.mkOption {
          type = lib.types.int;
          default = 0;
        };
        assertions = lib.mkOption {
          type = lib.types.listOf lib.types.attrs;
          default = [ ];
        };
      };
    };
  darwinUniverse =
    { lib, ... }:
    {
      options = {
        nix.settings.post-build-hook = lib.mkOption {
          type = lib.types.str;
          default = "";
        };
        assertions = lib.mkOption {
          type = lib.types.listOf lib.types.attrs;
          default = [ ];
        };
      };
    };

  # A competitor module setting the contended leaf at PLAIN (node) priority.
  competitor = { nix.settings.post-build-hook = "/competitor/hook"; };

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

  enable = { system.nix-hook-owner.enable = true; };

  # ── specs under test ─────────────────────────────────────────────────
  # Canonical: owns the post-build-hook at the default "force" band, so it
  # beats the plain competitor. Carries an assertion.
  owner = mkConfigOwner {
    name = "nix-hook-owner";
    description = "authoritative owner of nix.settings.post-build-hook";
    owns = {
      nix.settings.post-build-hook = "/owned/hook";
    };
    assertions = [
      {
        assertion = true;
        message = "post-build-hook region must be singly-owned";
      }
    ];
  };

  # Weak band: "role" (== mkDefault) deliberately LOSES to a node-plain def.
  weakOwner = mkConfigOwner {
    name = "weak-owner";
    description = "weak owner";
    band = "role";
    owns = {
      system.k = 10;
    };
  };

  # _type-tagged leaf in owns: passes through un-rebanded (the leaf keeps
  # its own mkForce; band-wrapping does not double-wrap it).
  pretagged = mkConfigOwner {
    name = "pretag-owner";
    description = "pretagged owner";
    band = "role"; # weak default band, but the leaf is already mkForce
    owns = {
      nix.settings.post-build-hook = lib.mkForce "/pretagged/hook";
    };
  };

  # extraOptions + custom namespace + custom int band.
  fancy = mkConfigOwner {
    name = "sysctl-owner";
    description = "sysctl region owner";
    namespace = "blackmatter.system";
    band = 50; # raw int (== force)
    extraOptions = l: {
      replicas = l.mkOption {
        type = l.types.int;
        default = 2;
      };
    };
    owns = {
      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    };
  };

  # Predicate assertion (config -> bool): resolved inside config.
  predOwner = mkConfigOwner {
    name = "pred-owner";
    description = "predicate owner";
    owns = {
      system.k = 7;
    };
    assertions = [
      {
        assertion = config: config.system.k == 7;
        message = "system.k must be the owned value";
      }
    ];
  };
in
{
  # ── owner WINS: force-banded owned value beats the plain competitor ──
  owner-wins-over-competitor = {
    expr =
      (evalNixos [
        owner.nixos
        enable
        competitor
      ]).config.nix.settings.post-build-hook;
    expected = "/owned/hook";
  };

  # ── owner alone sets the owned value ─────────────────────────────────
  owner-sets-owned-value = {
    expr = (evalNixos [ owner.nixos enable ]).config.nix.settings.post-build-hook;
    expected = "/owned/hook";
  };

  # ── weak band ("role"/mkDefault) LOSES to a node-plain def ───────────
  weak-band-loses-to-node = {
    expr =
      (evalNixos [
        weakOwner.nixos
        { system.weak-owner.enable = true; }
        { system.k = 99; } # plain node def beats role band
      ]).config.system.k;
    expected = 99;
  };

  # ── weak band still applies when uncontended (proves it set, not noop) ─
  weak-band-applies-uncontended = {
    expr =
      (evalNixos [
        weakOwner.nixos
        { system.weak-owner.enable = true; }
      ]).config.system.k;
    expected = 10;
  };

  # ── _type-tagged leaf passes through un-rebanded (still wins as mkForce) ─
  pretagged-leaf-passes-through = {
    expr =
      (evalNixos [
        pretagged.nixos
        { system.pretag-owner.enable = true; }
        competitor # plain def — the pretagged mkForce still beats it
      ]).config.nix.settings.post-build-hook;
    expected = "/pretagged/hook";
  };

  # ── assertions land in config.assertions when enabled ────────────────
  assertions-land-when-enabled = {
    expr = (evalNixos [ owner.nixos enable ]).config.assertions;
    expected = [
      {
        assertion = true;
        message = "post-build-hook region must be singly-owned";
      }
    ];
  };

  # ── predicate assertion resolves against config ──────────────────────
  predicate-assertion-resolves = {
    expr =
      (evalNixos [
        predOwner.nixos
        { system.pred-owner.enable = true; }
      ]).config.assertions;
    expected = [
      {
        assertion = true;
        message = "system.k must be the owned value";
      }
    ];
  };

  # ── disabled: owned value ABSENT (default) + no assertions ───────────
  disabled-owned-absent = {
    expr = (evalNixos [ owner.nixos ]).config.nix.settings.post-build-hook;
    expected = "";
  };
  disabled-no-assertions = {
    expr = (evalNixos [ owner.nixos ]).config.assertions;
    expected = [ ];
  };

  # ── extraOptions land + are settable; custom namespace ───────────────
  extra-options-default-and-settable = {
    expr = {
      dflt = (evalNixos [ fancy.nixos { blackmatter.system.sysctl-owner.enable = true; } ]).config.blackmatter.system.sysctl-owner.replicas;
      set = (evalNixos [
        fancy.nixos
        {
          blackmatter.system.sysctl-owner.enable = true;
          blackmatter.system.sysctl-owner.replicas = 5;
        }
      ]).config.blackmatter.system.sysctl-owner.replicas;
    };
    expected = {
      dflt = 2;
      set = 5;
    };
  };

  # ── int band owns a nested attrsOf leaf ──────────────────────────────
  int-band-owns-nested-sysctl = {
    expr =
      (evalNixos [
        fancy.nixos
        { blackmatter.system.sysctl-owner.enable = true; }
      ]).config.boot.kernel.sysctl."net.ipv4.ip_forward";
    expected = 1;
  };

  # ── meta carries the resolved band + paths + kind ────────────────────
  meta-fields = {
    expr = fancy.meta;
    expected = {
      name = "sysctl-owner";
      kind = "config-owner";
      band = 50;
      optionPath = [
        "blackmatter"
        "system"
        "sysctl-owner"
      ];
      enablePath = [
        "blackmatter"
        "system"
        "sysctl-owner"
        "enable"
      ];
    };
  };
  meta-band-name-preserved = {
    expr = weakOwner.meta.band;
    expected = "role";
  };

  # ── darwin projection sets the owned value the same way ──────────────
  darwin-owner-wins = {
    expr =
      (evalDarwin [
        owner.darwin
        enable
        competitor
      ]).config.nix.settings.post-build-hook;
    expected = "/owned/hook";
  };
  darwin-disabled-owned-absent = {
    expr = (evalDarwin [ owner.darwin ]).config.nix.settings.post-build-hook;
    expected = "";
  };

  # ── class tagging: the nixos module is rejected under a darwin eval ──
}
// iroha.mkModuleEvalCheck {
  name = "config-owner-nixos-module-under-darwin-class";
  modules = [ owner.nixos ];
  class = "darwin";
  universe = [
    (
      { lib, ... }:
      {
        options.nix.settings.post-build-hook = lib.mkOption {
          type = lib.types.str;
          default = "";
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
        (mkConfigOwner {
          description = "d";
          owns = { };
        }).meta.name
      ).success;
    expected = false;
  };
  missing-owns-throws = {
    expr =
      (builtins.tryEval
        (mkConfigOwner {
          name = "x";
          description = "d";
        }).meta.kind
      ).success;
    expected = false;
  };
  owns-not-attrs-throws = {
    expr =
      (builtins.tryEval
        (mkConfigOwner {
          name = "x";
          description = "d";
          owns = "nope";
        }).meta.kind
      ).success;
    expected = false;
  };
  unknown-band-throws = {
    expr =
      (builtins.tryEval
        (mkConfigOwner {
          name = "x";
          description = "d";
          band = "bogus";
          owns = { };
        }).meta.band
      ).success;
    expected = false;
  };
  bad-assertion-entry-throws = {
    # assertion entry missing `message` — surfaced when assertions force
    # inside config (force config.assertions via an enabled eval).
    expr =
      (builtins.tryEval
        (builtins.deepSeq
          (evalNixos [
            (mkConfigOwner {
              name = "bad";
              description = "d";
              owns = { };
              assertions = [ { assertion = true; } ];
            }).nixos
            { system.bad.enable = true; }
          ]).config.assertions
          true)
      ).success;
    expected = false;
  };
}
