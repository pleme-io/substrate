# iroha.service-bundle — L2: one typed enable+config surface → a CURATED
# SET of upstream nixpkgs services, each feature independently gateable.
#
# The pattern this letter collapses (~10 home-* family modules in the
# fleet): a hand-rolled NixOS module declaring `enable` plus a clutch of
# per-feature `enable` bools, whose `config` is `mkIf cfg.enable (mkMerge
# [ (mkIf cfg.featA.enable { services.foo = …; }) (mkIf cfg.featB.enable
# { services.bar = …; }) … ])`. The bundle enable gates the whole curated
# set; each feature's enable (defaulting per the feature spec) gates one
# upstream `services.*`; the fragments mkMerge so multiple features can
# touch `services.*` without clobbering. Hand-typing that skeleton per
# bundle is drift — mkServiceBundle generates it from one typed spec.
#
# The emitted module is NixOS class-tagged (core.tag "nixos"): a bundle
# cannot be evaluated under another module class (parse-time rejection via
# evalModules `class`). pkgs never appears at import time — it binds late,
# as a module argument; each feature's `config` is a plain
# nixos-config-fragment function `cfgFeature -> { services.<upstream> = …;
# }` resolved INSIDE the emitted config where cfg exists.
#
# Exports (pure { lib }, zero pkgs):
#
#   mkServiceBundle :: {
#     name        :: str (required) — bundle name (option leaf);
#     description :: str (required) — human description (bundle enable text);
#     namespace   ? "services"      — dotted option root, e.g.
#                                     "blackmatter.components";
#     features    :: attrsOf featureSpec (required, NON-EMPTY) where
#       featureSpec = {
#         description ? <featureName> — feature enable option text;
#         default     ? false        — whether THIS feature enables when the
#                                      bundle is enabled (the feature
#                                      enable option's default);
#         config      :: cfgFeature -> nixos-config-fragment
#                                    — the upstream services.* this feature
#                                      renders; cfgFeature is the resolved
#                                      <ns>.<name>.<feature> config (carries
#                                      `enable` + the feature's extra
#                                      options). Required; typed throw if
#                                      missing or not a function;
#         options     ? { }          — extra typed option declarations for
#                                      this feature, landing under
#                                      <ns>.<name>.<feature>.* (raw mkOption
#                                      attrs, merged beside the generated
#                                      `enable`). Typed throw if not attrs;
#       };
#   } -> {
#     nixos :: class-tagged module —
#       options.<ns>.<name>.enable = mkEnableOption description;
#       options.<ns>.<name>.<feature>.enable = mkEnableOption (per
#         featureSpec.description) with default = featureSpec.default,
#         merged with featureSpec.options;
#       config = mkIf cfg.enable (mkMerge [
#         (per feature: mkIf cfg.<feature>.enable
#                         (feature.config cfg.<feature>)) ]);
#     meta :: {
#       name; optionPath = splitString "." namespace ++ [ name ];
#       features = [ featureNames ] (sorted); kind = "service-bundle";
#     };
#   }
#
# Throws (every message prefixed "iroha.service-bundle.mkServiceBundle: "):
#   - `name` or `description` missing (or non-string);
#   - `features` missing, not an attrset, or empty;
#   - a featureSpec is not an attrset;
#   - a featureSpec is missing `config`, or `config` is not a function;
#   - a featureSpec's `options` is present but not an attrset.
{ lib }:
let
  core = import ./core.nix { inherit lib; };

  mkServiceBundle =
    args:
    let
      name =
        let
          n = args.name or (throw "iroha.service-bundle.mkServiceBundle: `name` (str) is required.");
        in
        if builtins.isString n then
          n
        else
          throw "iroha.service-bundle.mkServiceBundle: `name` must be a string, got ${builtins.typeOf n}.";

      description =
        let
          d =
            args.description
              or (throw "iroha.service-bundle.mkServiceBundle: `description` (str) is required.");
        in
        if builtins.isString d then
          d
        else
          throw "iroha.service-bundle.mkServiceBundle: `description` must be a string, got ${builtins.typeOf d}.";

      namespace = args.namespace or "services";

      featuresRaw =
        args.features
          or (throw "iroha.service-bundle.mkServiceBundle: `features` (attrsOf featureSpec, non-empty) is required.");

      features =
        if !(builtins.isAttrs featuresRaw) then
          throw "iroha.service-bundle.mkServiceBundle: `features` must be an attrset, got ${builtins.typeOf featuresRaw}."
        else if featuresRaw == { } then
          throw "iroha.service-bundle.mkServiceBundle: `features` must be non-empty — a bundle with no features renders nothing."
        else
          featuresRaw;

      optionPath = lib.splitString "." namespace ++ [ name ];
      featureNames = builtins.attrNames features; # attrNames is sorted

      # Validate + normalize a single featureSpec. Validation is forced at
      # construction (via the seq below) so a bad feature throws eagerly,
      # not at first config read.
      normalizeFeature =
        fname: spec:
        if !(builtins.isAttrs spec) then
          throw "iroha.service-bundle.mkServiceBundle: feature '${fname}' must be an attrset (featureSpec), got ${builtins.typeOf spec}."
        else
          let
            cfgFn =
              spec.config
                or (throw "iroha.service-bundle.mkServiceBundle: feature '${fname}' is missing `config` (cfgFeature -> nixos-config-fragment).");
            extraOptions = spec.options or { };
          in
          if !(builtins.isFunction cfgFn) then
            throw "iroha.service-bundle.mkServiceBundle: feature '${fname}'.config must be a function (cfgFeature -> nixos-config-fragment), got ${builtins.typeOf cfgFn}."
          else if !(builtins.isAttrs extraOptions) then
            throw "iroha.service-bundle.mkServiceBundle: feature '${fname}'.options must be an attrset of option declarations, got ${builtins.typeOf extraOptions}."
          else
            {
              description = spec.description or fname;
              default = spec.default or false;
              config = cfgFn;
              options = extraOptions;
            };

      normFeatures = lib.mapAttrs normalizeFeature features;

      # Force every feature's validation at WHNF so malformed specs throw at
      # construction time.
      forcedFeatures = lib.foldl' (acc: fname: builtins.seq normFeatures.${fname} acc) true featureNames;

      # Per-feature option island: the generated `enable` (default from the
      # featureSpec) merged with the feature's extra typed options.
      featureOptionIsland =
        fname: spec:
        {
          enable =
            lib.mkEnableOption spec.description
            // {
              default = spec.default;
            };
        }
        // spec.options;

      bundleOptions = {
        enable = lib.mkEnableOption description;
      }
      // lib.mapAttrs featureOptionIsland normFeatures;

      module =
        { config, ... }:
        let
          cfg = lib.getAttrFromPath optionPath config;
        in
        {
          options = lib.setAttrByPath optionPath bundleOptions;

          config = lib.mkIf cfg.enable (
            lib.mkMerge (
              map (fname: lib.mkIf cfg.${fname}.enable (normFeatures.${fname}.config cfg.${fname})) featureNames
            )
          );
        };

      meta = {
        inherit name optionPath;
        features = featureNames;
        kind = "service-bundle";
      };
    in
    builtins.seq name (
      builtins.seq description (
        builtins.seq forcedFeatures {
          nixos = core.tag "nixos" {
            _file = "<iroha:service-bundle:${name}>";
            imports = [ module ];
          };
          inherit meta;
        }
      )
    );
in
{
  inherit mkServiceBundle;
}
