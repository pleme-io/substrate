# iroha.core — L0 vocabulary of the pleme-io Nix primitive alphabet.
#
# iroha (いろは): the classical Japanese pangram in which every kana appears
# exactly once — every primitive exists once, duplication is structurally
# absent. This file is the alphabet's ground floor: everything above it
# speaks only this vocabulary.
#
# Exports (pure { lib }, zero pkgs):
#
#   prio        — named priority bands for configuration layering.
#                 LOWER number WINS (lib.mkOverride semantics):
#                   base     = 1300   weakest profile axis
#                   hardware = 1200
#                   mixin    = 1100
#                   role     = 1000   == lib.mkDefault — existing profiles
#                                     already read as role-band (zero
#                                     behavioral change on adoption day)
#                   node     =  100   == plain definition priority — node
#                                     config beats every profile axis
#                   force    =   50   == lib.mkForce
#
#   at          — bandName|int -> value -> mkOverride'd value.
#
#   bandOf      — introspection: a _type-tagged override value -> band name
#                 (or "custom:<n>"), for "which layer set this?" queries.
#
#   classes     — the four module classes the alphabet emits.
#   tag         — className -> module -> class-tagged module wrapper.
#                 Tier-honest: this is parse-time rejection (evalModules
#                 with a mismatched `class` throws), not compile-time
#                 unrepresentability.
#
#   fieldType   — string-alias|raw types.* -> option type. The type-alias
#                 dictionary lifted from module-trio.nix resolveFieldType
#                 (superset; canonical home is now here).
#   mkField     — fieldSpec -> mkOption.
#   mkFields    — attrsOf fieldSpec -> attrsOf mkOption.
#
# fieldSpec = {
#   type :: "int"|"str"|"bool"|"float"|"path"|"port"
#         | "nullOrStr"|"nullOrInt"|"nullOrBool"|"nullOrPath"|"nullOrFloat"
#         | "listOfStr"|"listOfInt"|"listOfBool"|"listOfPath"
#         | "attrsOfStr"|"attrsOfInt"|"attrsOfBool"|"attrs"|"lines"
#         | "intRange" (with min/max) | "enum" (with values)
#         | raw types.* expression;
#   default ? ; description ? ; example ? ; min ? ; max ? ; values ? ;
# }
{ lib }:
let
  inherit (lib) types mkOption optionalAttrs;

  prio = {
    base = 1300;
    hardware = 1200;
    mixin = 1100;
    role = 1000; # == lib.mkDefault
    node = 100; # == plain definition (lib.modules.defaultOverridePriority)
    force = 50; # == lib.mkForce
  };

  bandNames = builtins.attrNames prio;

  at =
    band: value:
    let
      p =
        if builtins.isInt band then
          band
        else
          prio.${band} or (throw "iroha.core.at: unknown band '${toString band}' — one of ${lib.concatStringsSep ", " bandNames} or a raw int.");
    in
    lib.mkOverride p value;

  bandOf =
    v:
    if !(builtins.isAttrs v && v ? _type && v._type == "override") then
      null
    else
      let
        matches = lib.filterAttrs (_: p: p == v.priority) prio;
        names = builtins.attrNames matches;
      in
      if names != [ ] then builtins.head names else "custom:${toString v.priority}";

  classes = {
    nixos = "nixos";
    darwin = "darwin";
    homeManager = "homeManager";
    flake = "flake";
  };

  tag =
    class: module:
    if !(builtins.elem class (builtins.attrValues classes)) then
      throw "iroha.core.tag: unknown class '${toString class}' — one of ${lib.concatStringsSep ", " (builtins.attrValues classes)}."
    else
      {
        _file = "<iroha:tag:${class}>";
        _class = class;
        imports = [ module ];
      };

  fieldType =
    field:
    if field ? type then
      if builtins.isString field.type then
        if field.type == "int" then
          types.int
        else if field.type == "str" then
          types.str
        else if field.type == "bool" then
          types.bool
        else if field.type == "float" then
          types.float
        else if field.type == "path" then
          types.path
        else if field.type == "port" then
          types.port
        else if field.type == "lines" then
          types.lines
        else if field.type == "nullOrStr" then
          types.nullOr types.str
        else if field.type == "nullOrInt" then
          types.nullOr types.int
        else if field.type == "nullOrBool" then
          types.nullOr types.bool
        else if field.type == "nullOrPath" then
          types.nullOr types.path
        else if field.type == "nullOrFloat" then
          types.nullOr types.float
        else if field.type == "listOfStr" then
          types.listOf types.str
        else if field.type == "listOfInt" then
          types.listOf types.int
        else if field.type == "listOfBool" then
          types.listOf types.bool
        else if field.type == "listOfPath" then
          types.listOf types.path
        else if field.type == "attrsOfStr" then
          types.attrsOf types.str
        else if field.type == "attrsOfInt" then
          types.attrsOf types.int
        else if field.type == "attrsOfBool" then
          types.attrsOf types.bool
        else if field.type == "attrs" then
          types.attrs
        else if field.type == "intRange" then
          types.ints.between (field.min or 0) (field.max or 65535)
        else if field.type == "enum" then
          types.enum (field.values or (throw "iroha.core.fieldType: enum needs `values`."))
        else
          throw "iroha.core.fieldType: unknown field type alias '${field.type}' — see the type-alias dictionary in iroha/core.nix, or pass field.type as a raw types.* expression."
      else
        field.type
    else
      types.unspecified;

  mkField =
    field:
    mkOption (
      {
        type = fieldType field;
      }
      // optionalAttrs (field ? default) { inherit (field) default; }
      // optionalAttrs (field ? description) { inherit (field) description; }
      // optionalAttrs (field ? example) { inherit (field) example; }
    );

  mkFields = lib.mapAttrs (_: mkField);
in
{
  inherit
    prio
    at
    bandOf
    classes
    tag
    fieldType
    mkField
    mkFields
    ;
}
