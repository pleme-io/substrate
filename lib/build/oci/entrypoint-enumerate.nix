# entrypoint-enumerate.nix — the STATIC half of the distroless discovery
# mechanism (the org CLAUDE.md's "enumerated bare-invoked tools").
#
# ═══════════════════════════════════════════════════════════════════════
# What it does
# ═══════════════════════════════════════════════════════════════════════
#
# Given an entrypoint / wrapper shell script, deterministically list the
# EXTERNAL commands it bare-invokes (bare command names that resolve via
# PATH), minus shell builtins and keywords. That list SEEDS the toolset:
# map each command to a catalog bundle (`mkdir` → `coreutils`, `sed` →
# `textproc`) and declare `entrypointTools = [ those-bundles ]` on
# `mkDistrolessImage`. The BOOT-CHECK (run the image, read the crash) is
# the empirical confirm loop that closes any residual the static pass
# missed — see the methodology in theory/NIX-HARDENING.md §III.4.
#
# This is a pure Nix function (no derivation, no IFD, no shell) — it reads
# a script's text and reasons about it with string ops only, so it runs at
# eval time and can drive the catalog selection directly.
#
# ═══════════════════════════════════════════════════════════════════════
# Tier-honest: heuristic seed, not a full shell parser
# ═══════════════════════════════════════════════════════════════════════
#
# This is a COMMAND-POSITION heuristic, not a POSIX-shell grammar. It:
#   - splits the script into simple-command segments on the separators
#     that begin a new command context (newline ; | & && || ` $( ) ( { });
#   - per segment, drops leading env-assignments, redirections and
#     transparent prefixes (exec/command/env/sudo/nohup/time + the
#     control keywords then/do/else/elif that can lead a split segment);
#   - classifies the first remaining word: a lowercase-ish bare identifier
#     that is NOT a builtin/keyword, NOT a path (`/…`, `./…`), NOT a
#     variable/quoted (`$…`, `"…`), NOT an option (`-…`) → an external
#     command.
#
# It deliberately OVER- rather than under-reports at the margins (a false
# positive costs one extra reviewed tool; a false negative costs a boot
# crash) and does NOT parse heredocs, `eval`'d strings, or commands built
# by variable expansion. Those, and anything it misses, are caught by the
# boot-check. Treat its output as a seed to review, not gospel.
{ lib }:

let
  # ── Shell builtins + keywords (never external, never gathered) ────────
  # POSIX + bash/dash common builtins, control keywords, and the test/
  # grouping tokens. A first-word here means the segment invokes no
  # external command.
  builtinsAndKeywords = [
    # control keywords
    "if" "then" "else" "elif" "fi" "for" "while" "until" "do" "done"
    "case" "esac" "in" "function" "select" "time" "coproc"
    # grouping / test tokens
    "[" "[[" "]" "]]" "{" "}" "!" "((" "))"
    # POSIX/bash builtins
    "set" "unset" "export" "readonly" "local" "declare" "typeset" "shift"
    "eval" "exit" "return" "break" "continue" "trap" "wait" "read" "echo"
    "printf" "test" "true" "false" "cd" "pwd" ":" "." "source" "alias"
    "unalias" "type" "hash" "umask" "ulimit" "getopts" "let" "jobs" "fg"
    "bg" "kill" "disown" "enable" "mapfile" "readarray" "pushd" "popd"
    "dirs" "suspend" "caller" "times" "help" "logout" "history" "fc"
    "bind" "compgen" "complete" "compopt" "shopt" "command" "builtin"
  ];

  # Transparent prefixes: a command RUNNER whose first argument is itself
  # the command we care about. `exec mysqld …` needs `mysqld`, not `exec`.
  # (Control keywords then/do/else/elif can lead a split segment the same
  # way and are skipped identically.)
  transparentPrefixes = [
    "exec" "command" "builtin" "nohup" "time" "sudo" "env" "then" "do"
    "else" "elif" "\\"
  ];

  hasPrefixAny = prefixes: s: lib.any (p: lib.hasPrefix p s) prefixes;

  # Is `w` an env assignment leading a command? (`FOO=bar cmd`)
  isAssignment = w:
    let m = builtins.match "[A-Za-z_][A-Za-z0-9_]*=.*" w;
    in m != null;

  # Is `w` a redirection token? (`>f` `>>f` `2>f` `<f` `&>f`)
  isRedirection = w:
    (builtins.match "[0-9]*[<>].*" w) != null || lib.hasPrefix "&>" w;

  # A bare external-command NAME: starts with a letter, then
  # letters/digits/_ . + - (covers node_exporter, clickhouse-server,
  # barman-cloud, x.y). Excludes paths (contain `/`), vars (`$`), quotes,
  # options (`-…`).
  isCommandName = w:
    (builtins.match "[A-Za-z][A-Za-z0-9_.+-]*" w) != null;

  isSkippablePrefix = w:
    isAssignment w || isRedirection w || hasPrefixAny transparentPrefixes w
    # bare, whole-token transparent words (exec, env, …) already matched by
    # hasPrefixAny; also skip a leading `!` negation token.
    || w == "!";

  # First external command in one already-split simple-command segment,
  # or null. Walks past skippable leading tokens, then classifies.
  firstCommandInWords = words:
    let
      go = ws:
        if ws == [] then null
        else let
          w = builtins.head ws;
          rest = builtins.tail ws;
        in
          if w == "" then go rest
          else if isSkippablePrefix w then go rest
          # a builtin/keyword first-word ⇒ no external command here
          else if builtins.elem w builtinsAndKeywords then null
          # path / variable / quoted / option first-word ⇒ not a bare tool
          else if hasPrefixAny [ "/" "./" "../" "\$" "\"" "'" "`" "-" "#" "~" "%" "@" ] w then null
          else if isCommandName w then w
          else null;
    in go words;

  # A full-line comment or blank line (leading whitespace then `#`, or only
  # whitespace) — dropped BEFORE tokenizing so a parenthetical inside a
  # comment (`# note (foo)`) can't leak `foo` as a false command once `(`
  # is normalized to a separator. Also drops the shebang line.
  isCommentOrBlank = line:
    (builtins.match "[ \t]*#.*" line) != null
    || (builtins.match "[ \t]*" line) != null;

  # ── bareCommandsFromText :: string -> [ string ] ──────────────────────
  bareCommandsFromText = rawText:
    let
      # Strip full-line comments + blanks first (see isCommentOrBlank).
      text = lib.concatStringsSep "\n"
        (builtins.filter (l: !(isCommentOrBlank l)) (lib.splitString "\n" rawText));
      # Replace every command-context boundary with a newline (multi-char
      # tokens first so `&&`/`||` don't get shredded by the single-char
      # pass), then tabs → spaces. Grouping braces become newlines too (a
      # `{`-group's first element is a command).
      normalized = builtins.replaceStrings
        [ "&&" "||" "|" ";;" ";" "&" "`" "$(" ")" "(" "{" "}" "\t" ]
        [ "\n" "\n" "\n" "\n" "\n" "\n" "\n" "\n" "\n" "\n" "\n" "\n" " " ]
        text;
      segments = lib.splitString "\n" normalized;
      wordsOf = seg: builtins.filter (w: w != "") (lib.splitString " " seg);
      cmds = builtins.filter (c: c != null)
        (map (seg: firstCommandInWords (wordsOf seg)) segments);
    in
    lib.naturalSort (lib.unique cmds);

  # ── bareCommands :: (path | derivation | string) -> [ string ] ────────
  # A path/derivation is read via builtins.readFile (a writeShellScript
  # output coerces to its outPath); a literal inline string is analyzed
  # directly (detected by NOT starting with `/`).
  bareCommands = src:
    let
      text =
        if builtins.isPath src then builtins.readFile src
        else if lib.isDerivation src then builtins.readFile src
        else if lib.isString src && lib.hasPrefix "/" src then builtins.readFile src
        else src; # literal inline script text
    in
    bareCommandsFromText text;

  # ── The command→bundle map (single source of the mapping knowledge) ───
  # Values are catalog bundle NAMES (see ./distroless-toolset.nix). `sh`/
  # `bash`/`dash` map to "shell" — which usually means the `shell = true`
  # FLAG rather than the bundle (see suggestBundles' note).
  defaultCommandMap = {
    # coreutils
    mkdir = "coreutils"; cat = "coreutils"; ln = "coreutils";
    chmod = "coreutils"; chown = "coreutils"; cp = "coreutils";
    mv = "coreutils"; rm = "coreutils"; ls = "coreutils";
    mktemp = "coreutils"; id = "coreutils"; head = "coreutils";
    tail = "coreutils"; touch = "coreutils"; readlink = "coreutils";
    dirname = "coreutils"; basename = "coreutils"; env = "coreutils";
    date = "coreutils"; sleep = "coreutils"; tr = "coreutils";
    wc = "coreutils"; sort = "coreutils"; cut = "coreutils";
    tee = "coreutils"; stat = "coreutils"; seq = "coreutils";
    nproc = "coreutils"; sync = "coreutils"; sha256sum = "coreutils";
    base64 = "coreutils"; expr = "coreutils"; whoami = "coreutils";
    uname = "coreutils"; realpath = "coreutils"; install = "coreutils";
    # textproc
    sed = "textproc"; grep = "textproc"; egrep = "textproc";
    fgrep = "textproc"; awk = "textproc"; gawk = "textproc";
    # process
    ps = "process"; free = "process"; top = "process"; pgrep = "process";
    pkill = "process"; pidof = "process"; sysctl = "process";
    pmap = "process"; vmstat = "process";
    # net
    hostname = "net"; ip = "net"; ping = "net"; ifconfig = "net";
    netstat = "net"; route = "net"; ss = "net"; arp = "net";
    # archive
    tar = "archive"; gzip = "archive"; gunzip = "archive";
    zcat = "archive"; xz = "archive"; unxz = "archive"; bzip2 = "archive";
    # findutils
    find = "findutils"; xargs = "findutils";
    # which
    which = "which";
    # shell (usually the shell = true flag)
    sh = "shell"; bash = "shell"; dash = "shell";
  };

  # ── suggestBundles :: [ string ] -> { bundles; shell; unmapped } ──────
  # Turn a command list into the catalog selection. `shell` is surfaced
  # SEPARATELY as a bool (map it to the `shell = true` flag, which installs
  # the /bin/sh symlink a shebang execs — the bundle alone doesn't); every
  # other mapped command yields a bundle name; anything unmapped is an
  # image-specific tool to pass as a RAW package (barman-cloud, a vendor
  # CLI) after you confirm which nixpkgs attr provides it.
  suggestBundles = cmds:
    let
      lookups = map (c: { cmd = c; bundle = defaultCommandMap.${c} or null; }) cmds;
      nonShell = builtins.filter (m: m.bundle != null && m.bundle != "shell") lookups;
      wantsShell = lib.any (m: m.bundle == "shell") lookups;
      unmapped = map (m: m.cmd) (builtins.filter (m: m.bundle == null) lookups);
    in {
      bundles = lib.naturalSort (lib.unique (map (m: m.bundle) nonShell));
      shell = wantsShell;
      inherit unmapped;
    };

in {
  inherit bareCommands bareCommandsFromText suggestBundles defaultCommandMap;
}
