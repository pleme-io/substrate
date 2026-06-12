# iroha.shim — deprecation shims: option renames, removals, and aliases as
# one typed, class-taggable module surface.
#
# The letter for the moment an option surface moves. Instead of hand-rolling
# mkRenamedOptionModule / mkRemovedOptionModule / mkAliasOptionModule call
# sites per repo, a shim is declared ONCE as data and emitted as a single
# module. Paths are accepted in dotted-string or list-of-strings form and
# normalized + validated EAGERLY — a malformed shim throws the moment the
# returned module is forced, never at some distant evalModules site.
#
# Exports (pure { lib }, zero pkgs):
#
#   mkDeprecationShim :: {
#     for     ? null  — null | "nixos"|"darwin"|"homeManager"|"flake" (any
#                       core.classes name). Non-null wraps the result with
#                       core.tag, so a shim authored for one module class is
#                       parse-time rejected by every other class's
#                       evalModules (unknown class -> core.tag's typed throw).
#     renames ? [ ]   — listOf { from :: path; to :: path; } ->
#                       lib.mkRenamedOptionModule per entry (setting `from`
#                       forwards to `to` AND emits a deprecation warning).
#     removed ? [ ]   — listOf { path :: path; reason :: str (REQUIRED); } ->
#                       lib.mkRemovedOptionModule per entry (setting `path`
#                       throws, carrying `reason`; leaving it unset stays
#                       evaluable). The target universe must declare the
#                       `warnings` + `assertions` options — NixOS, darwin,
#                       and home-manager all do.
#     aliases ? [ ]   — listOf { from :: path; to :: path; } ->
#                       lib.mkAliasOptionModule per entry (SILENT two-way
#                       alias: writes forward, reads mirror, no warning).
#   } -> module { _file = "<iroha:shim>"; imports = [ ...one per entry... ]; }
#
#   path :: dotted str — "a.b.c" -> lib.splitString "." -> [ "a" "b" "c" ]
#         | [str]      — passed through unchanged.
#
#   Typed throws (all EAGER — forcing the returned module surfaces them):
#     iroha.shim.mkDeprecationShim: empty shim (renames, removed, and
#       aliases all empty — a shim that shims nothing is a bug);
#     iroha.shim.mkDeprecationShim: `removed` entry missing `reason`, or
#       `reason` not a string;
#     iroha.shim.mkDeprecationShim: entry missing `from`/`to`/`path`;
#     iroha.shim.<fn>: path neither a dotted string nor a list.
#
#   mkEnableAlias :: { old :: path, new :: path } -> module
#     Sugar for the preset-rename case: one silent lib.mkAliasOptionModule
#     from `old` to `new` — setting the old enable path flips the new one.
#     Same path forms, same eager path validation, same "<iroha:shim>" _file.
{ lib }:
let
  core = import ./core.nix { inherit lib; };

  normalizePath =
    fn: p:
    if builtins.isString p then
      lib.splitString "." p
    else if builtins.isList p then
      p
    else
      throw "iroha.shim.${fn}: option path must be a dotted string (\"a.b.c\") or a list of strings, got ${builtins.typeOf p}.";

  requireField =
    fn: group: field: entry:
    entry.${field} or (throw "iroha.shim.${fn}: every `${group}` entry requires a `${field}` field.");

  mkDeprecationShim =
    {
      for ? null,
      renames ? [ ],
      removed ? [ ],
      aliases ? [ ],
    }:
    let
      fn = "mkDeprecationShim";
      norm = normalizePath fn;
      normalized = {
        renames = map (r: {
          from = norm (requireField fn "renames" "from" r);
          to = norm (requireField fn "renames" "to" r);
        }) renames;
        removed = map (r: {
          path = norm (requireField fn "removed" "path" r);
          reason =
            let
              reason = requireField fn "removed" "reason" r;
            in
            if builtins.isString reason then
              reason
            else
              throw "iroha.shim.${fn}: `removed` entry `reason` must be a string naming what replaced the option (and why), got ${builtins.typeOf reason}.";
        }) removed;
        aliases = map (a: {
          from = norm (requireField fn "aliases" "from" a);
          to = norm (requireField fn "aliases" "to" a);
        }) aliases;
      };
      # Eager validation: forcing the shim to WHNF surfaces every typed
      # throw above instead of deferring it into a later evalModules.
      guard = builtins.deepSeq normalized true;
      module = {
        _file = "<iroha:shim>";
        imports =
          map (r: lib.mkRenamedOptionModule r.from r.to) normalized.renames
          ++ map (r: lib.mkRemovedOptionModule r.path r.reason) normalized.removed
          ++ map (a: lib.mkAliasOptionModule a.from a.to) normalized.aliases;
      };
    in
    if renames == [ ] && removed == [ ] && aliases == [ ] then
      throw "iroha.shim.mkDeprecationShim: at least one of `renames`, `removed`, `aliases` must be non-empty — an empty shim shims nothing and is a bug."
    else
      builtins.seq guard (if for == null then module else core.tag for module);

  mkEnableAlias =
    { old, new }:
    let
      fn = "mkEnableAlias";
      old' = normalizePath fn old;
      new' = normalizePath fn new;
    in
    builtins.deepSeq [ old' new' ] {
      _file = "<iroha:shim>";
      imports = [ (lib.mkAliasOptionModule old' new') ];
    };
in
{
  inherit mkDeprecationShim mkEnableAlias;
}
