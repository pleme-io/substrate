# Tests — iroha.service-bundle (mkServiceBundle: bundle enable gates the
# whole curated set; per-feature enable defaults + gating; mkMerge of
# multiple features over services.*; per-feature extra options flowing into
# config; class tagging; meta; typed throws).
{ lib, iroha }:
let
  inherit (iroha) mkServiceBundle;

  # ── stub universe ───────────────────────────────────────────────────
  # Declare the option root the bundle owns plus the upstream services.*
  # paths its features render into — all attrsOf anything so any fragment
  # shape lands. NOTE: enable bools (cfg.<feature>.enable) are declared by
  # the bundle module itself; the universe only needs the rendered targets.
  servicesUniverse = {
    options.services.foo = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
    options.services.bar = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
  };

  # ── canonical bundle: feature A default-on, feature B default-off ────
  bundle = mkServiceBundle {
    name = "home-media";
    description = "home media services";
    features = {
      foo = {
        description = "the foo service";
        default = true;
        config = cfg: {
          services.foo = {
            enable = true;
            port = cfg.port;
          };
        };
        options = {
          port = lib.mkOption {
            type = lib.types.int;
            default = 8080;
          };
        };
      };
      bar = {
        # description defaults to feature name; default-off.
        config = _cfg: {
          services.bar.enable = true;
        };
      };
    };
  };

  evalBundle =
    cfgModule:
    lib.evalModules {
      class = "nixos";
      modules = [
        servicesUniverse
        bundle.nixos
        cfgModule
      ];
    };

  # ── custom-namespace bundle (introspection only) ────────────────────
  nsBundle = mkServiceBundle {
    name = "stack";
    description = "ns stack";
    namespace = "blackmatter.components";
    features.only = {
      config = _: { };
    };
  };
in
{
  # ── bundle disabled -> nothing rendered ─────────────────────────────
  disabled-bundle-renders-nothing = {
    expr =
      let
        c = (evalBundle { }).config.services;
      in
      {
        foo = c.foo;
        bar = c.bar;
      };
    expected = {
      foo = { };
      bar = { };
    };
  };

  # ── enabled bundle, feature A default-true -> A rendered ────────────
  enabled-bundle-default-on-feature-renders = {
    expr =
      let
        c = (evalBundle { services.home-media.enable = true; }).config.services.foo;
      in
      {
        inherit (c) enable port;
      };
    expected = {
      enable = true;
      port = 8080;
    };
  };

  # ── feature B default-false -> absent until flipped ─────────────────
  enabled-bundle-default-off-feature-absent = {
    expr = (evalBundle { services.home-media.enable = true; }).config.services.bar;
    expected = { };
  };

  # ── flipping B.enable -> B rendered AND merges with A ───────────────
  flipping-feature-renders-and-merges-with-a = {
    expr =
      let
        c =
          (evalBundle {
            services.home-media.enable = true;
            services.home-media.bar.enable = true;
          }).config.services;
      in
      {
        fooEnable = c.foo.enable;
        barEnable = c.bar.enable;
      };
    expected = {
      fooEnable = true;
      barEnable = true;
    };
  };

  # ── disabling a default-on feature drops it even with bundle on ─────
  disabling-default-on-feature-drops-it = {
    expr =
      (evalBundle {
        services.home-media.enable = true;
        services.home-media.foo.enable = false;
      }).config.services.foo;
    expected = { };
  };

  # ── per-feature extra option default + override flow into config ────
  feature-extra-option-default-flows-into-config = {
    expr = (evalBundle { services.home-media.enable = true; }).config.services.foo.port;
    expected = 8080;
  };
  feature-extra-option-override-flows-into-config = {
    expr =
      (evalBundle {
        services.home-media.enable = true;
        services.home-media.foo.port = 9999;
      }).config.services.foo.port;
    expected = 9999;
  };

  # ── per-feature enable option carries its default ───────────────────
  # default-on without any node override: feature A renders (default=true),
  # feature B does not (default=false). Proves the enable defaults flow.
  feature-enable-defaults-from-spec = {
    expr =
      let
        c = (evalBundle { services.home-media.enable = true; }).config.services;
      in
      {
        fooRendered = c.foo.enable or false;
        barRendered = c.bar.enable or false;
      };
    expected = {
      fooRendered = true; # foo default-on -> rendered
      barRendered = false; # bar default-off -> absent (no enable key)
    };
  };

  # ── feature description defaults to feature name ────────────────────
  # mkEnableOption wraps the label as "Whether to enable <label>." — the
  # default label IS the feature name, so the rendered description proves
  # the default flowed through.
  feature-description-defaults-to-name = {
    expr = (evalBundle { }).options.services.home-media.bar.enable.description;
    expected = "Whether to enable bar.";
  };
  feature-description-custom-flows = {
    expr = (evalBundle { }).options.services.home-media.foo.enable.description;
    expected = "Whether to enable the foo service.";
  };

  # ── class tagging: bundle module is nixos-tagged ────────────────────
  module-is-nixos-class-tagged = {
    expr = bundle.nixos._class;
    expected = "nixos";
  };
  bundle-rejected-under-darwin-class = {
    expr =
      (builtins.tryEval (
        builtins.seq
          (lib.evalModules {
            class = "darwin";
            modules = [
              servicesUniverse
              bundle.nixos
            ];
          }).config.services
          true
      )).success;
    expected = false;
  };

  # ── meta ────────────────────────────────────────────────────────────
  meta-shape = {
    expr = bundle.meta;
    expected = {
      name = "home-media";
      optionPath = [
        "services"
        "home-media"
      ];
      features = [
        "bar"
        "foo"
      ];
      kind = "service-bundle";
    };
  };
  meta-custom-namespace-option-path = {
    expr = nsBundle.meta.optionPath;
    expected = [
      "blackmatter"
      "components"
      "stack"
    ];
  };

  # ── typed throws ────────────────────────────────────────────────────
  name-missing-throws = {
    expr = (builtins.tryEval (mkServiceBundle { description = "d"; }).meta.name).success;
    expected = false;
  };
  description-missing-throws = {
    expr =
      (builtins.tryEval
        (mkServiceBundle {
          name = "x";
          features.a.config = _: { };
        }).nixos._class
      ).success;
    expected = false;
  };
  features-missing-throws = {
    expr =
      (builtins.tryEval (mkServiceBundle {
        name = "x";
        description = "d";
      }).meta.features).success;
    expected = false;
  };
  empty-features-throws = {
    expr =
      (builtins.tryEval (mkServiceBundle {
        name = "x";
        description = "d";
        features = { };
      }).meta.features).success;
    expected = false;
  };
  non-attrs-features-throws = {
    expr =
      (builtins.tryEval (mkServiceBundle {
        name = "x";
        description = "d";
        features = [ ];
      }).meta.features).success;
    expected = false;
  };
  feature-missing-config-throws = {
    expr =
      (builtins.tryEval
        (mkServiceBundle {
          name = "x";
          description = "d";
          features.a = { default = true; };
        }).nixos._class
      ).success;
    expected = false;
  };
  feature-config-not-function-throws = {
    expr =
      (builtins.tryEval
        (mkServiceBundle {
          name = "x";
          description = "d";
          features.a.config = { not = "a function"; };
        }).nixos._class
      ).success;
    expected = false;
  };
  feature-options-not-attrs-throws = {
    expr =
      (builtins.tryEval
        (mkServiceBundle {
          name = "x";
          description = "d";
          features.a = {
            config = _: { };
            options = 42;
          };
        }).nixos._class
      ).success;
    expected = false;
  };
}
