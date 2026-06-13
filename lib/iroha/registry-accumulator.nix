# iroha.registry-accumulator — L2: typed attrsOf entries -> filtered,
# ordered merge into one configuration sink.
#
# The recurring fleet shape this letter standardizes: a set of independently-
# toggleable, typed entries (binary caches, kubeconfig paths, edge-router
# blocklists, substituter mirrors, …) that the operator authors as a named
# attrset — each with its own `enable` switch — and which then fold, in a
# single deterministic pass, into one downstream configuration key. The
# pattern recurs ≥3× across the fleet:
#   - binary-caches  -> nix.settings.substituters       (enabled, sorted)
#   - kubeconfig set  -> KUBECONFIG (colon-joined paths)
#   - edge blocklists -> a router's denylist union
# Every hand-rolled instance re-derives the same three moves: declare a typed
# attrsOf, filter on a per-entry `enable`, fold the survivors (in a stable
# order) into the sink. This letter generates the option surface + the
# filter-and-fold from one typed spec; the consumer authors only the entry
# schema and the `render` that places the survivors into the sink.
#
# It composes the lower letters: core.mkFields builds the per-entry submodule
# options + core.classes/core.tag class-tags the emitted module. pkgs never
# appears at import time — it binds late, only inside the emitted module's
# config (and only if `render` reaches for it). The sink is whatever NixOS
# option `render` writes to; this letter declares NONE of the sink's options
# (the host's real NixOS module — or, under test, a stub universe — owns
# them), it only produces the config fragment that merges into them under
# mkIf cfg.enable.
#
# Determinism: `names` is `builtins.attrNames` of the enabled entries, which
# nix returns sorted by key — so the fold order is stable and reproducible
# regardless of authoring order. `enabledEntries` is the same survivors as an
# attrset (entry name -> the entry's resolved values, `enable` included), for
# renders that key by name rather than iterate the ordered list.
#
# Exports (pure { lib }, zero pkgs):
#
#   mkRegistryAccumulator :: {
#     name        :: str (required) — accumulator name (option leaf);
#     description :: str (required) — human description (bundle enable text);
#     namespace   ? "programs"      — dotted option root: <ns>.<name>;
#     entry       :: attrsOf fieldSpec (required) — the per-entry typed
#                   schema (core.mkFields shape). Every entry implicitly gains
#                   an `enable` bool (default true) UNLESS the schema already
#                   declares a field named `enable` (then the schema's own
#                   `enable` is honored verbatim — its type + default win);
#     render      :: { enabledEntries :: attrsOf <entry-values>;   — survivors
#                                       (entry whose resolved `enable` != false),
#                                       keyed by entry name, each carrying its
#                                       resolved field values incl. `enable`;
#                      names :: [ str ];                            — sorted
#                                       names of the survivors (stable fold
#                                       order); }
#                   -> nixos-config-fragment — how the survivors fold into the
#                   sink, e.g. { nix.settings.substituters = map (n:
#                   enabledEntries.${n}.url) names; }. Evaluated INSIDE the
#                   emitted module's config (lib/pkgs/config in scope via the
#                   surrounding module args is NOT passed — render is a pure
#                   function of the two survivor projections; reach for pkgs by
#                   making `render` close over nothing and letting the host
#                   module merge pkgs-derived values separately, or pass the
#                   fragment plain attrs);
#   } -> {
#     nixos :: nixos-class-tagged module —
#               options.<ns>.<name>.enable  = mkEnableOption description (the
#                 bundle switch; whole accumulator off when false);
#               options.<ns>.<name>.entries = attrsOf (submodule {
#                 options = entry-schema ++ { enable = bool, default true }; });
#               config = mkIf cfg.enable (render {
#                 enabledEntries = entries with enable != false;
#                 names = sorted names of those; });
#     meta  :: { name; optionPath :: [str]; entriesPath :: [str];
#               enablePath :: [str]; kind = "registry-accumulator"; };
#   }
#
# Throws (every message prefixed "iroha.registry-accumulator.<fn>: "):
#   mkRegistryAccumulator —
#     - `name` (str) missing;
#     - `description` (str) missing;
#     - `entry` (attrsOf fieldSpec) missing, or not an attrset;
#     - `render` missing, or not a function;
#     - `namespace` present but not a string.
{ lib }:
let
  core = import ./core.nix { inherit lib; };
  inherit (lib) types mkOption mkIf;
in
{
  mkRegistryAccumulator =
    args:
    let
      name =
        args.name
          or (throw "iroha.registry-accumulator.mkRegistryAccumulator: `name` (str) is required.");
      description =
        args.description
          or (throw "iroha.registry-accumulator.mkRegistryAccumulator: `description` (str) is required.");

      namespace =
        let
          ns = args.namespace or "programs";
        in
        if !(builtins.isString ns) then
          throw "iroha.registry-accumulator.mkRegistryAccumulator: `namespace` must be a dotted string (option root) — got ${builtins.typeOf ns}."
        else
          ns;

      entry =
        let
          e =
            args.entry
              or (throw "iroha.registry-accumulator.mkRegistryAccumulator: `entry` (attrsOf fieldSpec — the per-entry typed schema) is required.");
        in
        if !(builtins.isAttrs e) then
          throw "iroha.registry-accumulator.mkRegistryAccumulator: `entry` must be an attrset of fieldSpecs (core.mkFields shape) — got ${builtins.typeOf e}."
        else
          e;

      render =
        let
          r =
            args.render
              or (throw "iroha.registry-accumulator.mkRegistryAccumulator: `render` ({ enabledEntries, names } -> nixos-config-fragment) is required.");
        in
        if !(builtins.isFunction r) then
          throw "iroha.registry-accumulator.mkRegistryAccumulator: `render` must be a function { enabledEntries, names } -> nixos-config-fragment — got ${builtins.typeOf r}."
        else
          r;

      optionPath = lib.splitString "." namespace ++ [ name ];
      entriesPath = optionPath ++ [ "entries" ];
      enablePath = optionPath ++ [ "enable" ];

      # Per-entry `enable` is implicit (default true) UNLESS the caller's
      # schema already declares one — then theirs wins verbatim. The merged
      # schema feeds core.mkFields, so every field — incl. the synthesized
      # `enable` — is a typed mkOption inside the submodule.
      entryHasEnable = entry ? enable;
      entrySchema =
        (lib.optionalAttrs (!entryHasEnable) {
          enable = {
            type = "bool";
            default = true;
            description = "Whether this ${name} entry participates in the merge.";
          };
        })
        // entry;

      entrySubmodule = types.submodule {
        options = core.mkFields entrySchema;
      };

      module =
        { config, ... }:
        let
          cfg = lib.getAttrFromPath optionPath config;
          # Survivors: entries whose resolved `enable` is not false. The
          # submodule guarantees `enable` exists (synthesized default true or
          # the caller's own), so `e.enable` is always present.
          enabledEntries = lib.filterAttrs (_: e: e.enable != false) cfg.entries;
          # attrNames returns keys sorted — the deterministic fold order.
          names = builtins.attrNames enabledEntries;
        in
        {
          options = lib.setAttrByPath optionPath {
            enable = lib.mkEnableOption description;
            entries = mkOption {
              type = types.attrsOf entrySubmodule;
              default = { };
              description = "Typed ${name} entries; the enabled ones fold into the sink. ${description}";
            };
          };
          config = mkIf cfg.enable (render { inherit enabledEntries names; });
        };
    in
    {
      nixos = core.tag core.classes.nixos module;
      meta = {
        inherit name optionPath entriesPath enablePath;
        kind = "registry-accumulator";
      };
    };
}
