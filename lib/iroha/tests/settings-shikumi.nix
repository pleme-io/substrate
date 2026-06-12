# Tests — iroha.settings-shikumi (shikumi schema → option-surface fields:
# alias normalization, intRange bounds promotion, default/description/
# min-max carry-through, schemaFile route, mkOptionSurface composition,
# typed throws).
{ lib, iroha }:
let
  inherit (iroha) mkSettingsFromShikumi shikumiTypeToFieldType mkOptionSurface;

  # ── fixture: every alias class the shikumi export emits ──────────────
  fixture = {
    server = {
      host = {
        type = "string";
        default = "0.0.0.0";
        description = "bind address";
      };
      label = {
        type = "str";
        default = "demo";
      };
      # bare u16 → port
      port = {
        type = "u16";
        default = 8080;
      };
      # bounded u16 → intRange (bounds win over the port shorthand)
      nice = {
        type = "u16";
        min = 1024;
        max = 4096;
      };
      # bounded u32 → intRange, default carried
      workers = {
        type = "u32";
        min = 1;
        max = 64;
        default = 8;
      };
      # bare u32/u64 → int
      backlog = {
        type = "u32";
      };
      timeoutMs = {
        type = "u64";
      };
      # bounded int → intRange
      retries = {
        type = "int";
        min = 0;
        max = 10;
      };
      # bare int → int
      maxConn = {
        type = "int";
        default = 128;
      };
    };
    render = {
      vsync = {
        type = "bool";
        default = true;
      };
      hidpi = {
        type = "boolean";
        default = false;
      };
      scale = {
        type = "float";
        default = 1.5;
      };
      # non-integer bounds: carried verbatim, inert (no float-range alias)
      gamma = {
        type = "f64";
        min = 0.5;
        max = 3.0;
      };
      opacity = {
        type = "f32";
      };
    };
    paths = {
      socket = {
        type = "path";
      };
      themeDirs = {
        type = "vec<string>";
        default = [
          "a"
          "b"
        ];
      };
      retryCodes = {
        type = "vec<int>";
      };
      env = {
        type = "map<string,string>";
        description = "extra env";
      };
    };
    conn = {
      # a field literally named `type` — must survive option-surface's
      # group/fieldSpec discriminator downstream.
      type = {
        type = "string";
        default = "tcp";
      };
    };
  };
  fields = mkSettingsFromShikumi {
    name = "demo";
    schema = fixture;
  };

  # ── schemaFile route (JSON fixture via builtins.toFile) ──────────────
  jsonFixture = builtins.toFile "demo-schema.json" (
    builtins.toJSON {
      net = {
        port = {
          type = "u16";
          default = 9090;
        };
        host = {
          type = "string";
          default = "localhost";
        };
      };
    }
  );
  fromFile = mkSettingsFromShikumi {
    name = "demo";
    schemaFile = jsonFixture;
  };

  # ── compose: the result feeds mkOptionSurface unchanged ──────────────
  # Stub pkgs: just enough for the RFC42 settings submodule — zero real
  # nixpkgs, suite stays pure-eval.
  stubPkgs = {
    formats.yaml = _ignored: {
      type = lib.types.attrsOf lib.types.anything;
      generate = n: _v: "generated:" + n;
    };
  };
  surface = mkOptionSurface {
    name = "demo";
    description = "demo tool";
    settings.fields = fields;
  };
  evalDemo =
    cfgModule:
    lib.evalModules {
      modules = [
        { _module.args.pkgs = stubPkgs; }
        surface.module
        cfgModule
      ];
    };
in
{
  # ── alias normalization + carry-through ───────────────────────────────
  alias-str-and-string-normalize = {
    expr = {
      s = fields.server.label.type;
      g = fields.server.host.type;
    };
    expected = {
      s = "str";
      g = "str";
    };
  };
  bare-u16-becomes-port = {
    expr = fields.server.port;
    expected = {
      type = "port";
      default = 8080;
    };
  };
  bounded-u16-becomes-intRange = {
    expr = fields.server.nice;
    expected = {
      type = "intRange";
      min = 1024;
      max = 4096;
    };
  };
  bounded-int-and-u32-become-intRange = {
    expr = {
      w = fields.server.workers;
      r = fields.server.retries;
    };
    expected = {
      w = {
        type = "intRange";
        min = 1;
        max = 64;
        default = 8;
      };
      r = {
        type = "intRange";
        min = 0;
        max = 10;
      };
    };
  };
  bare-int-classes-become-int = {
    expr = {
      b = fields.server.backlog.type;
      t = fields.server.timeoutMs.type;
      m = fields.server.maxConn.type;
    };
    expected = {
      b = "int";
      t = "int";
      m = "int";
    };
  };
  bool-and-boolean-normalize = {
    expr = {
      b = fields.render.vsync;
      n = fields.render.hidpi;
    };
    expected = {
      b = {
        type = "bool";
        default = true;
      };
      n = {
        type = "bool";
        default = false;
      };
    };
  };
  float-aliases-normalize = {
    expr = {
      f = fields.render.scale.type;
      f32 = fields.render.opacity.type;
      f64 = fields.render.gamma.type;
    };
    expected = {
      f = "float";
      f32 = "float";
      f64 = "float";
    };
  };
  non-integer-bounds-carried-inert = {
    expr = fields.render.gamma;
    expected = {
      type = "float";
      min = 0.5;
      max = 3.0;
    };
  };
  path-passes-through = {
    expr = fields.paths.socket;
    expected = {
      type = "path";
    };
  };
  vec-and-map-aliases = {
    expr = {
      vs = fields.paths.themeDirs;
      vi = fields.paths.retryCodes.type;
      m = fields.paths.env;
    };
    expected = {
      vs = {
        type = "listOfStr";
        default = [
          "a"
          "b"
        ];
      };
      vi = "listOfInt";
      m = {
        type = "attrsOfStr";
        description = "extra env";
      };
    };
  };
  default-and-description-carried = {
    expr = fields.server.host;
    expected = {
      type = "str";
      default = "0.0.0.0";
      description = "bind address";
    };
  };

  # ── schemaFile route ──────────────────────────────────────────────────
  schemafile-route-roundtrips = {
    expr = fromFile;
    expected = {
      net = {
        port = {
          type = "port";
          default = 9090;
        };
        host = {
          type = "str";
          default = "localhost";
        };
      };
    };
  };

  # ── composition: result feeds mkOptionSurface + evalModules ──────────
  compose-surface-accepts-typed-value = {
    expr =
      let
        cfg = (evalDemo { programs.demo.settings.server.port = 1234; }).config.programs.demo.settings;
      in
      {
        port = cfg.server.port;
        # group defaults flow through unchanged
        vsync = cfg.render.vsync;
        workers = cfg.server.workers;
        # the field literally named `type` lands as a typed group member
        connType = cfg.conn.type;
      };
    expected = {
      port = 1234;
      vsync = true;
      workers = 8;
      connType = "tcp";
    };
  };
  compose-surface-rejects-wrong-type = {
    expr = {
      island =
        (builtins.tryEval
          (evalDemo { programs.demo.settings.server.port = "nope"; }).config.programs.demo.settings.server.port
        ).success;
      # intRange bounds enforced by the module system: 100 > max 64
      range =
        (builtins.tryEval
          (evalDemo { programs.demo.settings.server.workers = 100; }).config.programs.demo.settings.server.workers
        ).success;
    };
    expected = {
      island = false;
      range = false;
    };
  };

  # ── shikumiTypeToFieldType (the pure mapping) ─────────────────────────
  type-mapper-pure-mapping = {
    expr = {
      s = shikumiTypeToFieldType "string";
      p = shikumiTypeToFieldType "u16";
      ints = lib.unique (
        map (t: (shikumiTypeToFieldType t).type) [
          "u32"
          "u64"
          "i32"
          "i64"
          "usize"
        ]
      );
    };
    expected = {
      s = {
        type = "str";
      };
      p = {
        type = "port";
      };
      ints = [ "int" ];
    };
  };
  type-mapper-unknown-throws = {
    expr = (builtins.tryEval (shikumiTypeToFieldType "complex128").type).success;
    expected = false;
  };

  # ── typed throws ──────────────────────────────────────────────────────
  unknown-type-throws-naming-path = {
    # mapAttrs is lazy — force the converted field to surface the throw.
    expr =
      (builtins.tryEval
        (mkSettingsFromShikumi {
          name = "bad";
          schema.grp.fld = {
            type = "complex128";
          };
        }).grp.fld.type
      ).success;
    expected = false;
  };
  field-missing-type-throws = {
    expr =
      (builtins.tryEval
        (mkSettingsFromShikumi {
          name = "bad";
          schema.grp.fld = {
            default = 1;
          };
        }).grp.fld.type
      ).success;
    expected = false;
  };
  group-not-attrset-throws = {
    expr =
      (builtins.tryEval
        (mkSettingsFromShikumi {
          name = "bad";
          schema.grp = 42;
        }).grp
      ).success;
    expected = false;
  };
  schema-not-attrset-throws = {
    expr =
      (builtins.tryEval (
        builtins.attrNames (mkSettingsFromShikumi {
          name = "bad";
          schema = "nope";
        })
      )).success;
    expected = false;
  };
  both-schema-and-schemafile-throws = {
    expr =
      (builtins.tryEval (
        builtins.attrNames (mkSettingsFromShikumi {
          name = "x";
          schema = { };
          schemaFile = "/nonexistent.json";
        })
      )).success;
    expected = false;
  };
  neither-schema-nor-schemafile-throws = {
    expr = (builtins.tryEval (builtins.attrNames (mkSettingsFromShikumi { name = "x"; }))).success;
    expected = false;
  };
  name-missing-throws = {
    expr = (builtins.tryEval (builtins.attrNames (mkSettingsFromShikumi { schema = fixture; }))).success;
    expected = false;
  };
}
