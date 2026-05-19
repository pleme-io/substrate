# mk-script-binary.nix — wrap a tatara-lisp script as a system-installable
# binary, materializing its declared dependencies alongside.
#
# This is estante's `uv tool install` equivalent. A script like:
#
#   ;;; --- estante
#   ;;; dependencies:
#   ;;;   - github:MichaelAquilina/zsh-you-should-use@v1.7.4
#   ;;; ---
#   (defload :pkg "zsh-you-should-use")
#   (defalias :name "ysu" :value "echo you should use")
#
# Becomes a derivation that:
#   1. Materializes `zsh-you-should-use` via `mk-shell-env`.
#   2. Wraps the script in a thin launcher that points `$FROSTRC` at
#      a generated rc.lisp containing:
#         (defsource :path "${shellEnv}/shellpkg.lock.lisp")
#         (defsource :path "${script}")
#   3. Exec's `frost --interactive` with that rc.
#
# The wrapper is the only ~3-line shell glue (allowed per the
# "1–3 line composition" carve-out in the NO SHELL directive) — every
# decision is baked into the Nix derivation graph, not the wrapper.
{ pkgs }:
let
  lib = pkgs.lib;
  shellEnvBuilder = (import ./mk-shell-env.nix { inherit pkgs; });
in
{
  # Wrap a script as a permanent binary. Runtime-polymorphic — supports
  # frost-lisp scripts AND vanilla shell (bash / zsh / fish) scripts.
  # The latter satisfy the "no required libraries" invariant: a
  # consumer with only bash on PATH can still install + run the
  # wrapped tool.
  #
  # Required:
  #   name      — installed binary name (e.g. "ysu-tool").
  #   script    — path to the script source. Runtime is derived from
  #               the file extension unless `runtime` is given.
  #
  # Optional:
  #   runtime   — one of "frost" | "bash" | "zsh" | "fish". If absent,
  #               the file extension chooses: `.lisp`/`.tlisp` → frost,
  #               `.bash`/`.sh` → bash, `.zsh` → zsh, `.fish` → fish.
  #   lockfile  — path to shellpkg.lock.nix declaring the script's deps.
  #               Frost runtimes read the lockfile via defsource;
  #               vanilla runtimes source `<materialized>/init.<shell>`
  #               for every locked package. If absent, no env loaded.
  #   frost     — frost binary derivation (only used when runtime = frost).
  #               Defaults to looking up `frost` on the runtime PATH.
  #   extraRcLines — additional setup lines for the generated wrapper.
  mkScriptBinary = {
    name,
    script,
    runtime ? null,
    lockfile ? null,
    frost ? null,
    extraRcLines ? [],
    ...
  }:
    let
      # Detect runtime from the file extension if not explicit.
      extension = lib.toLower (lib.last (lib.splitString "." (toString script)));
      runtimeResolved = if runtime != null then runtime else
        if extension == "tlisp" || extension == "lisp" then "frost"
        else if extension == "bash" || extension == "sh" then "bash"
        else if extension == "zsh" then "zsh"
        else if extension == "fish" then "fish"
        else "frost";

      shellEnv = if lockfile == null
        then null
        else shellEnvBuilder.mkShellEnv {
          inherit lockfile;
          name = "${name}-deps";
        };

      # ── Frost runtime ───────────────────────────────────────────────
      # Generated rc.lisp wires the lockfile + extras + script. Order
      # matters: locks must be visible before defload fires.
      frostRcLines = lib.concatStringsSep "\n" (
        (if shellEnv != null then [
          ''(defsource :path "${shellEnv}/shellpkg.lock.lisp")''
        ] else [])
        ++ extraRcLines
        ++ [ ''(defsource :path "${script}")'' ]
      );
      frostRcFile = pkgs.writeText "${name}.rc.lisp" frostRcLines;
      frostBin = if frost != null then "${frost}/bin/frost" else "frost";
      frostText = ''
        exec ${frostBin} -i -c "$(cat ${frostRcFile})" "$@"
      '';

      # ── Vanilla runtimes ────────────────────────────────────────────
      # Source each locked package's `init.<shell>` before running the
      # user script. The lockfile entries' materialized paths are
      # resolved at wrapper-eval time so the wrapper itself is a
      # standalone shell script — no estante or frost on PATH needed
      # at runtime.
      vanillaEntrypoint =
        if runtimeResolved == "zsh" then "init.zsh"
        else if runtimeResolved == "fish" then "init.fish"
        else "init.bash";
      lockData = if shellEnv != null then
        (import ./lockfile-loader.nix { inherit lib; }).loadLockfile lockfile
      else { packages = []; };
      vanillaSourceLines = lib.concatMapStringsSep "\n" (entry: ''
        if [ -f "${entry.materializedPath or "/dev/null"}/${vanillaEntrypoint}" ]; then
          . "${entry.materializedPath or "/dev/null"}/${vanillaEntrypoint}"
        fi
      '') (lockData.packages or []);
      vanillaText = ''
        ${vanillaSourceLines}
        ${lib.concatStringsSep "\n" extraRcLines}
        exec ${runtimeResolved} "${toString script}" "$@"
      '';

      # ── Wrapper body picked by runtime ──────────────────────────────
      body = if runtimeResolved == "frost" then frostText else vanillaText;

      runtimeInputs =
        lib.optionals (runtimeResolved == "frost" && frost != null) [ frost ];
    in pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = body;

      meta = {
        description = "Wrapped ${runtimeResolved} script: ${name}";
        estante = {
          script = {
            inherit name;
            runtime = runtimeResolved;
            deps = if shellEnv != null then shellEnv.meta.estante.envContents else [];
          };
        };
      };
    };
}
