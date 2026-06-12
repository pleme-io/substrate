# Tests — iroha.core (bands, classes, tag, field types).
{ lib, iroha }:
let
  inherit (iroha) prio at bandOf classes tag fieldType mkField;

  # A module tagged for homeManager must be REJECTED by a nixos-class eval.
  hmTagged = tag classes.homeManager {
    options.x = lib.mkOption {
      type = lib.types.int;
      default = 1;
    };
  };
  wrongClassEval = builtins.tryEval (
    builtins.seq
      (lib.evalModules {
        class = "nixos";
        modules = [ hmTagged ];
      }).config.x
      true
  );
  rightClassEval = builtins.tryEval (
    builtins.seq
      (lib.evalModules {
        class = "homeManager";
        modules = [ hmTagged ];
      }).config.x
      true
  );

  # Band arithmetic: a role-band value loses to a node-band value.
  bandEval = lib.evalModules {
    modules = [
      {
        options.v = lib.mkOption { type = lib.types.int; };
      }
      { v = at "role" 1; }
      { v = at "node" 2; }
    ];
  };
  # base < hardware < mixin < role in strength: mixin beats base.
  axisEval = lib.evalModules {
    modules = [
      {
        options.v = lib.mkOption { type = lib.types.int; };
      }
      { v = at "base" 10; }
      { v = at "mixin" 20; }
    ];
  };
in
{
  # ── bands ───────────────────────────────────────────────────────────
  band-role-equals-mkDefault = {
    expr = (at "role" 7).priority == (lib.mkDefault 7).priority;
    expected = true;
  };
  band-force-equals-mkForce = {
    expr = (at "force" 7).priority == (lib.mkForce 7).priority;
    expected = true;
  };
  band-node-equals-plain-definition = {
    expr = prio.node == lib.modules.defaultOverridePriority;
    expected = true;
  };
  band-ordering = {
    expr = prio.base > prio.hardware && prio.hardware > prio.mixin && prio.mixin > prio.role && prio.role > prio.node && prio.node > prio.force;
    expected = true;
  };
  band-node-beats-role = {
    expr = bandEval.config.v;
    expected = 2;
  };
  band-mixin-beats-base = {
    expr = axisEval.config.v;
    expected = 20;
  };
  band-raw-int-accepted = {
    expr = (at 250 5).priority;
    expected = 250;
  };
  band-unknown-throws = {
    # mkOverride is lazy — force .priority to surface the throw.
    expr = (builtins.tryEval (at "nope" 1).priority).success;
    expected = false;
  };
  bandOf-roundtrip = {
    expr = bandOf (at "mixin" 3);
    expected = "mixin";
  };
  bandOf-custom = {
    expr = bandOf (at 777 3);
    expected = "custom:777";
  };
  bandOf-plain-value = {
    expr = bandOf 42;
    expected = null;
  };

  # ── classes + tag ───────────────────────────────────────────────────
  tag-wrong-class-rejected = {
    expr = wrongClassEval.success;
    expected = false;
  };
  tag-right-class-accepted = {
    expr = rightClassEval.success;
    expected = true;
  };
  tag-unknown-class-throws = {
    expr = (builtins.tryEval (tag "frobnicate" { })).success;
    expected = false;
  };

  # ── field types ─────────────────────────────────────────────────────
  fieldType-int = {
    expr = (fieldType { type = "int"; }).name;
    expected = "int";
  };
  fieldType-nullOrStr-accepts-null = {
    expr = (fieldType { type = "nullOrStr"; }).check null;
    expected = true;
  };
  fieldType-listOfStr = {
    expr = (fieldType { type = "listOfStr"; }).check [ "a" "b" ];
    expected = true;
  };
  fieldType-intRange-bounds = {
    expr =
      let
        t = fieldType {
          type = "intRange";
          min = 1;
          max = 10;
        };
      in
      t.check 5 && !(t.check 11);
    expected = true;
  };
  fieldType-enum = {
    expr =
      (fieldType {
        type = "enum";
        values = [ "a" "b" ];
      }).check "a";
    expected = true;
  };
  fieldType-enum-without-values-throws = {
    expr = (builtins.tryEval ((fieldType { type = "enum"; }).check "a")).success;
    expected = false;
  };
  fieldType-raw-passthrough = {
    expr = (fieldType { type = lib.types.lines; }).name == lib.types.lines.name;
    expected = true;
  };
  fieldType-unknown-alias-throws = {
    expr = (builtins.tryEval (fieldType { type = "complex128"; })).success;
    expected = false;
  };
  mkField-carries-default = {
    expr =
      (mkField {
        type = "int";
        default = 9;
        description = "d";
      }).default;
    expected = 9;
  };
}
