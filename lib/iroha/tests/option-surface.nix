# Tests — iroha.option-surface (paths, package option lazy/eager, RFC42
# settings submodule with typed islands + groups + freeform, packageFor,
# render, extra, typed throws).
{ lib, iroha }:
let
  inherit (iroha) mkOptionSurface;

  # Stub pkgs: just enough surface for the settings option (pkgs.formats)
  # and package resolution — zero real nixpkgs.
  fakeDrv = name: {
    type = "derivation";
    inherit name;
  };
  stubPkgs = {
    formats.yaml = _ignored: {
      type = lib.types.attrsOf lib.types.anything;
      generate = n: v: "generated:" + n;
    };
    demo = fakeDrv "demo-from-pkgs";
    demoPkg = fakeDrv "demoPkg";
  };

  modArgs = {
    inherit lib;
    pkgs = stubPkgs;
    config = { };
  };

  # ── canonical surface: enable + lazy package + settings ─────────────
  demo = mkOptionSurface {
    name = "demo";
    description = "demo tool";
    settings = {
      fields = {
        port = {
          type = "port";
          default = 8080;
          description = "listen port";
        };
        ui = {
          theme = {
            type = "str";
            default = "nord";
          };
        };
      };
      defaults = {
        log = {
          level = "info";
          format = "json";
        };
      };
    };
  };
  demoOpts = (demo.module modArgs).options.programs.demo;

  evalDemo =
    cfgModule:
    lib.evalModules {
      modules = [
        { _module.args.pkgs = stubPkgs; }
        demo.module
        cfgModule
      ];
    };

  # ── variant surfaces ────────────────────────────────────────────────
  customNs = mkOptionSurface {
    name = "vigy";
    description = "vigy daemon";
    namespace = "blackmatter.components";
    optionName = "vigyTool";
  };

  eager = mkOptionSurface {
    name = "demo";
    description = "demo tool";
    package = {
      attr = "demoPkg";
      lazy = false;
    };
  };
  eagerOpts = (eager.module modArgs).options.programs.demo;

  noPkg = mkOptionSurface {
    name = "bare";
    description = "no package";
    package = false;
  };
  noPkgOpts = (noPkg.module modArgs).options.programs.bare;

  noEnable = mkOptionSurface {
    name = "quiet";
    description = "no enable";
    enable = false;
  };
  noEnableOpts = (noEnable.module modArgs).options.programs.quiet;

  dashed = mkOptionSurface {
    name = "my-app";
    description = "dashed name";
    settings = { };
  };

  tomlSurface = mkOptionSurface {
    name = "cfg";
    description = "toml settings";
    settings.format = "toml";
  };

  withExtra = mkOptionSurface {
    name = "extras";
    description = "extra options";
    extra = l: {
      banner = l.mkOption {
        type = l.types.str;
        default = "hi";
      };
    };
  };
in
{
  # ── paths ────────────────────────────────────────────────────────────
  option-path-and-enable-path-defaults = {
    expr = {
      o = demo.optionPath;
      e = demo.enablePath;
    };
    expected = {
      o = [ "programs" "demo" ];
      e = [ "programs" "demo" "enable" ];
    };
  };
  option-path-custom-namespace-and-name = {
    expr = {
      o = customNs.optionPath;
      e = customNs.enablePath;
    };
    expected = {
      o = [ "blackmatter" "components" "vigyTool" ];
      e = [ "blackmatter" "components" "vigyTool" "enable" ];
    };
  };

  # ── package spec + option ────────────────────────────────────────────
  package-spec-defaults = {
    expr = demo.packageSpec;
    expected = {
      attr = "demo";
      lazy = true;
    };
  };
  package-false-omits-spec-and-option = {
    expr = {
      spec = noPkg.packageSpec;
      hasOpt = noPkgOpts ? package;
    };
    expected = {
      spec = null;
      hasOpt = false;
    };
  };
  lazy-package-option-null-default-and-defaultText = {
    expr = {
      d = demoOpts.package.default;
      t = demoOpts.package.defaultText.text;
    };
    expected = {
      d = null;
      t = "pkgs.demo";
    };
  };
  eager-package-option-defaultText-and-default = {
    expr = {
      t = eagerOpts.package.defaultText.text;
      n = eagerOpts.package.default.name;
    };
    expected = {
      t = "pkgs.demoPkg";
      n = "demoPkg";
    };
  };

  # ── settings spec normalization ──────────────────────────────────────
  settings-spec-null-by-default = {
    expr = noPkg.settingsSpec;
    expected = null;
  };
  settings-spec-defaults-filled = {
    expr = dashed.settingsSpec;
    expected = {
      format = "yaml";
      ext = "yaml";
      relPath = ".config/my-app/my-app.yaml";
      envVar = "MY_APP_CONFIG";
      fields = { };
      defaults = { };
    };
  };
  settings-format-toml = {
    expr = {
      f = tomlSurface.settingsSpec.format;
      e = tomlSurface.settingsSpec.ext;
      p = tomlSurface.settingsSpec.relPath;
    };
    expected = {
      f = "toml";
      e = "toml";
      p = ".config/cfg/cfg.toml";
    };
  };
  settings-format-unknown-throws = {
    expr =
      (builtins.tryEval
        (mkOptionSurface {
          name = "x";
          description = "d";
          settings.format = "ini";
        }).settingsSpec.relPath
      ).success;
    expected = false;
  };

  # ── module: enable + settings submodule semantics ────────────────────
  enable-option-default-and-omission = {
    expr = {
      dflt = (evalDemo { }).config.programs.demo.enable;
      absent = noEnableOpts ? enable;
      present = demoOpts ? enable;
    };
    expected = {
      dflt = false;
      absent = false;
      present = true;
    };
  };
  typed-island-and-freeform-accepted = {
    expr =
      let
        cfg =
          (evalDemo {
            programs.demo.settings.port = 1234;
            programs.demo.settings.arbitraryKey = "zzz";
          }).config.programs.demo.settings;
      in
      {
        port = cfg.port;
        free = cfg.arbitraryKey;
      };
    expected = {
      port = 1234;
      free = "zzz";
    };
  };
  grouped-field-lands-typed = {
    expr = {
      dflt = (evalDemo { }).config.programs.demo.settings.ui.theme;
      set = (evalDemo { programs.demo.settings.ui.theme = "dracula"; }).config.programs.demo.settings.ui.theme;
    };
    expected = {
      dflt = "nord";
      set = "dracula";
    };
  };
  group-with-member-field-named-type-detected-as-group = {
    # A config schema commonly has a field literally named `type`
    # (connection.type = "tcp"). The fieldSpec/group discriminator must
    # not mistake the GROUP for a fieldSpec just because it has a `type`
    # key — only a string alias or raw lib.types.* value marks a fieldSpec.
    expr =
      let
        s = mkOptionSurface {
          name = "conn";
          description = "d";
          settings.fields.connection = {
            type = {
              type = "str";
              default = "tcp";
            };
            host = {
              type = "str";
              default = "localhost";
            };
          };
        };
        cfg =
          (lib.evalModules {
            modules = [
              { _module.args.pkgs = stubPkgs; }
              s.module
              { programs.conn.enable = true; }
            ];
          }).config.programs.conn.settings.connection;
      in
      {
        inherit (cfg) type host;
      };
    expected = {
      type = "tcp";
      host = "localhost";
    };
  };
  wrong-type-rejected-island-and-group = {
    expr = {
      island =
        (builtins.tryEval (evalDemo { programs.demo.settings.port = "nope"; }).config.programs.demo.settings.port)
        .success;
      group =
        (builtins.tryEval (evalDemo { programs.demo.settings.ui.theme = 42; }).config.programs.demo.settings.ui.theme)
        .success;
    };
    expected = {
      island = false;
      group = false;
    };
  };
  extra-function-receives-lib-and-lands = {
    expr =
      (lib.evalModules {
        modules = [
          { _module.args.pkgs = stubPkgs; }
          withExtra.module
        ];
      }).config.programs.extras.banner;
    expected = "hi";
  };

  # ── packageFor ───────────────────────────────────────────────────────
  packageFor-prefers-cfg-package = {
    expr =
      (demo.packageFor {
        cfg = {
          package = fakeDrv "override";
        };
        pkgs = stubPkgs;
      }).name;
    expected = "override";
  };
  packageFor-falls-back-to-pkgs-attr = {
    expr = {
      nullPkg =
        (demo.packageFor {
          cfg = {
            package = null;
          };
          pkgs = stubPkgs;
        }).name;
      noKey =
        (demo.packageFor {
          cfg = { };
          pkgs = stubPkgs;
        }).name;
    };
    expected = {
      nullPkg = "demo-from-pkgs";
      noKey = "demo-from-pkgs";
    };
  };
  packageFor-throws-typed = {
    expr = {
      falseSurface =
        (builtins.tryEval (noPkg.packageFor {
          cfg = { };
          pkgs = { };
        })).success;
      missingAttr =
        (builtins.tryEval (demo.packageFor {
          cfg = { };
          pkgs = {
            inherit (stubPkgs) formats;
          };
        })).success;
    };
    expected = {
      falseSurface = false;
      missingAttr = false;
    };
  };

  # ── render ───────────────────────────────────────────────────────────
  render-null-when-no-settings = {
    expr = noPkg.render {
      cfg = { };
      pkgs = stubPkgs;
    };
    expected = null;
  };
  render-merges-defaults-under-user = {
    expr = demo.render {
      cfg = {
        settings = {
          log.level = "debug";
        };
      };
      pkgs = stubPkgs;
    };
    expected = {
      relPath = ".config/demo/demo.yaml";
      envVar = "DEMO_CONFIG";
      value = {
        log = {
          level = "debug";
          format = "json";
        };
      };
      source = "generated:demo.yaml";
    };
  };
  render-unset-nullOr-island-absent-not-null = {
    # The silent whole-config-fallback class: an unset nullOr island
    # (default null) — and any authored explicit null — must be ABSENT
    # from the rendered value, never `null`. Shikumi extraction
    # (figment + serde) is atomic: one explicit null on a non-Option
    # Rust field fails the WHOLE extraction and the app silently falls
    # back to full prescribed defaults (proven live via tobira's
    # `accent_color: null`). The non-null sibling must survive.
    expr =
      let
        s = mkOptionSurface {
          name = "nully";
          description = "d";
          settings.fields = {
            accent = {
              type = "nullOrStr";
              default = null;
            };
            width = {
              type = "int";
              default = 560;
            };
          };
        };
        cfg =
          (lib.evalModules {
            modules = [
              { _module.args.pkgs = stubPkgs; }
              s.module
              { programs.nully.settings.authoredNull = null; }
            ];
          }).config.programs.nully;
        r = s.render {
          inherit cfg;
          pkgs = stubPkgs;
        };
      in
      {
        hasAccent = r.value ? accent;
        hasAuthoredNull = r.value ? authoredNull;
        width = r.value.width;
      };
    expected = {
      hasAccent = false;
      hasAuthoredNull = false;
      width = 560;
    };
  };
  render-full-pipeline-from-eval = {
    expr =
      let
        r = demo.render {
          cfg = (evalDemo { programs.demo.settings.arbitraryKey = "zzz"; }).config.programs.demo;
          pkgs = stubPkgs;
        };
      in
      {
        port = r.value.port;
        theme = r.value.ui.theme;
        level = r.value.log.level;
        free = r.value.arbitraryKey;
        src = r.source;
      };
    expected = {
      port = 8080;
      theme = "nord";
      level = "info";
      free = "zzz";
      src = "generated:demo.yaml";
    };
  };

  # ── typed throws ─────────────────────────────────────────────────────
  name-missing-throws = {
    expr =
      (builtins.tryEval (builtins.concatStringsSep "." (mkOptionSurface { description = "d"; }).optionPath))
      .success;
    expected = false;
  };
  description-missing-throws = {
    # mkEnableOption is LAZY — force the description field that interpolates.
    expr =
      (builtins.tryEval ((mkOptionSurface { name = "x"; }).module modArgs).options.programs.x.enable.description)
      .success;
    expected = false;
  };
  package-bad-shape-throws = {
    expr =
      (builtins.tryEval
        (mkOptionSurface {
          name = "x";
          description = "d";
          package = "yes";
        }).packageSpec
      ).success;
    expected = false;
  };
  extra-bad-shape-throws = {
    # extraAttrs is merged lazily into the option body — force the body.
    expr =
      (builtins.tryEval (
        builtins.attrNames
          ((mkOptionSurface {
            name = "bad";
            description = "d";
            extra = 42;
          }).module modArgs).options.programs.bad
      )).success;
    expected = false;
  };
}
