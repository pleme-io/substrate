# Tests — iroha.profile (mkProfile: axis banding, _type-stop, enables,
# manifest pass-through, class tagging, assertions, imports, typed throws).
{ lib, iroha }:
let
  inherit (iroha) mkProfile at;

  # ── option universes ────────────────────────────────────────────────
  vOpt = {
    options.v = lib.mkOption { type = lib.types.int; };
  };
  wOpt = {
    options.w = lib.mkOption { type = lib.types.int; };
  };
  nestedOpt = {
    options.a.b.c = lib.mkOption { type = lib.types.int; };
  };
  enableOpt = {
    options.services.foo.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };
  xOpt = {
    options.programs.x.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };
  assertOpt = {
    options.assertions = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
    };
  };
  v2Opt = {
    options.v2 = lib.mkOption {
      type = lib.types.int;
      default = 0;
    };
  };

  # ── axis banding: base loses to mixin, both lose to a plain node def ─
  pBase = mkProfile {
    name = "a";
    axis = "base";
    for = "nixos";
    settings.v = 10;
  };
  pMixin = mkProfile {
    name = "b";
    axis = "mixin";
    for = "nixos";
    settings.v = 20;
  };
  axisEval = lib.evalModules {
    class = "nixos";
    modules = [
      vOpt
      pBase
      pMixin
    ];
  };
  nodeEval = lib.evalModules {
    class = "nixos";
    modules = [
      vOpt
      pBase
      pMixin
      { v = 30; }
    ];
  };

  # ── _type stop: mkForce inside settings passes through un-rebanded ──
  pForce = mkProfile {
    name = "f";
    axis = "base";
    for = "nixos";
    settings.w = lib.mkForce 99;
  };
  forceEval = lib.evalModules {
    class = "nixos";
    modules = [
      wOpt
      pForce
      { w = 33; }
    ];
  };

  # ── nested settings: leaves banded, stronger axis wins at the leaf ──
  pNestBase = mkProfile {
    name = "n1";
    axis = "base";
    for = "nixos";
    settings.a.b.c = 1;
  };
  pNestRole = mkProfile {
    name = "n2";
    axis = "role";
    for = "nixos";
    settings.a.b.c = 2;
  };
  nestedEval = lib.evalModules {
    class = "nixos";
    modules = [
      nestedOpt
      pNestBase
      pNestRole
    ];
  };

  # ── enables: dotted + list path forms; node band beats the enable ───
  pEnable = mkProfile {
    name = "e";
    for = "nixos";
    enables = [ "services.foo.enable" ];
  };
  enableEval = lib.evalModules {
    class = "nixos";
    modules = [
      enableOpt
      pEnable
    ];
  };
  enableNodeEval = lib.evalModules {
    class = "nixos";
    modules = [
      enableOpt
      pEnable
      { services.foo.enable = at "node" false; }
    ];
  };
  pEnableList = mkProfile {
    name = "el";
    for = "nixos";
    enables = [
      [
        "services"
        "foo"
        "enable"
      ]
    ];
  };
  enableListEval = lib.evalModules {
    class = "nixos";
    modules = [
      enableOpt
      pEnableList
    ];
  };
  pBadPath = mkProfile {
    name = "bp";
    for = "nixos";
    enables = [ 42 ];
  };
  # The path throw is lazy (lives inside config) — force the option.
  badPathForced = builtins.tryEval (
    builtins.seq
      (lib.evalModules {
        class = "nixos";
        modules = [
          enableOpt
          pBadPath
        ];
      }).config.services.foo.enable
      true
  );

  # ── manifest: pre-banded fragment passes through and flips the opt ──
  fakeManifest = {
    enablesForProfile = _profile: lib.mkMerge [ { programs.x.enable = lib.mkOverride 1000 true; } ];
  };
  pManifest = mkProfile {
    name = "m";
    for = "nixos";
    manifest = fakeManifest;
  };
  manifestEval = lib.evalModules {
    class = "nixos";
    modules = [
      xOpt
      pManifest
    ];
  };

  # ── class tagging: homeManager profile rejected under nixos ─────────
  pHm = mkProfile {
    name = "hm";
    for = "homeManager";
    settings.v = 1;
  };
  hmWrongClass = builtins.tryEval (
    builtins.seq
      (lib.evalModules {
        class = "nixos";
        modules = [
          vOpt
          pHm
        ];
      }).config.v
      true
  );
  hmRightClassEval = lib.evalModules {
    class = "homeManager";
    modules = [
      vOpt
      pHm
    ];
  };

  # ── assertions land; absent assertions add no fragment ──────────────
  pAssert = mkProfile {
    name = "as";
    for = "nixos";
    assertions = [
      {
        assertion = false;
        message = "profile-as: boom";
      }
    ];
  };
  assertEval = lib.evalModules {
    class = "nixos";
    modules = [
      assertOpt
      pAssert
    ];
  };
  pEmpty = mkProfile {
    name = "na";
    for = "nixos";
  };
  emptyEval = lib.evalModules {
    class = "nixos";
    modules = [
      assertOpt
      pEmpty
    ];
  };

  # ── imports pass through untouched ──────────────────────────────────
  pImports = mkProfile {
    name = "imp";
    for = "nixos";
    imports = [ { v2 = 5; } ];
  };
  importsEval = lib.evalModules {
    class = "nixos";
    modules = [
      v2Opt
      pImports
    ];
  };

  # ── introspection: default axis, _file shape, _class ────────────────
  pDefault = mkProfile {
    name = "d";
    for = "darwin";
  };
in
{
  # ── axis banding ────────────────────────────────────────────────────
  axis-mixin-beats-base = {
    expr = axisEval.config.v;
    expected = 20;
  };
  plain-node-def-beats-every-profile-axis = {
    expr = nodeEval.config.v;
    expected = 30;
  };
  nested-leaf-banded-role-beats-base = {
    expr = nestedEval.config.a.b.c;
    expected = 2;
  };

  # ── _type stop ──────────────────────────────────────────────────────
  type-stop-mkforce-passes-through-un-rebanded = {
    expr = forceEval.config.w;
    expected = 99;
  };

  # ── enables ─────────────────────────────────────────────────────────
  enable-dotted-path-flips-bool = {
    expr = enableEval.config.services.foo.enable;
    expected = true;
  };
  enable-loses-to-node-band-false = {
    expr = enableNodeEval.config.services.foo.enable;
    expected = false;
  };
  enable-list-path-form = {
    expr = enableListEval.config.services.foo.enable;
    expected = true;
  };
  enable-bad-path-type-throws = {
    expr = badPathForced.success;
    expected = false;
  };

  # ── manifest integration ────────────────────────────────────────────
  manifest-fragment-flips-option = {
    expr = manifestEval.config.programs.x.enable;
    expected = true;
  };

  # ── class tagging ───────────────────────────────────────────────────
  hm-profile-rejected-under-nixos-class = {
    expr = hmWrongClass.success;
    expected = false;
  };
  hm-profile-accepted-under-hm-class = {
    expr = hmRightClassEval.config.v;
    expected = 1;
  };
  for-sets-module-class = {
    expr = pDefault._class;
    expected = "darwin";
  };

  # ── assertions ──────────────────────────────────────────────────────
  assertions-land-in-config = {
    expr = map (a: a.message) assertEval.config.assertions;
    expected = [ "profile-as: boom" ];
  };
  empty-profile-contributes-nothing = {
    expr = emptyEval.config.assertions;
    expected = [ ];
  };

  # ── imports ─────────────────────────────────────────────────────────
  imports-pass-through-untouched = {
    expr = importsEval.config.v2;
    expected = 5;
  };

  # ── defaults + _file shape ──────────────────────────────────────────
  default-axis-is-role-in-file-tag = {
    # role == lib.mkDefault: migrating an existing mkDefault profile
    # without naming an axis preserves its exact precedence (parity).
    expr = (builtins.head pDefault.imports)._file;
    expected = "<iroha:profile:role/d>";
  };
  default-axis-band-equals-mkDefault = {
    expr =
      let
        ev = lib.evalModules {
          class = "nixos";
          modules = [
            { options.v = lib.mkOption { type = lib.types.int; }; }
            { v = lib.mkDefault 1; } # unmigrated mkDefault profile
            (mkProfile {
              name = "p";
              for = "nixos";
              settings.v = 2;
            })
          ];
        };
      in
      # Same band -> conflicting definitions -> loud failure (exactly
      # what two mkDefault profiles did before migration: parity).
      (builtins.tryEval ev.config.v).success;
    expected = false;
  };

  # ── whole: band-boundary escape for non-recursing option types ──────
  whole-bands-subtree-as-one-value = {
    # types.attrs merges definition values verbatim at depth >= 1; per-leaf
    # wrappers would leak into config as literal data. `whole` wraps the
    # subtree once at its top, so the option receives plain data.
    expr =
      let
        ev = lib.evalModules {
          class = "nixos";
          modules = [
            { options.x = lib.mkOption { type = lib.types.attrs; }; }
            (mkProfile {
              name = "p";
              for = "nixos";
              settings.x = {
                a.b = 5;
              };
              whole = [ "x" ];
            })
          ];
        };
      in
      ev.config.x;
    expected = {
      a.b = 5;
    };
  };
  per-leaf-banding-leaks-through-types-attrs-without-whole = {
    # Regression pin of the documented BAND BOUNDARY: without `whole`,
    # a types.attrs option at depth >= 2 receives the raw override
    # wrapper as data. This test documents the boundary (it is the
    # reason `whole` exists), so a future fix that discharges wrappers
    # everywhere will flip this expectation — deliberately.
    expr =
      let
        ev = lib.evalModules {
          class = "nixos";
          modules = [
            { options.x = lib.mkOption { type = lib.types.attrs; }; }
            (mkProfile {
              name = "p";
              for = "nixos";
              settings.x = {
                a.b = 5;
              };
            })
          ];
        };
      in
      ev.config.x.a.b._type or "no-wrapper";
    expected = "override";
  };
  whole-missing-path-throws = {
    expr =
      (builtins.tryEval
        (lib.evalModules {
          class = "nixos";
          modules = [
            { options.x = lib.mkOption { type = lib.types.attrs; }; }
            (mkProfile {
              name = "p";
              for = "nixos";
              settings.x = { };
              whole = [ "y" ];
            })
          ];
        }).config.x
      ).success;
    expected = false;
  };

  # ── typed throws (eager at construction) ────────────────────────────
  unknown-axis-throws = {
    expr =
      (builtins.tryEval (mkProfile {
        name = "x";
        axis = "node";
        for = "nixos";
      })).success;
    expected = false;
  };
  unknown-for-class-throws = {
    expr =
      (builtins.tryEval (mkProfile {
        name = "x";
        for = "flake";
      })).success;
    expected = false;
  };
  non-string-name-throws = {
    expr =
      (builtins.tryEval (mkProfile {
        name = 42;
        for = "nixos";
      })).success;
    expected = false;
  };
  non-attrset-settings-throws = {
    expr =
      (builtins.tryEval (mkProfile {
        name = "x";
        for = "nixos";
        settings = 5;
      })).success;
    expected = false;
  };
}
