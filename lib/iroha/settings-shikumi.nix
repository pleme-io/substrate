# iroha.settings-shikumi — L1 bridge: shikumi schema → option-surface fields.
#
# The CONFIGURATION-MANAGEMENT missing link. Every operator-facing pleme-io
# Rust tool exposes its typed config through shikumi::TieredConfig, and
# `<app> config-schema` exports that schema as JSON in the
# shikumiTypedGroups convention. This letter converts that ONE schema into
# the option-surface `settings.fields` grouped spec, so the Rust
# TieredConfig surface and the Nix option surface are derived from the same
# source and cannot drift: regenerate the schema, re-import it here, and the
# HM/NixOS/Darwin option surface follows mechanically.
#
# shikumi schema shape (the JSON `<app> config-schema` emits):
#   schema :: attrsOf group
#   group  :: attrsOf field
#   field  :: { type :: <shikumi alias, below>; default ? ; description ? ;
#               min ? ; max ? }
#
# Alias normalization (rust-ish shikumi type → iroha fieldSpec alias):
#   str | string                   → str
#   bool | boolean                 → bool
#   float | f32 | f64              → float
#   int                            → int
#   path                           → path
#   u16                            → port      (bare: the 0–65535 default)
#   u32 | u64 | i32 | i64 | usize  → int
#   vec<string>                    → listOfStr
#   vec<int>                       → listOfInt
#   map<string,string>             → attrsOfStr
# Bounds promotion: any INTEGER-class alias (int/u16/u32/u64/i32/i64/usize)
# with min and/or max present becomes intRange with the given bounds
# (missing bound filled with core.fieldType's 0/65535 defaults). Bounds on
# non-integer aliases are carried verbatim but inert — core.fieldType has
# no float-range alias today; carrying keeps the conversion lossless.
#
# Exports (pure { lib }, zero pkgs):
#
#   shikumiTypeToFieldType :: str -> { type :: str }
#     The pure, bounds-free alias mapping (the table above, without the
#     intRange promotion — that needs the field's min/max and lives in
#     mkSettingsFromShikumi). Exposed for reuse + tests.
#
#   mkSettingsFromShikumi :: {
#     name       :: str (required) — app name, interpolated into every
#                   error message so a failing fleet-wide conversion names
#                   its app;
#     schema     ? null — the schema attrs above (already-parsed form);
#     schemaFile ? null — path to the JSON export, read via
#                   builtins.fromJSON (builtins.readFile schemaFile);
#                   exactly ONE of schema/schemaFile is required;
#   } -> fields :: attrsOf (attrsOf fieldSpec)
#     The option-surface `settings.fields` grouped shape — feed directly
#     into mkOptionSurface { settings.fields = <result>; }. Per field:
#     default/description carried verbatim; min/max promoted (integer
#     aliases) or carried inert (others). A shikumi field literally named
#     `type` inside a group converts to a fieldSpec-shaped attrset, which
#     option-surface's group/fieldSpec discriminator handles correctly.
#
# Throws (every message prefixed "iroha.settings-shikumi.<fn>: "):
#   shikumiTypeToFieldType — non-string alias; unknown shikumi type.
#   mkSettingsFromShikumi  — `name` missing or non-string; both of
#                            schema+schemaFile given; neither given; schema
#                            not an attrset; a group not an attrset; a field
#                            not an attrset / missing `type` / non-string
#                            `type`; unknown shikumi type (names app, group,
#                            field, and the offending type). readFile /
#                            fromJSON errors on a bad schemaFile propagate
#                            untyped (builtins' own messages).
{ lib }:
let
  inherit (lib) optionalAttrs;

  # rust-ish shikumi type → iroha fieldSpec string alias (core.fieldType).
  baseAlias = {
    "int" = "int";
    "str" = "str";
    "string" = "str";
    "bool" = "bool";
    "boolean" = "bool";
    "float" = "float";
    "f32" = "float";
    "f64" = "float";
    "path" = "path";
    "u16" = "port";
    "u32" = "int";
    "u64" = "int";
    "i32" = "int";
    "i64" = "int";
    "usize" = "int";
    "vec<string>" = "listOfStr";
    "vec<int>" = "listOfInt";
    "map<string,string>" = "attrsOfStr";
  };

  knownAliases = lib.concatStringsSep ", " (builtins.attrNames baseAlias);

  # Integer-class aliases: min/max present promotes these to intRange.
  intish = [
    "int"
    "u16"
    "u32"
    "u64"
    "i32"
    "i64"
    "usize"
  ];

  shikumiTypeToFieldType =
    t:
    if !(builtins.isString t) then
      throw "iroha.settings-shikumi.shikumiTypeToFieldType: shikumi type must be a string — got ${builtins.typeOf t}."
    else if !(baseAlias ? ${t}) then
      throw "iroha.settings-shikumi.shikumiTypeToFieldType: unknown shikumi type '${t}' — one of ${knownAliases}."
    else
      { type = baseAlias.${t}; };

  convertField =
    appName: groupName: fieldName: f:
    let
      where = "app '${appName}', group '${groupName}', field '${fieldName}'";
    in
    if !(builtins.isAttrs f) then
      throw "iroha.settings-shikumi.mkSettingsFromShikumi: ${where}: field must be an attrset { type, ... } — got ${builtins.typeOf f}."
    else if !(f ? type) then
      throw "iroha.settings-shikumi.mkSettingsFromShikumi: ${where}: missing `type` — every shikumi field declares one."
    else if !(builtins.isString f.type) then
      throw "iroha.settings-shikumi.mkSettingsFromShikumi: ${where}: `type` must be a string shikumi alias — got ${builtins.typeOf f.type}."
    else if !(baseAlias ? ${f.type}) then
      throw "iroha.settings-shikumi.mkSettingsFromShikumi: ${where}: unknown shikumi type '${f.type}' — one of ${knownAliases}."
    else
      let
        bounded = (f ? min || f ? max) && builtins.elem f.type intish;
        base =
          if bounded then
            {
              type = "intRange";
              min = f.min or 0;
              max = f.max or 65535;
            }
          else
            { type = baseAlias.${f.type}; }
            // optionalAttrs (f ? min) { inherit (f) min; }
            // optionalAttrs (f ? max) { inherit (f) max; };
      in
      base
      // optionalAttrs (f ? default) { inherit (f) default; }
      // optionalAttrs (f ? description) { inherit (f) description; };

  mkSettingsFromShikumi =
    args:
    let
      name =
        if !(args ? name) then
          throw "iroha.settings-shikumi.mkSettingsFromShikumi: `name` (str) is required — it names the app in every error message."
        else if !(builtins.isString args.name) then
          throw "iroha.settings-shikumi.mkSettingsFromShikumi: `name` must be a string — got ${builtins.typeOf args.name}."
        else
          args.name;
      schema = args.schema or null;
      schemaFile = args.schemaFile or null;
      # seq name: forcing ANY part of the result (even just attr names)
      # surfaces a missing/mistyped `name` instead of deferring it to the
      # first error message that would have interpolated it.
      resolved = builtins.seq name (
        if schema != null && schemaFile != null then
          throw "iroha.settings-shikumi.mkSettingsFromShikumi: app '${name}': exactly one of `schema` or `schemaFile` is required — got both."
        else if schema == null && schemaFile == null then
          throw "iroha.settings-shikumi.mkSettingsFromShikumi: app '${name}': exactly one of `schema` or `schemaFile` is required — got neither."
        else if schemaFile != null then
          builtins.fromJSON (builtins.readFile schemaFile)
        else
          schema
      );
    in
    if !(builtins.isAttrs resolved) then
      throw "iroha.settings-shikumi.mkSettingsFromShikumi: app '${name}': schema must be an attrset of groups (attrsOf (attrsOf field)) — got ${builtins.typeOf resolved}."
    else
      lib.mapAttrs (
        groupName: group:
        if !(builtins.isAttrs group) then
          throw "iroha.settings-shikumi.mkSettingsFromShikumi: app '${name}', group '${groupName}': group must be an attrset of fields — got ${builtins.typeOf group}."
        else
          lib.mapAttrs (fieldName: convertField name groupName fieldName) group
      ) resolved;
in
{
  inherit shikumiTypeToFieldType mkSettingsFromShikumi;
}
