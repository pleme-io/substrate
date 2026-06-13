# iroha.activation-hook — L2: one typed enable → one idempotent OS
# activation-script step, projected onto NixOS and nix-darwin.
#
# The recurring fleet shape this letter standardizes: a single boolean
# ("disable Determinate's nixd shim", "materialize an admin-users record",
# "grant passwordless sudo", "apply a pmset power profile", "sync the
# macOS app catalog", "seed the attic default cache server", "materialize
# a home directory") that, when flipped, must run ONE idempotent shell
# step during system activation. Today every such step is hand-wired into
# `system.activationScripts.<name>` per node — the option surface, the
# `mkIf cfg.enable` gate, and the cross-platform NixOS-vs-darwin shape
# difference are re-typed each time. This letter generates all three from
# one spec.
#
# It composes the lower letters: the option skeleton (enable + extra
# option declarations) is the same three-part shape iroha.option-surface
# emits, and the class tagging is iroha.core.tag. Only the activation
# body is novel — and it is the ONE sanctioned bash in the alphabet (the
# OS activation phase is a shell phase; callers keep the body idempotent,
# the rule magma/★★ MAGMA-NATIVE carves out for genuine OS exec). pkgs
# never appears at import time — it binds late, inside the emitted
# fragments where the `script` function receives { cfg, pkgs, lib }.
#
# The NixOS-vs-darwin shape difference, made explicit (tier-honest):
#   - NixOS  `system.activationScripts.<name>` accepts the RICHER
#     submodule { text; deps; } — so the emitted nixos module sets BOTH
#     and `deps` orders the step after named phases (e.g. [ "users" ]).
#   - nix-darwin `system.activationScripts.<name>.text` is a flat string
#     on its predefined keys; arbitrary keys take `{ text = …; }`. The
#     emitted darwin module therefore sets ONLY `.text`. `deps` is a
#     NixOS-only richness; on darwin it is silently inapplicable (the
#     darwin activation runner has a fixed phase order). This asymmetry
#     is documented, not papered over.
#
# Exports (pure { lib }, zero pkgs):
#
#   mkActivationHook :: {
#     name        :: str (required) — activationScripts attr key on every
#                    platform + the option leaf;
#     description :: str (required) — enable option text + script comment;
#     namespace   ? "system"        — dotted option root (the enable +
#                    extraOptions land at <namespace>.<name>);
#     enable      ? true            — emit `enable = mkEnableOption description`
#                    (false ⇒ no enable option AND the body is emitted
#                    UNCONDITIONALLY — an always-on activation step);
#     extraOptions ? { } | (lib: attrs) — extra option declarations merged
#                    under the option root (function form receives lib),
#                    e.g. a `users = mkOption { … }` the script reads;
#     script      ? { cfg, pkgs, lib } -> str — the idempotent shell body,
#                    generated with cfg/pkgs/lib in scope (cfg is the
#                    config at <namespace>.<name>); EXACTLY ONE of
#                    script/text;
#     text        ? null            — a STATIC body string, the alternative
#                    to `script` when the body needs no cfg/pkgs; EXACTLY
#                    ONE of script/text;
#     deps        ? [ ]             — listOf str: NixOS activationScript
#                    ordering deps (e.g. [ "users" ] to run after the
#                    users phase); NixOS-only (see asymmetry note above).
#   } -> {
#     nixos  :: class-tagged module ({ lib, pkgs, config, ... }) —
#               options = <enable + extraOptions at the option root>;
#               config = mkIf <gate> {
#                 system.activationScripts.<name> = { text = <body>; deps = deps; };
#               };  where <gate> = cfg.enable when enable, else literal true;
#     darwin :: class-tagged module ({ lib, pkgs, config, ... }) — same
#               option surface; config = mkIf <gate> {
#                 system.activationScripts.<name>.text = <body>;
#               };  (no deps — flat-text darwin shape);
#     meta   :: { name, optionPath :: [str], enablePath :: [str],
#                 kind = "activation-hook" };
#   }
#
# Throws (every message prefixed "iroha.activation-hook.mkActivationHook: "):
#   - `name` / `description` missing;
#   - both `script` and `text` set, or neither;
#   - `script` set but not a function; `text` set but not a string;
#   - `deps` not a list;
#   - `extraOptions` neither attrset nor function.
{ lib }:
let
  core = import ./core.nix { inherit lib; };
  inherit (lib) mkIf mkEnableOption optionalAttrs;

  mkActivationHook =
    args:
    let
      name = args.name or (throw "iroha.activation-hook.mkActivationHook: `name` (str) is required.");
      description =
        args.description
          or (throw "iroha.activation-hook.mkActivationHook: `description` (str) is required.");
      namespace = args.namespace or "system";
      enable = args.enable or true;
      extraOptions = args.extraOptions or { };
      deps = args.deps or [ ];

      hasScript = args ? script;
      hasText = args ? text && args.text != null;

      # Exactly-one-of discipline: the body comes from a generator fn OR a
      # static string, never both, never neither. Resolved to a single
      # `bodyFor { cfg, pkgs }` -> str so the two emitted modules share one
      # body-resolution path.
      bodyFor =
        if hasScript && hasText then
          throw "iroha.activation-hook.mkActivationHook: pass exactly one of `script` (fn) or `text` (static str) — got both."
        else if !hasScript && !hasText then
          throw "iroha.activation-hook.mkActivationHook: pass exactly one of `script` ({ cfg, pkgs, lib } -> str) or `text` (static str) — got neither."
        else if hasScript then
          if !(builtins.isFunction args.script) then
            throw "iroha.activation-hook.mkActivationHook: `script` must be a function { cfg, pkgs, lib } -> str — got ${builtins.typeOf args.script}."
          else
            { cfg, pkgs }: args.script { inherit cfg pkgs lib; }
        else if !(builtins.isString args.text) then
          throw "iroha.activation-hook.mkActivationHook: `text` must be a string — got ${builtins.typeOf args.text}."
        else
          _ignored: args.text;

      depsChecked =
        if !(builtins.isList deps) then
          throw "iroha.activation-hook.mkActivationHook: `deps` must be a list of activation-phase names (str) — got ${builtins.typeOf deps}."
        else
          deps;

      optionPath = lib.splitString "." namespace ++ [ name ];
      enablePath = optionPath ++ [ "enable" ];

      extraAttrs =
        if builtins.isFunction extraOptions then
          extraOptions lib
        else if builtins.isAttrs extraOptions then
          extraOptions
        else
          throw "iroha.activation-hook.mkActivationHook: `extraOptions` must be an attrset or a function (lib -> attrs) — got ${builtins.typeOf extraOptions}.";

      optionsBlock = lib.setAttrByPath optionPath (
        optionalAttrs enable { enable = mkEnableOption description; } // extraAttrs
      );

      # The config-at-root, gate, and body are computed once per emitted
      # module from its own `config`/`pkgs` args (cfg/pkgs only exist
      # inside the module). enable=false ⇒ no enable option ⇒ the step is
      # unconditional (literal-true gate).
      cfgAt = config: lib.attrByPath optionPath { } config;
      gateOf = config: if enable then (cfgAt config).enable or false else true;

      nixosModule =
        {
          lib,
          pkgs,
          config,
          ...
        }:
        {
          options = optionsBlock;
          config = mkIf (gateOf config) {
            system.activationScripts.${name} = {
              text = bodyFor {
                cfg = cfgAt config;
                inherit pkgs;
              };
              deps = depsChecked;
            };
          };
        };

      darwinModule =
        {
          lib,
          pkgs,
          config,
          ...
        }:
        {
          options = optionsBlock;
          config = mkIf (gateOf config) {
            # nix-darwin: arbitrary activationScripts keys take a flat
            # `.text` — no `deps` (the darwin runner phase order is fixed).
            system.activationScripts.${name}.text = bodyFor {
              cfg = cfgAt config;
              inherit pkgs;
            };
          };
        };

      meta = {
        inherit name optionPath enablePath;
        kind = "activation-hook";
      };
    in
    {
      nixos = core.tag core.classes.nixos nixosModule;
      darwin = core.tag core.classes.darwin darwinModule;
      inherit meta;
    };
in
{
  inherit mkActivationHook;
}
