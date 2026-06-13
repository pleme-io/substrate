# iroha.config-owner — L2: a single typed OWNER of a contended config region.
#
# Some config regions are CONTENDED: several modules reach for the same
# leaf (nix.settings.post-build-hook, a sysctl, nix.settings.substituters,
# a nixpkgs provider toggle) and the last/strongest definition silently
# wins — or worse, two definitions at the same priority collide
# ("option set multiple times"). The fleet hits this >=4× (post-build-hook,
# nix-cache substituters, sysctl-overrides with mkOverride 999 collisions,
# nix-provider). This letter makes ONE module the authoritative owner of a
# region: it sets the owned values at a HIGH priority band (default
# "force" == mkForce, so the owner WINS over any plain competitor), and it
# can assert the region is not multiply-claimed via caller-supplied
# assertions emitted as config.assertions.
#
# Band-wrapping reuses the SAME bandLeaves descent kata.mkProfile uses
# (iroha/profile.nix `band`): recurse plain attrsets, STOP at any
# _type-tagged value (an already-mkForce/mkIf/mkOverride leaf in `owns`
# passes through un-rebanded, keeping its own band), wrap every other leaf
# at the chosen band via core.at. So an owner authored at "force" beats a
# competitor's plain definition by band arithmetic, not import order; an
# owner authored at a WEAKER band ("role") deliberately LOSES to a
# node-plain definition (band arithmetic, not a special case).
#
# COMPOSES iroha.mkOptionSurface for the enable + extraOptions skeleton
# (package = false, settings = null) and iroha.core.{at,tag,prio} for band
# wrapping + class tagging. pkgs never appears at import time — it binds
# late as a module argument.
#
# Exports (pure { lib }, zero pkgs):
#
#   mkConfigOwner :: {
#     name        :: str (required) — owner name + last option-path segment;
#     description :: str (required) — human description (enable option text);
#     namespace   ? "system"        — dotted option root; the option lands at
#                                     <namespace>.<name>;
#     enable      ? true            — whether the region is owned (the enable
#                                     option's default); when false, the
#                                     owned values + assertions are absent;
#     extraOptions ? { } | (lib -> attrs) — extra typed option declarations
#                                     merged under the option root (function
#                                     form receives lib);
#     owns        :: attrs (required) — the config fragment this module
#                                     authoritatively sets. Every PLAIN leaf
#                                     is wrapped at `band` (default mkForce)
#                                     so this owner wins over competitors; a
#                                     leaf already _type-tagged (mkForce/mkIf/
#                                     mkOverride/…) passes through un-rebanded.
#                                     Typed throw if not an attrset;
#     band        ? "force"         — a core.prio band NAME ("force"|"role"|
#                                     "node"|"base"|"hardware"|"mixin") OR a
#                                     raw int priority — the priority the
#                                     owned leaves are wrapped at. Default
#                                     "force" (mkForce) makes the owner win.
#                                     A weaker band makes it deliberately lose
#                                     to stronger definitions. An unknown band
#                                     NAME is a typed throw (raw ints always
#                                     accepted, matching core.at);
#     assertions  ? [ ]             — listOf { assertion, message } where
#                                     assertion is a bool OR a (config -> bool)
#                                     predicate (resolved inside config where
#                                     `config` exists). Emitted verbatim as
#                                     config.assertions when enable AND the
#                                     list is non-empty. Typed throw if not a
#                                     list, or an entry missing assertion/
#                                     message (surfaced when assertions force);
#   } -> {
#     nixos :: class-tagged module (_class "nixos") —
#       options.<ns>.<name>.{ enable, …extraOptions };
#       config = mkIf cfg.enable (mkMerge (
#         [ <owns, every plain leaf banded at `band`> ]
#         ++ [ { assertions = <resolved>; } ]  when assertions != [ ]));
#     darwin :: class-tagged module (_class "darwin") — same shape;
#     meta :: {
#       name; optionPath; enablePath; band; kind = "config-owner";
#     };
#   }
#
# Throws (every message prefixed "iroha.config-owner.mkConfigOwner: "):
#   - `name` / `description` missing;
#   - `owns` missing or not an attrset;
#   - `band` an unknown band NAME (raw ints always pass, per core.at);
#   - `assertions` not a list, or an entry missing `assertion` / `message`.
{ lib }:
let
  core = import ./core.nix { inherit lib; };
  optionSurface = import ./option-surface.nix { inherit lib; };
  inherit (lib) optionalAttrs;

  bandNames = builtins.attrNames core.prio;

  mkConfigOwner =
    args:
    let
      name = args.name or (throw "iroha.config-owner.mkConfigOwner: `name` (str) is required.");
      description =
        args.description
          or (throw "iroha.config-owner.mkConfigOwner: `description` (str) is required.");
      namespace = args.namespace or "system";
      enable = args.enable or true;
      extraOptions = args.extraOptions or { };
      owns =
        if !(args ? owns) then
          throw "iroha.config-owner.mkConfigOwner: `owns` (attrs — the config fragment this owner authoritatively sets) is required."
        else if !(builtins.isAttrs args.owns) then
          throw "iroha.config-owner.mkConfigOwner: `owns` must be an attrset (a config fragment), got ${builtins.typeOf args.owns}."
        else
          args.owns;

      # Band validation: a NAME must resolve in core.prio; a raw int always
      # passes (matching core.at). Forced at construction so a bad band name
      # throws here, not at first config read.
      band = args.band or "force";
      band' =
        if builtins.isInt band then
          band
        else if builtins.isString band && builtins.hasAttr band core.prio then
          band
        else
          throw "iroha.config-owner.mkConfigOwner: unknown band '${toString band}' — one of ${lib.concatStringsSep ", " bandNames} or a raw int priority.";

      rawAssertions = args.assertions or [ ];
      assertions =
        if !(builtins.isList rawAssertions) then
          throw "iroha.config-owner.mkConfigOwner: `assertions` must be a list of { assertion, message }, got ${builtins.typeOf rawAssertions}."
        else
          rawAssertions;

      # ── band-wrapping (the bandLeaves shape mkProfile uses) ─────────────
      # _type-carrying attrsets stop (an already-banded mkForce/mkIf/
      # mkOverride leaf passes through untouched); plain attrsets descend;
      # every other value is a leaf wrapped whole at the chosen band.
      bandLeaves =
        v:
        if builtins.isAttrs v then
          if v ? _type then v else lib.mapAttrs (_: bandLeaves) v
        else
          core.at band' v;

      ownsFragment = bandLeaves owns;

      # Each assertion's `assertion` may be a bool OR a (config -> bool)
      # predicate; resolve inside config where `config` exists. Force the
      # shape (assertion + message present) when the list is built.
      resolveAssertions =
        config:
        map (
          a:
          let
            a' =
              if !(builtins.isAttrs a && a ? assertion && a ? message) then
                throw "iroha.config-owner.mkConfigOwner: each `assertions` entry needs `assertion` (bool | config -> bool) and `message` (str)."
              else
                a;
          in
          {
            assertion = if builtins.isFunction a'.assertion then a'.assertion config else a'.assertion;
            inherit (a') message;
          }
        ) assertions;

      # ── option surface (enable + extras; no package, no settings) ───────
      surface = optionSurface.mkOptionSurface {
        inherit
          name
          description
          namespace
          enable
          ;
        package = false;
        settings = null;
        extra = extraOptions;
      };

      optionPath = surface.optionPath;
      enablePath = surface.enablePath;

      configFragment =
        {
          config,
          ...
        }:
        let
          cfg = lib.getAttrFromPath optionPath config;
        in
        {
          config = lib.mkIf cfg.enable (
            lib.mkMerge (
              [ ownsFragment ]
              ++ lib.optional (assertions != [ ]) { assertions = resolveAssertions config; }
            )
          );
        };

      mkClassModule =
        class:
        core.tag class {
          imports = [
            surface.module
            configFragment
          ];
        };
    in
    # Force the typed validations at WHNF so a bad name/owns/band throws at
    # construction time (name/description forced by their `or` throws on use
    # below; band' + owns forced here).
    builtins.seq band' (
      builtins.seq (builtins.isAttrs owns) {
        nixos = mkClassModule core.classes.nixos;
        darwin = mkClassModule core.classes.darwin;
        meta = {
          inherit name optionPath enablePath;
          band = band';
          kind = "config-owner";
        };
      }
    );
in
{
  inherit mkConfigOwner;
}
