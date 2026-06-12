# iroha.typed-app — L1: typed flake-app constructor (binary + argv + env).
#
# Replaces the ad-hoc `pkgs.writeShellScript` app-wrapper idiom with one
# typed shape, per the NO SHELL law: the ONLY bash this letter ever emits
# is mechanically compiled from data — `export K=<escaped>` lines followed
# by exactly one shebang-less `exec <program> <escaped argv> "$@"` line,
# every word routed through lib.escapeShellArg(s), never interpolated raw.
# Authored shell logic has no input surface here: argv is a list of
# strings, env is an attrset of strings, and anything that would compile
# to broken or injectable bash is a typed throw instead. When there is
# nothing to bake (argv == [ ] && env == { }) no wrapper exists at all —
# program is the binary's bin path directly (zero-wrapper fast path).
#
# Exports (pure { lib }, zero pkgs at import time — pkgs binds late as a
# field of the FUNCTION argument, and pkgs.writeShellScript is the only
# attribute ever reached, only on the wrapper path):
#
#   mkTypedApp :: {
#     pkgs        (required) — late-bound package set; presence is checked
#                   on every call, the value is only forced when a wrapper
#                   is compiled;
#     name        :: str (required) — app name; the wrapper derivation is
#                   named "<name>-app";
#     binary      (required) — derivation (any outPath-coercible attrset;
#                   program path = "${binary}/bin/<binaryName>")
#                   | str (absolute program path, used verbatim);
#     binaryName  ? name    — bin/ entry used when `binary` is a derivation
#                   (ignored for a string binary);
#     argv        ? [ ]     (listOf str) — baked arguments, escaped one by
#                   one via lib.escapeShellArgs;
#     env         ? { }     (attrsOf str) — baked exports; keys must be
#                   shell identifiers ([A-Za-z_][A-Za-z0-9_]*) so the
#                   compiled `export` line can never be broken bash;
#     description ? name;
#   } -> {
#     type    = "app";
#     program :: str — the direct bin path (zero wrapper) when
#               argv == [ ] && env == { }; otherwise the
#               pkgs.writeShellScript "<name>-app" result, coerced to its
#               store-path string when string-coercible. A non-coercible
#               writeShellScript result (a stub pkgs in a pure-eval test
#               suite) passes through uncoerced so its text stays
#               inspectable;
#     meta    = { name; description; argv; env; } — the typed source of
#               truth the wrapper was compiled from (round-trippable).
#   }
#
# Throws (every message prefixed "iroha.typed-app.mkTypedApp: "):
#   - spec not an attrset;
#   - `pkgs` missing;
#   - `name` missing or not a string;
#   - `binary` missing;
#   - `binary` an attrset without outPath/__toString (not string-coercible,
#     so not a derivation), or neither attrset nor string (e.g. an int);
#   - `argv` not a list, or an argv entry not a string;
#   - `env` not an attrset, an env value not a string, or an env key not a
#     valid shell identifier.
{ lib }:
let
  isCoercibleDrv = b: builtins.isAttrs b && (b ? outPath || b ? __toString);

  envKeyOk = k: builtins.match "[A-Za-z_][A-Za-z0-9_]*" k != null;

  mkTypedApp =
    spec:
    # Eager typed guards: every malformed spec is a typed throw at the call
    # site, never a hard "expected a set" eval error three frames deep.
    if !builtins.isAttrs spec then
      throw "iroha.typed-app.mkTypedApp: spec must be an attrset — got ${builtins.typeOf spec}."
    else if !(spec ? pkgs) then
      throw "iroha.typed-app.mkTypedApp: `pkgs` is required — pkgs binds late (function argument), never at import time."
    else if !(spec ? name) then
      throw "iroha.typed-app.mkTypedApp: `name` (str) is required."
    else if !builtins.isString spec.name then
      throw "iroha.typed-app.mkTypedApp: `name` must be a string — got ${builtins.typeOf spec.name}."
    else if !(spec ? binary) then
      throw "iroha.typed-app.mkTypedApp: `binary` (derivation | absolute program path string) is required."
    else if builtins.isAttrs spec.binary && !isCoercibleDrv spec.binary then
      throw "iroha.typed-app.mkTypedApp: `binary` attrset is not string-coercible (no outPath/__toString — not a derivation); pass a derivation or an absolute program path string."
    else if !(builtins.isString spec.binary || builtins.isAttrs spec.binary) then
      throw "iroha.typed-app.mkTypedApp: `binary` must be a derivation or an absolute program path string — got ${builtins.typeOf spec.binary}."
    else if !builtins.isList (spec.argv or [ ]) then
      throw "iroha.typed-app.mkTypedApp: `argv` must be a list of strings — got ${builtins.typeOf spec.argv}."
    else if !lib.all builtins.isString (spec.argv or [ ]) then
      throw "iroha.typed-app.mkTypedApp: `argv` entries must all be strings — baked arguments are data, never authored shell."
    else if !builtins.isAttrs (spec.env or { }) then
      throw "iroha.typed-app.mkTypedApp: `env` must be an attrset of strings — got ${builtins.typeOf spec.env}."
    else
      let
        env = spec.env or { };
        badEnvValues = builtins.attrNames (lib.filterAttrs (_: v: !builtins.isString v) env);
        badEnvKeys = builtins.filter (k: !envKeyOk k) (builtins.attrNames env);
      in
      if badEnvValues != [ ] then
        throw "iroha.typed-app.mkTypedApp: env values must be strings — env.${builtins.head badEnvValues} is ${builtins.typeOf env.${builtins.head badEnvValues}}."
      else if badEnvKeys != [ ] then
        throw "iroha.typed-app.mkTypedApp: env keys must be shell identifiers ([A-Za-z_][A-Za-z0-9_]*) — '${builtins.head badEnvKeys}' would compile to broken bash."
      else
        let
          inherit (spec) pkgs name binary;
          binaryName = spec.binaryName or name;
          argv = spec.argv or [ ];
          description = spec.description or name;

          binPath = if builtins.isString binary then binary else "${binary}/bin/${binaryName}";

          # The whole emitted surface: export lines + one exec line, each
          # word compiled from data through escapeShellArg(s). writeShellScript
          # prepends the shebang itself — the text stays shebang-less.
          exportLines = lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") env;
          execLine = ''exec ${lib.escapeShellArgs ([ binPath ] ++ argv)} "$@"'';
          text = lib.concatStringsSep "\n" (exportLines ++ [ execLine ]);

          needsWrapper = argv != [ ] || env != { };
          wrapper = pkgs.writeShellScript "${name}-app" text;

          program =
            if !needsWrapper then
              binPath
            # Real writeShellScript output is a derivation — coerce to its
            # store-path string (flake app `program` must be a string). A
            # stub result without outPath/__toString passes through
            # uncoerced so pure-eval test suites can inspect the text.
            else if lib.isStringLike wrapper then
              "${wrapper}"
            else
              wrapper;
        in
        {
          type = "app";
          inherit program;
          meta = {
            inherit
              name
              description
              argv
              env
              ;
          };
        };
in
{
  inherit mkTypedApp;
}
