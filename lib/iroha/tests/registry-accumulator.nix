# Tests — iroha.registry-accumulator (typed attrsOf entries -> filtered,
# ordered merge into one sink). Module-emitting letter: eval the emitted
# nixos module against a STUB universe declaring the sink option(s), assert
# the resulting config; cover the synthesized per-entry `enable`, the
# enabled/disabled filtering, the deterministic sorted fold order, the
# custom-`enable`-in-schema path, the disabled-bundle short-circuit, the
# typed per-entry field enforcement (wrong type rejected under evalModules),
# meta, and the typed throws.
{ lib, iroha }:
let
  inherit (iroha) mkRegistryAccumulator;

  # ── stub universe: the SINK options the render writes into ────────────
  # The accumulator declares its OWN options.<ns>.<name> surface; the
  # universe only needs to declare the downstream sink(s) the render folds
  # into (substituters list + a KUBECONFIG-style scalar + a flag attr).
  sinkUniverse =
    { lib, ... }:
    {
      options = {
        nix.settings.substituters = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        environment.variables.KUBECONFIG = lib.mkOption {
          type = lib.types.str;
          default = "";
        };
      };
    };

  stubPkgs = { };

  evalAcc =
    acc: cfgModule:
    lib.evalModules {
      class = "nixos";
      modules = [
        sinkUniverse
        { _module.args.pkgs = stubPkgs; }
        acc.nixos
        cfgModule
      ];
    };

  # ── canonical: binary-caches -> substituters ─────────────────────────
  caches = mkRegistryAccumulator {
    name = "binaryCaches";
    description = "binary cache substituters";
    entry = {
      url = {
        type = "str";
        description = "substituter URL";
      };
    };
    render =
      { enabledEntries, names }:
      {
        nix.settings.substituters = map (n: enabledEntries.${n}.url) names;
      };
  };

  # Three entries: a (enable true), b (enable false), c (enable true).
  cachesCfg = {
    programs.binaryCaches = {
      enable = true;
      entries = {
        a.url = "https://a.cache";
        b = {
          url = "https://b.cache";
          enable = false;
        };
        c.url = "https://c.cache";
      };
    };
  };

  # ── KUBECONFIG: colon-joined scalar sink ─────────────────────────────
  kube = mkRegistryAccumulator {
    name = "kubeconfigs";
    description = "kubeconfig path union";
    entry = {
      path = {
        type = "str";
        description = "kubeconfig path";
      };
    };
    render =
      { enabledEntries, names }:
      {
        environment.variables.KUBECONFIG =
          lib.concatStringsSep ":" (map (n: enabledEntries.${n}.path) names);
      };
  };

  # ── schema declaring its OWN `enable` (must be honored verbatim) ──────
  customEnable = mkRegistryAccumulator {
    name = "feeds";
    description = "feeds with explicit enable default";
    entry = {
      enable = {
        type = "bool";
        default = false; # caller default OFF — overrides the implicit true
      };
      src = {
        type = "str";
      };
    };
    render =
      { names, ... }:
      {
        environment.variables.KUBECONFIG = lib.concatStringsSep "," names;
      };
  };
in
{
  # ── enabled/disabled filtering + sorted fold order ───────────────────
  only-enabled-entries-fold-into-sink-sorted = {
    # b is disabled -> absent; a and c present, sorted by name.
    expr = (evalAcc caches cachesCfg).config.nix.settings.substituters;
    expected = [
      "https://a.cache"
      "https://c.cache"
    ];
  };
  flipping-b-enable-makes-b-appear = {
    expr =
      (evalAcc caches {
        programs.binaryCaches = {
          enable = true;
          entries = {
            a.url = "https://a.cache";
            b.url = "https://b.cache"; # enable now defaults true
            c.url = "https://c.cache";
          };
        };
      }).config.nix.settings.substituters;
    expected = [
      "https://a.cache"
      "https://b.cache"
      "https://c.cache"
    ];
  };
  fold-order-is-sorted-not-authored = {
    # Authored z, m, a — the fold must come out a, m, z (attrNames sorts).
    expr =
      (evalAcc caches {
        programs.binaryCaches = {
          enable = true;
          entries = {
            z.url = "https://z.cache";
            m.url = "https://m.cache";
            a.url = "https://a.cache";
          };
        };
      }).config.nix.settings.substituters;
    expected = [
      "https://a.cache"
      "https://m.cache"
      "https://z.cache"
    ];
  };

  # ── per-entry implicit `enable` ──────────────────────────────────────
  implicit-enable-defaults-true = {
    # Entry with no explicit enable -> participates.
    expr =
      (evalAcc caches {
        programs.binaryCaches = {
          enable = true;
          entries.only.url = "https://only.cache";
        };
      }).config.nix.settings.substituters;
    expected = [ "https://only.cache" ];
  };
  explicit-enable-false-excludes = {
    expr =
      (evalAcc caches {
        programs.binaryCaches = {
          enable = true;
          entries.off = {
            url = "https://off.cache";
            enable = false;
          };
        };
      }).config.nix.settings.substituters;
    expected = [ ];
  };

  # ── disabled bundle short-circuits the whole accumulator ─────────────
  disabled-bundle-leaves-sink-at-default = {
    # cfg.enable = false (the default) -> render never runs, sink stays [].
    expr =
      (evalAcc caches {
        programs.binaryCaches.entries.a.url = "https://a.cache";
      }).config.nix.settings.substituters;
    expected = [ ];
  };
  bundle-enable-defaults-false = {
    expr = (evalAcc caches { }).config.programs.binaryCaches.enable;
    expected = false;
  };

  # ── alternate sink shape: colon-joined scalar ────────────────────────
  kubeconfig-colon-joins-enabled-paths = {
    expr =
      (evalAcc kube {
        programs.kubeconfigs = {
          enable = true;
          entries = {
            prod.path = "/etc/kube/prod";
            dev = {
              path = "/etc/kube/dev";
              enable = false;
            };
            staging.path = "/etc/kube/staging";
          };
        };
      }).config.environment.variables.KUBECONFIG;
    expected = "/etc/kube/prod:/etc/kube/staging";
  };

  # ── caller-declared `enable` honored verbatim (default OFF) ───────────
  custom-enable-schema-default-off-excludes-by-default = {
    # caller set enable default = false; entries without an explicit flip
    # do NOT participate.
    expr =
      (evalAcc customEnable {
        programs.feeds = {
          enable = true;
          entries = {
            x.src = "x";
            y.src = "y";
          };
        };
      }).config.environment.variables.KUBECONFIG;
    expected = "";
  };
  custom-enable-schema-flipped-on-participates = {
    expr =
      (evalAcc customEnable {
        programs.feeds = {
          enable = true;
          entries = {
            x = {
              src = "x";
              enable = true;
            };
            y.src = "y"; # stays default-false
          };
        };
      }).config.environment.variables.KUBECONFIG;
    expected = "x";
  };

  # ── typed per-entry field enforcement ────────────────────────────────
  entry-field-wrong-type-rejected = {
    # url is types.str — assigning an int must fail under evalModules.
    expr =
      (builtins.tryEval
        (evalAcc caches {
          programs.binaryCaches = {
            enable = true;
            entries.bad.url = 42;
          };
        }).config.nix.settings.substituters
      ).success;
    expected = false;
  };
  entry-enable-wrong-type-rejected = {
    # synthesized enable is types.bool — a string must fail.
    expr =
      (builtins.tryEval
        (evalAcc caches {
          programs.binaryCaches = {
            enable = true;
            entries.bad = {
              url = "https://x";
              enable = "yes";
            };
          };
        }).config.nix.settings.substituters
      ).success;
    expected = false;
  };

  # ── meta ─────────────────────────────────────────────────────────────
  meta-fields-exact = {
    expr = caches.meta;
    expected = {
      name = "binaryCaches";
      optionPath = [
        "programs"
        "binaryCaches"
      ];
      entriesPath = [
        "programs"
        "binaryCaches"
        "entries"
      ];
      enablePath = [
        "programs"
        "binaryCaches"
        "enable"
      ];
      kind = "registry-accumulator";
    };
  };
  meta-custom-namespace = {
    expr =
      (mkRegistryAccumulator {
        name = "blocklists";
        description = "edge router blocklists";
        namespace = "blackmatter.components";
        entry.cidr.type = "str";
        render = { ... }: { };
      }).meta.optionPath;
    expected = [
      "blackmatter"
      "components"
      "blocklists"
    ];
  };

  # ── class tagging: the emitted module is nixos-class; a darwin-class
  #    eval REJECTS it (parse-time _class mismatch). ──────────────────────
}
// iroha.mkModuleEvalCheck {
  name = "accumulator-under-darwin-class";
  modules = [ caches.nixos ];
  class = "darwin";
  universe = [
    (
      { lib, ... }:
      {
        options.nix.settings.substituters = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
      }
    )
  ];
  expectClassReject = true;
}
// {
  # ── typed throws (lazy — force the field that throws) ────────────────
  missing-name-throws = {
    expr = (builtins.tryEval (mkRegistryAccumulator { description = "d"; }).meta.name).success;
    expected = false;
  };
  missing-description-throws = {
    # `description` is consumed lazily inside mkEnableOption in the emitted
    # module — force the emitted enable option's description text. The
    # nixos module is core.tag-wrapped: { imports = [ <module> ]; }; pull the
    # inner module out, apply it with a stub config, and reach the option.
    expr =
      (builtins.tryEval (
        let
          acc = mkRegistryAccumulator {
            name = "x";
            entry.u.type = "str";
            render = { ... }: { };
          };
          inner = builtins.head acc.nixos.imports;
          opts = (inner { config = { programs.x = { enable = false; entries = { }; }; }; }).options;
        in
        opts.programs.x.enable.description
      )).success;
    expected = false;
  };
  missing-entry-throws = {
    # `entry`/`render` are validated lazily where they're consumed (inside
    # the emitted module's options/config). Eval against the sink universe
    # with a concrete entry, then deepSeq the merged entry value so the
    # submodule type (which forces `entry` → the throw) is applied.
    expr =
      (builtins.tryEval (builtins.deepSeq
        (evalAcc (mkRegistryAccumulator {
          name = "x";
          description = "d";
          render = { ... }: { };
        }) { programs.x.entries.one = { }; }).config.programs.x.entries
        true
      )).success;
    expected = false;
  };
  entry-non-attrs-throws = {
    expr =
      (builtins.tryEval (builtins.deepSeq
        (evalAcc (mkRegistryAccumulator {
          name = "x";
          description = "d";
          entry = "nope";
          render = { ... }: { };
        }) { programs.x.entries.one = { }; }).config.programs.x.entries
        true
      )).success;
    expected = false;
  };
  missing-render-throws = {
    expr =
      (builtins.tryEval
        (evalAcc (mkRegistryAccumulator {
          name = "x";
          description = "d";
          entry.u.type = "str";
        }) { programs.x.enable = true; }).config.nix.settings.substituters
      ).success;
    expected = false;
  };
  render-non-function-throws = {
    expr =
      (builtins.tryEval
        (evalAcc (mkRegistryAccumulator {
          name = "x";
          description = "d";
          entry.u.type = "str";
          render = { };
        }) { programs.x.enable = true; }).config.nix.settings.substituters
      ).success;
    expected = false;
  };
}
