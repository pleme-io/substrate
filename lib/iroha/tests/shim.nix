# Tests — iroha.shim (deprecation shims: renames, removals, aliases).
{ lib, iroha }:
let
  inherit (iroha) mkDeprecationShim mkEnableAlias;

  # Minimal option universe: mkRenamedOptionModule emits through `warnings`,
  # mkRemovedOptionModule asserts through `assertions` — stub both (the real
  # NixOS/darwin/HM universes all declare them).
  universe = {
    options.warnings = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    options.assertions = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
    };
  };

  newOpt = {
    options.new.opt = lib.mkOption {
      type = lib.types.int;
      default = 0;
    };
  };

  # ── renames ─────────────────────────────────────────────────────────
  renameShim = mkDeprecationShim {
    renames = [
      {
        from = "old.opt";
        to = "new.opt";
      }
    ];
  };
  renameEval = lib.evalModules {
    modules = [
      universe
      newOpt
      renameShim
      { old.opt = 5; }
    ];
  };
  renameUnsetEval = lib.evalModules {
    modules = [
      universe
      newOpt
      renameShim
    ];
  };
  renameListEval = lib.evalModules {
    modules = [
      universe
      newOpt
      (mkDeprecationShim {
        renames = [
          {
            from = [
              "old"
              "opt"
            ];
            to = [
              "new"
              "opt"
            ];
          }
        ];
      })
      { old.opt = 6; }
    ];
  };

  # ── aliases ─────────────────────────────────────────────────────────
  aliasEval = lib.evalModules {
    modules = [
      universe
      newOpt
      (mkDeprecationShim {
        aliases = [
          {
            from = "old.opt";
            to = "new.opt";
          }
        ];
      })
      { old.opt = 7; }
    ];
  };

  # ── removed ─────────────────────────────────────────────────────────
  removedShim = mkDeprecationShim {
    removed = [
      {
        path = "old.gone";
        reason = "gone since v2 — use new.opt instead.";
      }
    ];
  };
  removedSetEval = lib.evalModules {
    modules = [
      universe
      newOpt
      removedShim
      { old.gone = 1; }
    ];
  };
  removedUnsetEval = lib.evalModules {
    modules = [
      universe
      newOpt
      removedShim
    ];
  };

  # ── for-tagging (class gate) ────────────────────────────────────────
  hmShim = mkDeprecationShim {
    for = "homeManager";
    renames = [
      {
        from = "old.opt";
        to = "new.opt";
      }
    ];
  };
  hmRejected = builtins.tryEval (
    builtins.seq
      (lib.evalModules {
        class = "nixos";
        modules = [
          universe
          newOpt
          hmShim
          { old.opt = 5; }
        ];
      }).config.new.opt
      true
  );
  hmAccepted = builtins.tryEval (
    (lib.evalModules {
      class = "homeManager";
      modules = [
        universe
        newOpt
        hmShim
        { old.opt = 5; }
      ];
    }).config.new.opt
  );

  # ── mkEnableAlias ───────────────────────────────────────────────────
  enableDecl = {
    options.features.foo.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };
  enableEval = lib.evalModules {
    modules = [
      universe
      enableDecl
      (mkEnableAlias {
        old = "presets.foo.enable";
        new = "features.foo.enable";
      })
      { presets.foo.enable = true; }
    ];
  };
  enableListEval = lib.evalModules {
    modules = [
      universe
      enableDecl
      (mkEnableAlias {
        old = [
          "presets"
          "foo"
          "enable"
        ];
        new = [
          "features"
          "foo"
          "enable"
        ];
      })
      { presets.foo.enable = true; }
    ];
  };
in
{
  # ── renames: forward + warn ─────────────────────────────────────────
  rename-forwards-old-to-new = {
    expr = renameEval.config.new.opt;
    expected = 5;
  };
  rename-emits-warning = {
    expr = builtins.length renameEval.config.warnings > 0;
    expected = true;
  };
  rename-unset-is-silent = {
    expr = renameUnsetEval.config.warnings;
    expected = [ ];
  };
  rename-unset-keeps-default = {
    expr = renameUnsetEval.config.new.opt;
    expected = 0;
  };
  rename-list-path-form = {
    expr = renameListEval.config.new.opt;
    expected = 6;
  };

  # ── aliases: forward silently + mirror reads ────────────────────────
  alias-forwards-old-to-new = {
    expr = aliasEval.config.new.opt;
    expected = 7;
  };
  alias-is-silent = {
    expr = aliasEval.config.warnings;
    expected = [ ];
  };
  alias-reads-back = {
    expr = aliasEval.config.old.opt == aliasEval.config.new.opt;
    expected = true;
  };

  # ── removed: set throws, unset stays evaluable ──────────────────────
  removed-set-throws-with-reason = {
    expr = (builtins.tryEval removedSetEval.config.old.gone).success;
    expected = false;
  };
  removed-set-assertion-fires = {
    expr = (builtins.head removedSetEval.config.assertions).assertion;
    expected = false;
  };
  removed-unset-still-evaluates = {
    expr = (builtins.tryEval (builtins.deepSeq removedUnsetEval.config.assertions true)).success;
    expected = true;
  };
  removed-unset-assertion-holds = {
    expr = (builtins.head removedUnsetEval.config.assertions).assertion;
    expected = true;
  };

  # ── typed throws ────────────────────────────────────────────────────
  empty-shim-throws = {
    expr = (builtins.tryEval (mkDeprecationShim { })).success;
    expected = false;
  };
  removed-without-reason-throws = {
    expr = (builtins.tryEval (mkDeprecationShim { removed = [ { path = "a.b"; } ]; })).success;
    expected = false;
  };
  bad-path-type-throws = {
    expr =
      (builtins.tryEval (mkDeprecationShim {
        aliases = [
          {
            from = 42;
            to = "a.b";
          }
        ];
      })).success;
    expected = false;
  };
  missing-rename-to-throws = {
    expr = (builtins.tryEval (mkDeprecationShim { renames = [ { from = "a.b"; } ]; })).success;
    expected = false;
  };
  unknown-for-class-throws = {
    expr =
      (builtins.tryEval (mkDeprecationShim {
        for = "frobnicate";
        aliases = [
          {
            from = "a.b";
            to = "c.d";
          }
        ];
      })).success;
    expected = false;
  };

  # ── for-tagging: parse-time class gate ──────────────────────────────
  for-homeManager-rejected-under-nixos = {
    expr = hmRejected.success;
    expected = false;
  };
  for-homeManager-accepted-under-homeManager = {
    expr = hmAccepted.success && hmAccepted.value == 5;
    expected = true;
  };
  tagged-shim-carries-class = {
    expr = hmShim._class;
    expected = "homeManager";
  };
  untagged-shim-has-no-class = {
    expr = renameShim ? _class;
    expected = false;
  };

  # ── module shape ────────────────────────────────────────────────────
  shim-file-marker = {
    expr = renameShim._file;
    expected = "<iroha:shim>";
  };
  shim-imports-one-per-entry = {
    expr =
      builtins.length
        (mkDeprecationShim {
          renames = [
            {
              from = "a.b";
              to = "c.d";
            }
          ];
          removed = [
            {
              path = "e.f";
              reason = "r";
            }
          ];
          aliases = [
            {
              from = "g.h";
              to = "i.j";
            }
          ];
        }).imports;
    expected = 3;
  };

  # ── mkEnableAlias ───────────────────────────────────────────────────
  enable-alias-flips-new = {
    expr = enableEval.config.features.foo.enable;
    expected = true;
  };
  enable-alias-list-path = {
    expr = enableListEval.config.features.foo.enable;
    expected = true;
  };
  enable-alias-bad-path-throws = {
    expr =
      (builtins.tryEval (mkEnableAlias {
        old = 5;
        new = "a.b";
      })).success;
    expected = false;
  };
  enable-alias-file-marker = {
    expr =
      (mkEnableAlias {
        old = "a.b";
        new = "c.d";
      })._file;
    expected = "<iroha:shim>";
  };
}
