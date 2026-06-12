# iroha.profile — L4 composition: axis-named profile layers (srvos shape).
#
# A profile is one stackable configuration layer pinned to a named priority
# axis (base < hardware < mixin < role in strength; lower number wins). Every
# plain-data leaf a profile sets is band-wrapped at its axis, so stacking is
# commutative within an axis, cross-axis precedence is deterministic, and any
# node-level plain definition beats every profile — by band arithmetic, not
# by import order. The result is a class-tagged module: a profile authored
# for one module class cannot be evaluated under another (parse-time
# rejection via evalModules `class`).
#
# BAND BOUNDARY (load-bearing — read before authoring settings): per-leaf
# band wrappers are only discharged where the target option's TYPE merges
# per nested attr (attrsOf / submodule / anything / pkgs.formats types).
# Options whose merge uses definition values verbatim — types.attrs at
# depth >= 2, and custom merges like nixpkgs.config — pass the wrapper
# through as LITERAL DATA ({ _type = "override"; ... } lands in config).
# For such targets, set the subtree as ONE banded value via `whole`
# (below) or pre-wrap it yourself (`settings.nixpkgs.config =
# core.at axis { allowUnfree = true; }` — the _type stop passes it through
# intact, banded at the top).
#
# MIGRATION PARITY: the default axis is "role" (priority 1000 ==
# lib.mkDefault) — migrating an existing mkDefault-based profile without
# naming an axis preserves its exact precedence. Choose a weaker axis
# (base/hardware/mixin) deliberately, knowing role-banded manifest enables
# and other role-axis profiles will then beat this profile's values.
#
# Exports (pure { lib }, zero pkgs):
#
#   mkProfile :: {
#     name       :: str                            (required — typed throw if
#                                                   not a string);
#     axis       ?  "role"                         — "base"|"hardware"|"mixin"
#                                                   |"role"; typed throw
#                                                   otherwise. Default "role"
#                                                   == lib.mkDefault: parity
#                                                   with every existing
#                                                   mkDefault-based profile;
#     for        :: "nixos"|"darwin"|"homeManager" (required — the module
#                                                   class; typed throw
#                                                   otherwise);
#     manifest   ?  null                           — a mkManifest result; when
#                                                   non-null, config includes
#                                                   manifest.enablesForProfile
#                                                   name. That fragment is
#                                                   ALREADY role-banded by the
#                                                   manifest letter and passes
#                                                   through untouched —
#                                                   REGARDLESS of this
#                                                   profile's axis;
#     enables    ?  [ ]                            — listOf (dotted str |
#                                                   [str]) option paths set
#                                                   `true` at the axis band;
#                                                   any other path shape is a
#                                                   typed throw (surfaced when
#                                                   config is forced);
#     settings   ?  { }                            — PLAIN-DATA config attrs;
#                                                   every LEAF wrapped
#                                                   `core.at axis`. Descent
#                                                   rules: an attrset WITH
#                                                   _type passes through
#                                                   untouched (stop — mkForce/
#                                                   mkIf/mkOverride keep their
#                                                   own band); an attrset
#                                                   WITHOUT _type descends;
#                                                   everything else (ints,
#                                                   strs, bools, lists,
#                                                   functions, null) is a leaf
#                                                   wrapped whole. Empty
#                                                   settings contribute { }
#                                                   harmlessly. Typed throw if
#                                                   not an attrset. See BAND
#                                                   BOUNDARY above for option
#                                                   types that need `whole`;
#     whole      ?  [ ]                            — listOf (dotted str |
#                                                   [str]): settings paths
#                                                   whose SUBTREE is banded as
#                                                   one value instead of
#                                                   per-leaf (for types.attrs /
#                                                   nixpkgs.config-class
#                                                   targets whose merge does
#                                                   not discharge nested
#                                                   wrappers). Path must exist
#                                                   in settings — typed throw
#                                                   otherwise;
#     imports    ?  [ ]                            — modules passed through
#                                                   untouched;
#     assertions ?  [ ]                            — listOf { assertion,
#                                                   message }; emitted as
#                                                   config.assertions when
#                                                   non-empty;
#   } -> module
#
#   Result shape:
#     core.tag <for> {
#       _file   = "<iroha:profile:<axis>/<name>>";
#       imports = imports;
#       config  = lib.mkMerge ([ banded-settings ]
#                              ++ enable-fragments        # one per path
#                              ++ [ manifest-fragment ]?  # iff manifest
#                              ++ [ assertions-fragment ]?);
#     }
#
#   Enable fragment per path:
#     lib.setAttrByPath (normalized path) (core.at axis true)
#   Path normalization: dotted str -> lib.splitString "."; list passes
#   through; anything else is a typed throw.
{ lib }:
let
  core = import ./core.nix { inherit lib; };

  axes = [
    "base"
    "hardware"
    "mixin"
    "role"
  ];

  forClasses = [
    "nixos"
    "darwin"
    "homeManager"
  ];

  mkProfile =
    {
      name,
      axis ? "role",
      for,
      manifest ? null,
      enables ? [ ],
      settings ? { },
      whole ? [ ],
      imports ? [ ],
      assertions ? [ ],
    }:
    let
      name' =
        if builtins.isString name then
          name
        else
          throw "iroha.profile.mkProfile: `name` must be a string, got ${builtins.typeOf name}.";

      axis' =
        if builtins.elem axis axes then
          axis
        else
          throw "iroha.profile.mkProfile: unknown axis '${toString axis}' — expected one of ${lib.concatStringsSep ", " axes}.";

      for' =
        if builtins.elem for forClasses then
          for
        else
          throw "iroha.profile.mkProfile: unknown `for` class '${toString for}' — expected one of ${lib.concatStringsSep ", " forClasses}.";

      settings' =
        if builtins.isAttrs settings then
          settings
        else
          throw "iroha.profile.mkProfile: `settings` must be a plain-data attrset, got ${builtins.typeOf settings}.";

      normalizePath =
        p:
        if builtins.isString p then
          lib.splitString "." p
        else if builtins.isList p then
          p
        else
          throw "iroha.profile.mkProfile: enable path must be a dotted string or a list of strings, got ${builtins.typeOf p}.";

      wholePaths = map (
        p:
        let
          np = normalizePath p;
        in
        if lib.hasAttrByPath np settings' then
          np
        else
          throw "iroha.profile.mkProfile: `whole` path ${lib.concatStringsSep "." np} does not exist in `settings`."
      ) whole;

      # Pre-wrap each `whole` subtree at its top: the _type stop in `band`
      # then passes it through intact — one banded value, no per-leaf
      # descent. This is the escape for option types whose merge does not
      # discharge nested override wrappers (types.attrs depth >= 2,
      # nixpkgs.config — see BAND BOUNDARY in the header).
      settingsWithWhole = lib.updateManyAttrsByPath (map (p: {
        path = p;
        update = old: core.at axis' old;
      }) wholePaths) settings';

      # Descent: _type-carrying attrsets stop (pass through untouched —
      # they already carry their own band/semantics); plain attrsets
      # descend; every other value is a leaf wrapped whole at the axis.
      band =
        v:
        if builtins.isAttrs v then
          if v ? _type then v else lib.mapAttrs (_: band) v
        else
          core.at axis' v;

      enableFragment = p: lib.setAttrByPath (normalizePath p) (core.at axis' true);

      fragments =
        [ (band settingsWithWhole) ]
        ++ map enableFragment enables
        # Manifest fragment: already role-banded by the manifest letter;
        # passes through regardless of this profile's axis.
        ++ lib.optional (manifest != null) (manifest.enablesForProfile name')
        ++ lib.optional (assertions != [ ]) { inherit assertions; };
    in
    # Force the typed validations at WHNF so a bad name/axis/settings throws
    # at construction time, not at first config read (for' is forced by
    # core.tag's own class check).
    builtins.seq name' (
      builtins.seq axis' (
        builtins.seq settings' (
          core.tag for' {
            _file = "<iroha:profile:${axis'}/${name'}>";
            inherit imports;
            config = lib.mkMerge fragments;
          }
        )
      )
    );
in
{
  inherit mkProfile;
}
