# iroha.conf-checks — L6 proof: assert OPTION VALUES on a BUILT config.
#
# iroha.checks.mkEvalChecks proves properties of BARE expressions; this
# letter proves properties of a BUILT configuration's `.config` — the
# evaluated option tree of a nixosSystem / darwinSystem (or any
# lib.evalModules result). It is a thin harness: given the built
# `.config` attrset and a list of typed path-assertions, it EMITS
# nix-unit `{ expr, expected }` pairs that feed STRAIGHT into
# iroha.mkEvalChecks. It COMPOSES that letter (does not duplicate the
# runTests loop) — the emitted attrset is exactly the `tests` shape
# mkEvalChecks consumes, named "<name>:<dotted-path>".
#
# Why a sibling to mkModuleEvalCheck (checks.nix): mkModuleEvalCheck
# RUNS lib.evalModules itself (module graph under test) and aborts when
# an asserted path does not exist (its `throw` default). mkConfChecks
# takes an ALREADY-BUILT config (the caller did the evalModules /
# nixosSystem) and is REPORT-ORIENTED: a path missing under an
# `expected`/`satisfies` assert yields a FAILING case (expr = a typed
# sentinel marker, NEVER equal to a real expected), not an eval abort —
# so a config audit reports every gap instead of dying on the first.
#
# Each assertSpec carries a `path` plus exactly one of three discriminants:
#   { path; expected   }  — attrByPath path config == expected
#   { path; satisfies  }  — predicate (any -> bool) over the value, == true
#   { path; present    }  — bool: does the path exist AND resolve non-null?
# `present` is the only kind that does NOT fail on a missing path — it
# REPORTS absence (expr = false vs your expected present bool).
#
# Path may be a dotted string ("services.foo.enable") or a list
# ([ "services" "foo" "enable" ]); both normalize to the same case.
# Missing-path detection for expected/satisfies is STRUCTURAL
# (lib.hasAttrByPath — it does not force the leaf value); the leaf is
# forced only when present (the value you are asserting on anyway).
#
# Exports (pure { lib }, zero pkgs):
#
#   mkConfChecks :: {
#     name    :: str (required) — case-name prefix;
#     config  :: attrs (required) — the BUILT `.config` to assert against
#               (e.g. nixosConfigurations.<n>.config);
#     asserts :: [ assertSpec ] (required, NON-EMPTY) where assertSpec =
#         { path :: [str] | dotted-str; expected  :: any }
#       | { path; satisfies :: any -> bool }
#       | { path; present   :: bool };
#   } -> attrsOf { expr, expected }   (feed into iroha.mkEvalChecks tests;
#                                      one case named "<name>:<dotted path>")
#
#   mkConfChecksFor :: {
#     name    :: str (required);
#     configs :: attrsOf builtConfig (required, NON-EMPTY);
#     asserts :: builtConfig -> [ assertSpec ] (required — the per-config
#               assert list; receives each config so assertions can read
#               sibling values);
#   } -> attrsOf { expr, expected }   (names "<name>:<cfgName>:<dotted path>")
#
# Throws (every message prefixed "iroha.conf-checks.<fn>: "):
#   mkConfChecks    — `name`/`config`/`asserts` missing; `asserts` not a
#                     list or empty; an assertSpec with no path; an
#                     assertSpec carrying none of expected/satisfies/present
#                     (or more than one); a `satisfies` that is not a
#                     function; a `present` that is not a bool.
#   mkConfChecksFor — `name`/`configs`/`asserts` missing; `configs` not an
#                     attrset or empty; `asserts` not a function.
{ lib }:
let
  inherit (lib) hasAttrByPath attrByPath;

  # A path the caller never produces — a present/expected value equal to
  # this marker is not a real config value, so using it as the
  # missing-path expr guarantees a FAILING case under expected/satisfies.
  missingMarker = path: "<iroha.conf-checks:MISSING:${lib.concatStringsSep "." path}>";

  normalizePath =
    fn: p:
    if builtins.isList p then
      p
    else if builtins.isString p then
      lib.splitString "." p
    else
      throw "iroha.conf-checks.${fn}: `path` must be a list of strings or a dotted string — got ${builtins.typeOf p}.";

  # One assertSpec -> one nameValuePair { "<prefix>:<dotted>" = {expr,expected}; }.
  assertToCase =
    fn: prefix: config: a:
    let
      path = normalizePath fn (a.path or (throw "iroha.conf-checks.${fn}: every assert needs a `path` ([str] | dotted-str)."));
      caseName = "${prefix}:${lib.concatStringsSep "." path}";

      hasExpected = a ? expected;
      hasSatisfies = a ? satisfies;
      hasPresent = a ? present;
      kindCount = (if hasExpected then 1 else 0) + (if hasSatisfies then 1 else 0) + (if hasPresent then 1 else 0);

      present = hasAttrByPath path config;

      pair =
        if kindCount != 1 then
          throw "iroha.conf-checks.${fn}: assert at path '${lib.concatStringsSep "." path}' must carry EXACTLY one of `expected`, `satisfies`, or `present` — got ${toString kindCount}."
        else if hasPresent then
          if !(builtins.isBool a.present) then
            throw "iroha.conf-checks.${fn}: `present` at path '${lib.concatStringsSep "." path}' must be a bool — got ${builtins.typeOf a.present}."
          else
            {
              # present := path exists AND its value is non-null. Structural
              # existence first (no force); only then force the leaf to test
              # non-null. NEVER fails on a missing path — it REPORTS.
              expr = present && attrByPath path null config != null;
              expected = a.present;
            }
        else if hasSatisfies then
          if !(builtins.isFunction a.satisfies) then
            throw "iroha.conf-checks.${fn}: `satisfies` at path '${lib.concatStringsSep "." path}' must be a function (any -> bool) — got ${builtins.typeOf a.satisfies}."
          else if !present then
            # Missing under a satisfies assert -> failing case (the marker
            # string is not `true`), NOT an eval abort, NOT a predicate call
            # on a sentinel.
            {
              expr = missingMarker path;
              expected = true;
            }
          else
            {
              expr = a.satisfies (attrByPath path null config);
              expected = true;
            }
        else
          # hasExpected
          if !present then
            {
              expr = missingMarker path;
              expected = a.expected;
            }
          else
            {
              expr = attrByPath path null config;
              expected = a.expected;
            };
    in
    lib.nameValuePair caseName pair;

  buildCases =
    fn: prefix: config: asserts:
    if !(builtins.isList asserts) then
      throw "iroha.conf-checks.${fn}: `asserts` must be a list of assertSpec — got ${builtins.typeOf asserts}."
    else if asserts == [ ] then
      throw "iroha.conf-checks.${fn}: `asserts` must be NON-EMPTY — an assertion-free conf check proves nothing."
    else
      lib.listToAttrs (map (assertToCase fn prefix config) asserts);

  mkConfChecks =
    args:
    let
      name = args.name or (throw "iroha.conf-checks.mkConfChecks: `name` (str) is required.");
      config =
        if args ? config then
          args.config
        else
          throw "iroha.conf-checks.mkConfChecks: `config` (attrs — the built `.config` to assert against) is required.";
      asserts =
        args.asserts
          or (throw "iroha.conf-checks.mkConfChecks: `asserts` ([ assertSpec ], non-empty) is required.");
    in
    buildCases "mkConfChecks" name config asserts;

  mkConfChecksFor =
    args:
    let
      name = args.name or (throw "iroha.conf-checks.mkConfChecksFor: `name` (str) is required.");
      configs =
        if args ? configs then
          args.configs
        else
          throw "iroha.conf-checks.mkConfChecksFor: `configs` (attrsOf builtConfig) is required.";
      asserts =
        args.asserts
          or (throw "iroha.conf-checks.mkConfChecksFor: `asserts` (builtConfig -> [ assertSpec ]) is required.");
    in
    if !(builtins.isAttrs configs) then
      throw "iroha.conf-checks.mkConfChecksFor: `configs` must be an attrset of built configs — got ${builtins.typeOf configs}."
    else if configs == { } then
      throw "iroha.conf-checks.mkConfChecksFor: `configs` must be NON-EMPTY — nothing to assert against."
    else if !(builtins.isFunction asserts) then
      throw "iroha.conf-checks.mkConfChecksFor: `asserts` must be a function (builtConfig -> [ assertSpec ]) — got ${builtins.typeOf asserts}."
    else
      lib.concatMapAttrs (
        cfgName: config: buildCases "mkConfChecksFor" "${name}:${cfgName}" config (asserts config)
      ) configs;
in
{
  inherit mkConfChecks mkConfChecksFor;
}
