# iroha.option-surface — L1 option algebra: generated option skeletons.
#
# Every operator-facing component exposes the same three-part option
# surface — enable + package + RFC42 settings (freeform submodule with
# typed field islands). Hand-typing that skeleton per component is drift;
# this letter generates it from one typed spec. The emitted module is the
# single standardized shape every hand-rolled options.<ns>.<name> block
# collapses into. pkgs never appears at import time — it binds late, as a
# module argument (settings/eager-package) or a call argument
# (packageFor/render).
#
# Exports (pure { lib }, zero pkgs):
#
#   mkOptionSurface :: {
#     name        :: str (required) — component name;
#     description :: str (required) — human description (enable option text);
#     namespace   ? "programs"      — dotted option root, e.g. "blackmatter.components";
#     optionName  ? name            — last option-path segment;
#     enable      ? true            — emit `enable = mkEnableOption description`;
#     package     ? { }             — { attr ? name, lazy ? true } | false to omit.
#                                     lazy=true : type = nullOr package, default = null,
#                                                 defaultText = "pkgs.<attr>" (resolution
#                                                 deferred to packageFor — no pkgs forced);
#                                     lazy=false: type = package, default = pkgs.<attr>,
#                                                 same defaultText — the QUIRK-COMPATIBLE
#                                                 eager form matching module-trio;
#     settings    ? null | {
#       format   ? "yaml"           — "yaml"|"json"|"toml" → pkgs.formats.<format> at
#                                     render time; ext = yaml/json/toml respectively;
#       relPath  ? ".config/<name>/<name>.<ext>";
#       envVar   ? upper-snake(name) + "_CONFIG" (dashes → underscores);
#       fields   ? { }              — attrsOf fieldSpec (typed islands, core.mkFields).
#                                     One level of grouping: a value v is a fieldSpec
#                                     iff v.type is a string alias or a raw
#                                     lib.types.* value; otherwise v is a group whose
#                                     own attrs are fieldSpecs (shikumiTypedGroups
#                                     shape). A group MAY contain a member field
#                                     named `type` — its fieldSpec-shaped value is
#                                     not an option type, so the group is detected
#                                     correctly;
#       defaults ? { }              — plain attrs merged UNDER user settings at render;
#     };
#     extra       ? { } | (lib: attrs) — extra option declarations merged under the
#                                     option root (function form receives lib);
#   } -> {
#     optionPath   :: [str] — splitString "." namespace ++ [ optionName ];
#     enablePath   :: [str] — optionPath ++ [ "enable" ];
#     settingsSpec :: null | { format, ext, relPath, envVar, fields, defaults }
#                     (all defaults filled — exposed for package-module);
#     packageSpec  :: null | { attr, lazy };
#     module       :: { lib, pkgs, config, ... } -> { options = <nested at optionPath>; }
#                     settings option is the RFC42 shape:
#                     submodule { freeformType = (pkgs.formats.<format> { }).type;
#                                 options = <typed islands incl. groups>; }, default { };
#     packageFor   :: { cfg, pkgs } -> drv — cfg.package if non-null else pkgs.<attr>
#                     (for lazy=false surfaces cfg.package is never null, so the same
#                     expression works);
#     render       :: { cfg, pkgs, ... } -> null | { relPath, envVar, value, source }
#                     value  = core.pruneNulls (recursiveUpdate defaults cfg.settings)
#                     (defaults lose; null-valued attrs are DROPPED — an
#                     unset nullOr island must be absent from the rendered
#                     file, never `null`: one explicit null on a non-Option
#                     Rust field fails the whole serde extraction);
#                     source = (pkgs.formats.<format> { }).generate (baseNameOf relPath) value;
#                     null when settings == null;
#   }
#
# Throws (every message prefixed "iroha.option-surface.<fn>: "):
#   mkOptionSurface — `name`/`description` missing; settings.format outside
#                     yaml|json|toml; `package` neither attrset nor false;
#                     `extra` neither attrset nor function; eager default
#                     forced against a pkgs lacking <attr>.
#   packageFor      — surface was declared with package = false;
#                     pkgs lacks <attr> at resolution time.
{ lib }:
let
  core = import ./core.nix { inherit lib; };
  inherit (lib) types mkOption;

  formatExt = {
    yaml = "yaml";
    json = "json";
    toml = "toml";
  };

  mkOptionSurface =
    args:
    let
      name = args.name or (throw "iroha.option-surface.mkOptionSurface: `name` (str) is required.");
      description = args.description or (throw "iroha.option-surface.mkOptionSurface: `description` (str) is required.");
      namespace = args.namespace or "programs";
      optionName = args.optionName or name;
      enable = args.enable or true;
      package = args.package or { };
      settings = args.settings or null;
      extra = args.extra or { };

      optionPath = lib.splitString "." namespace ++ [ optionName ];
      enablePath = optionPath ++ [ "enable" ];

      packageSpec =
        if package == false then
          null
        else if !(builtins.isAttrs package) then
          throw "iroha.option-surface.mkOptionSurface: `package` must be an attrset { attr ? name, lazy ? true } or false to omit the option — got ${builtins.typeOf package}."
        else
          {
            attr = package.attr or name;
            lazy = package.lazy or true;
          };

      settingsSpec =
        if settings == null then
          null
        else
          let
            format = settings.format or "yaml";
          in
          if !(builtins.hasAttr format formatExt) then
            throw "iroha.option-surface.mkOptionSurface: unknown settings.format '${toString format}' — one of yaml, json, toml."
          else
            let
              ext = formatExt.${format};
            in
            {
              inherit format ext;
              relPath = settings.relPath or ".config/${name}/${name}.${ext}";
              envVar = settings.envVar or "${lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] name)}_CONFIG";
              fields = settings.fields or { };
              defaults = settings.defaults or { };
            };

      # One level of grouping: a value is a fieldSpec iff it carries a
      # `type` that is a TYPE — a string alias or a raw lib.types.* value
      # (_type == "option-type"). A group that legitimately contains a
      # member FIELD named `type` (common in config schemas:
      # connection = { type = { type = "str"; }; host = ...; }) has an
      # attrset `type` that is itself a fieldSpec, not an option type —
      # that is a group, not a fieldSpec. Nested plain attrsets of
      # mkOptions ARE nested option declarations to the module system, so
      # groups land as <group>.<field> typed options.
      isFieldSpec =
        v: v ? type && (builtins.isString v.type || (v.type._type or null) == "option-type");
      islandOptions = lib.mapAttrs (
        _: v: if isFieldSpec v then core.mkField v else core.mkFields v
      ) settingsSpec.fields;

      pkgAttrPath = lib.splitString "." packageSpec.attr;
      resolvePackage =
        fn: pkgs:
        lib.attrByPath pkgAttrPath (throw "iroha.option-surface.${fn}: pkgs.${packageSpec.attr} does not exist — expected the package attribute declared by surface '${name}'.") pkgs;

      packageOption =
        pkgs:
        if packageSpec.lazy then
          mkOption {
            type = types.nullOr types.package;
            default = null;
            defaultText = lib.literalExpression "pkgs.${packageSpec.attr}";
            description = "Package for ${name}; null resolves to pkgs.${packageSpec.attr} via packageFor.";
          }
        else
          mkOption {
            type = types.package;
            default = resolvePackage "mkOptionSurface" pkgs;
            defaultText = lib.literalExpression "pkgs.${packageSpec.attr}";
            description = "Package for ${name}.";
          };

      settingsOption =
        pkgs:
        mkOption {
          type = types.submodule {
            freeformType = (pkgs.formats.${settingsSpec.format} { }).type;
            options = islandOptions;
          };
          default = { };
          description = "Settings for ${name}: typed islands + freeform keys, rendered as ${settingsSpec.format} at ${settingsSpec.relPath}.";
        };

      extraAttrs =
        if builtins.isFunction extra then
          extra lib
        else if builtins.isAttrs extra then
          extra
        else
          throw "iroha.option-surface.mkOptionSurface: `extra` must be an attrset or a function (lib -> attrs) — got ${builtins.typeOf extra}.";

      module =
        {
          lib,
          pkgs,
          config,
          ...
        }:
        {
          options = lib.setAttrByPath optionPath (
            lib.optionalAttrs enable { enable = lib.mkEnableOption description; }
            // lib.optionalAttrs (packageSpec != null) { package = packageOption pkgs; }
            // lib.optionalAttrs (settingsSpec != null) { settings = settingsOption pkgs; }
            // extraAttrs
          );
        };

      packageFor =
        { cfg, pkgs }:
        if packageSpec == null then
          throw "iroha.option-surface.packageFor: surface '${name}' was declared with package = false — expected a package option to resolve; nothing to return."
        else if (cfg.package or null) != null then
          cfg.package
        else
          resolvePackage "packageFor" pkgs;

      render =
        { cfg, pkgs, ... }:
        if settingsSpec == null then
          null
        else
          let
            # pruneNulls: unset nullOr islands (and any authored nulls)
            # must be ABSENT from the rendered file, never `null` — shikumi
            # config extraction (figment + serde) is atomic, so a single
            # explicit null on a non-Option field fails the WHOLE
            # extraction and the app silently falls back to full
            # prescribed defaults. See iroha/core.nix pruneNulls.
            value = core.pruneNulls (lib.recursiveUpdate settingsSpec.defaults cfg.settings);
          in
          {
            inherit (settingsSpec) relPath envVar;
            inherit value;
            source = (pkgs.formats.${settingsSpec.format} { }).generate (baseNameOf settingsSpec.relPath) value;
          };
    in
    {
      inherit
        optionPath
        enablePath
        settingsSpec
        packageSpec
        module
        packageFor
        render
        ;
    };
in
{
  inherit mkOptionSurface;
}
