# iroha.wrapped-package — L1: the typed wrapper chokepoint.
#
# One spec → one wrapped derivation. Subsumes the six hand-rolled wrapper
# idioms scattered across the fleet (symlinkJoin+wrapProgram PATH-pin,
# multicall symlink farms, binary rename, env-export wrappers, bare
# makeWrapper launchers) and wrapper-manager-the-dependency (its spec shape
# is adopted; the input is skipped). The ONLY generated bash is the
# postBuild script, and it is COMPILED from the typed spec through
# lib.escapeShellArg(s) — never authored. The normalized spec rides along
# as passthru.iroha.wrapSpec: closed-loop round-trip auditability — every
# wrapped drv carries the pure data it was compiled from, so "where did
# this wrapper come from?" is an attrset read, never a research question.
#
# Exports (pure { lib }, zero pkgs at import time — pkgs binds late, as an
# explicit required argument of mkWrappedPackage):
#
#   mkWrappedPackage :: {
#     pkgs          (required) — late-bound package set; supplies
#                     symlinkJoin + makeWrapper;
#     basePackage   (required) — the drv being wrapped;
#     name          ? basePackage.pname or basePackage.name (else typed
#                     throw) — the wrapper drv is named "<name>-wrapped";
#     binary        ? basePackage.meta.mainProgram or name — the
#                     bin/<binary> being wrapped;
#     prependFlags  ? [ ] — listOf str, compiled to ONE --add-flags word
#                     (injected BEFORE user args);
#     appendFlags   ? [ ] — listOf str, compiled to ONE --append-flags word
#                     (injected AFTER user args);
#     env           ? { } — attrsOf (str | { value :: str, force ? false });
#                     a plain str means force = false; force → --set,
#                     else --set-default. Compiled in sorted-name order
#                     (deterministic output);
#     pathAdd       ? [ ] — listOf drv, compiled to
#                     --prefix PATH : <drv>/bin:<drv>/bin…;
#     rename        ? null — nullOr str: expose the wrapped binary under
#                     this name instead (compiled as mv + wrapProgram on
#                     the new name);
#     multicall     ? [ ] — listOf str: extra bin/<name> symlinks to the
#                     (possibly renamed) wrapper, linked AFTER the wrap;
#   } -> drv = pkgs.symlinkJoin {
#     name              = "<name>-wrapped";
#     paths             = [ basePackage ];
#     nativeBuildInputs = [ pkgs.makeWrapper ];
#     postBuild         = <compiled: mv (rename only) → wrapProgram + flag
#                         pieces → ln -s per multicall entry>;
#     passthru          = basePackage.passthru (preserved) with
#                         iroha.wrapSpec = { name, binary, exposed, rename,
#                           prependFlags, appendFlags,
#                           env (normalized to { value, force }),
#                           pathBins (the compiled <drv>/bin strings),
#                           multicall }
#                         (an existing passthru.iroha attrset is merged
#                         under, never clobbered);
#     meta              = basePackage.meta // { mainProgram = exposed }
#                         where exposed = rename-or-binary;
#   }
#
# Throws (every message prefixed "iroha.wrapped-package.mkWrappedPackage: "):
#   - `pkgs` missing;
#   - `basePackage` missing;
#   - `name` underivable (no explicit name, no pname / name on basePackage);
#   - an `env` value that is neither a string nor an attrset with a
#     string `value` (force ? false);
#   - `rename` equal to `binary` (a rename to the same name is pointless).
{ lib }:
let
  prefix = "iroha.wrapped-package.mkWrappedPackage";

  mkWrappedPackage =
    args:
    let
      pkgs = args.pkgs or (throw "${prefix}: `pkgs` (the late-bound package set) is required.");
      basePackage =
        args.basePackage or (throw "${prefix}: `basePackage` (the drv being wrapped) is required.");

      name =
        args.name or (basePackage.pname or (basePackage.name
          or (throw "${prefix}: `name` is underivable — pass `name` explicitly, or give `basePackage` a pname/name.")
        )
        );
      binary = args.binary or (basePackage.meta.mainProgram or name);

      prependFlags = args.prependFlags or [ ];
      appendFlags = args.appendFlags or [ ];
      pathAdd = args.pathAdd or [ ];
      multicall = args.multicall or [ ];

      rename =
        let
          r = args.rename or null;
        in
        if r == null then
          null
        else if r == binary then
          throw "${prefix}: `rename` ('${toString r}') equals `binary` — a rename to the same name is pointless; drop `rename`."
        else
          r;

      # The exposed binary name: what the wrapper script is called, what
      # multicall links point at, what meta.mainProgram advertises.
      exposed = if rename != null then rename else binary;

      # env normalization: plain str → { value, force = false }; attrset
      # must carry a string `value` (force defaults false). The normalized
      # form is both the compile input and the wrapSpec audit record.
      normalizeEnvValue =
        envName: v:
        if builtins.isString v then
          {
            value = v;
            force = false;
          }
        else if builtins.isAttrs v && builtins.isString (v.value or null) then
          {
            value = v.value;
            force = v.force or false;
          }
        else
          throw "${prefix}: env.${envName} must be a string or { value :: str, force ? false } — got ${builtins.typeOf v}${lib.optionalString (builtins.isAttrs v) " with keys [ ${lib.concatStringsSep ", " (builtins.attrNames v)} ]"}.";
      env = lib.mapAttrs normalizeEnvValue (args.env or { });

      # PATH pieces: one "<drv>/bin" string per pathAdd entry (makeBinPath
      # resolves the bin output per drv), joined for the --prefix value.
      pathBins = map (d: lib.makeBinPath [ d ]) pathAdd;
      binPath = lib.concatStringsSep ":" pathBins;

      # ── the compiler ──────────────────────────────────────────────────
      # makeWrapper flag pieces as a pure argv list, then ONE escape pass
      # (lib.escapeShellArgs) renders them. The --add-flags/--append-flags
      # values are themselves pre-escaped flag strings (escapeShellArgs of
      # the typed list) so each lands as ONE shell word for wrapProgram —
      # the standard double-escape contract, compiled not hand-quoted.
      flagPieces =
        lib.optionals (prependFlags != [ ]) [
          "--add-flags"
          (lib.escapeShellArgs prependFlags)
        ]
        ++ lib.optionals (appendFlags != [ ]) [
          "--append-flags"
          (lib.escapeShellArgs appendFlags)
        ]
        ++ lib.concatMap (
          n:
          let
            e = env.${n};
          in
          [
            (if e.force then "--set" else "--set-default")
            n
            e.value
          ]
        ) (builtins.attrNames env)
        ++ lib.optionals (pathAdd != [ ]) [
          "--prefix"
          "PATH"
          ":"
          binPath
        ];

      # "$out" must survive as a shell variable, so the bin path is
      # compiled as the literal "$out/bin/" adjacent to the escaped name
      # (adjacent shell words concatenate).
      binRef = n: "\"$out/bin/\"${lib.escapeShellArg n}";

      wrapLine =
        "wrapProgram ${binRef exposed}"
        + lib.optionalString (flagPieces != [ ]) " ${lib.escapeShellArgs flagPieces}";

      postBuild = lib.concatStringsSep "\n" (
        lib.optional (rename != null) "mv ${binRef binary} ${binRef rename}"
        ++ [ wrapLine ]
        ++ map (m: "ln -s ${binRef exposed} ${binRef m}") multicall
      );

      # The normalized spec as pure data — the closed-loop audit record.
      wrapSpec = {
        inherit
          name
          binary
          exposed
          rename
          prependFlags
          appendFlags
          env
          pathBins
          multicall
          ;
      };
    in
    pkgs.symlinkJoin {
      name = "${name}-wrapped";
      paths = [ basePackage ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      inherit postBuild;
      passthru = (basePackage.passthru or { }) // {
        iroha = (basePackage.passthru.iroha or { }) // {
          inherit wrapSpec;
        };
      };
      meta = (basePackage.meta or { }) // {
        mainProgram = exposed;
      };
    };
in
{
  inherit mkWrappedPackage;
}
