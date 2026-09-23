# DuckDB, tuned to the machine and to the job — one settings surface, rendered
# into a wrapped `duckdb` that carries it everywhere.
#
# ── Why a wrapper, not ~/.duckdbrc ──────────────────────────────────────────
#
# Measured on DuckDB 1.4.3 (2026-09-23): the CLI reads ~/.duckdbrc ONLY in an
# interactive terminal. `duckdb -c`, `duckdb -f`, and SQL piped on stdin all
# ignore it — which is every path an agent, a script, a blue bidama (bunseki)
# or a nix derivation takes. An rc file tunes the one caller that needs it
# least. `-init FILE` is honoured in every mode and prints nothing, so the
# wrapper adds `-init <rendered settings>` and the settings travel with the
# binary.
#
# ── Why these settings (defaults measured on a 14-core M4 Pro, 48 GiB) ──
#
#   temp_directory           default '.tmp' — relative to the CWD, so a query
#                            that spills writes into whatever repo you ran it
#                            from (a dirty tree) or, in a derivation that cd's
#                            into the store, fails. Rendered: $TMPDIR/duckdb,
#                            resolved at run time.
#   max_temp_directory_size  default "90% of available disk" — on a disk that
#                            is 94% full that lets one query take the last 27
#                            GB the nix store needs. Rendered: a declared cap.
#   memory_limit             default 80% of RAM, per process. Fourteen nix
#                            builds at once each get 80%. Rendered: a share of
#                            declared RAM per profile.
#   threads                  default = every core. In a build, nix already
#                            allots cores (NIX_BUILD_CORES); DuckDB defers to
#                            it instead of each build claiming all 14.
#   storage_compatibility_version
#                            default v0.10.2 — new databases are written in a
#                            two-year-old format, forgoing newer compression.
#                            Rendered: 'latest', safe because the same pinned
#                            duckdb reads what it writes (the consumer's job:
#                            ship ONE duckdb to both the builds and the shell).
#
# Values that must be read at run time ($TMPDIR, NIX_BUILD_CORES) are rendered
# as DuckDB expressions over getenv(), which `SET` evaluates when the file is
# loaded — so one store path serves every build directory and every user.
#
# ── Usage ────────────────────────────────────────────────────────────────────
#
#   duckdbLib = import "${substrate}/lib/duckdb.nix" { inherit lib; };
#   hardware  = { memoryGiB = 48; performanceCores = 10; efficiencyCores = 4; scratchGiB = 8; };
#   shell     = duckdbLib.wrap { inherit pkgs; settings = duckdbLib.settingsFor { profile = "interactive"; inherit hardware; }; };
#   builder   = duckdbLib.wrap { inherit pkgs; settings = duckdbLib.settingsFor { profile = "build";       inherit hardware; }; };
#
# An unknown setting name, or a value of the wrong kind, is an EVAL error —
# DuckDB would only reject it when the file is loaded, on the machine, later.
{ lib }:

let
  # The closed set of settings this surface renders, each with its kind.
  # Adding a setting is one row here; a name not in this table does not
  # evaluate. Kinds: int, bool, size (a DuckDB size string such as "8GiB"),
  # string, and sql (an expression DuckDB evaluates at load time).
  known = {
    threads = [ "int" "sql" ];
    memory_limit = [ "size" ];
    max_temp_directory_size = [ "size" ];
    temp_directory = [ "string" "sql" ];
    storage_compatibility_version = [ "string" ];
    preserve_insertion_order = [ "bool" ];
    enable_progress_bar = [ "bool" ];
    allocator_background_threads = [ "bool" ];
  };

  # A value is a plain int/bool/string, `{ size = "8GiB"; }`, or `{ sql = "…"; }`.
  kindOf = v:
    if builtins.isInt v then "int"
    else if builtins.isBool v then "bool"
    else if builtins.isString v then "string"
    else if builtins.isAttrs v && v ? size then "size"
    else if builtins.isAttrs v && v ? sql then "sql"
    else throw "duckdb: a setting value must be an int, bool, string, { size = …; } or { sql = …; }";

  validSize = s: builtins.match "[0-9]+(\\.[0-9]+)?(KB|MB|GB|TB|KiB|MiB|GiB|TiB)" s != null;

  quote = s: "'" + builtins.replaceStrings [ "'" ] [ "''" ] s + "'";

  renderValue = name: v:
    let k = kindOf v; in
    if !(builtins.elem k known.${name}) then
      throw "duckdb: setting ${name} takes ${lib.concatStringsSep " or " known.${name}}, got ${k}"
    else if k == "int" then toString v
    else if k == "bool" then lib.boolToString v
    else if k == "string" then quote v
    else if k == "size" then
      (if validSize v.size then quote v.size
       else throw "duckdb: ${name} = \"${v.size}\" is not a DuckDB size (a number then KB/MB/GB/TB or KiB/MiB/GiB/TiB — DuckDB takes no percentages)")
    else v.sql;

  checkName = name:
    if known ? ${name} then name
    else throw "duckdb: unknown setting '${name}' (known: ${lib.concatStringsSep ", " (builtins.attrNames known)})";

  # A size DuckDB parses, from a (possibly fractional) GiB count: whole GiB
  # when it is one, else whole MiB. Nix renders floats as "8.000000".
  gib = x:
    let mib = builtins.floor (x * 1024); in
    { size = if lib.mod mib 1024 == 0 then "${toString (mib / 1024)}GiB" else "${toString mib}MiB"; };

  # $TMPDIR/duckdb, whatever TMPDIR is when the file loads (a build's own temp
  # dir under nix, the per-user /var/folders/…/T on macOS, /tmp when unset).
  scratchDir = { sql = "rtrim(coalesce(nullif(getenv('TMPDIR'), ''), '/tmp'), '/') || '/duckdb'"; };

  # Declared, because evaluation cannot read the machine. `nix run` the
  # consumer's tuning tool to measure; a declared fact is checked by use.
  checkHardware = h:
    assert lib.assertMsg (h ? memoryGiB && h.memoryGiB > 0) "duckdb: hardware.memoryGiB is required";
    assert lib.assertMsg (h ? performanceCores && h.performanceCores > 0) "duckdb: hardware.performanceCores is required";
    h // {
      efficiencyCores = h.efficiencyCores or 0;
      scratchGiB = h.scratchGiB or 8;
      maxJobs = h.maxJobs or (h.performanceCores + (h.efficiencyCores or 0));
    };

  # The profiles — what the process is doing, not what machine it is on.
  profiles = {
    # A person or an agent exploring on a workstation it shares with builds,
    # a browser and a VM: half the RAM, every core, spills capped.
    interactive = h: {
      threads = h.performanceCores + h.efficiencyCores;
      memory_limit = gib (h.memoryGiB * 0.5);
      max_temp_directory_size = gib h.scratchGiB;
      temp_directory = scratchDir;
      storage_compatibility_version = "latest";
    };

    # One nix derivation among up to maxJobs at once: nix's own core allotment,
    # a per-job share of 60% of RAM, the build's own temp dir.
    build = h: {
      threads = { sql = "coalesce(try_cast(nullif(getenv('NIX_BUILD_CORES'), '0') as integer), ${toString h.performanceCores})"; };
      memory_limit = gib (lib.max 1 (h.memoryGiB * 0.6 / h.maxJobs));
      max_temp_directory_size = gib h.scratchGiB;
      temp_directory = scratchDir;
      storage_compatibility_version = "latest";
    };
  };
in
rec {
  inherit known profiles;

  # settingsFor { profile = "interactive" | "build"; hardware; overrides ? {} }
  settingsFor = { profile, hardware, overrides ? { } }:
    if !(profiles ? ${profile})
    then throw "duckdb: unknown profile '${profile}' (known: ${lib.concatStringsSep ", " (builtins.attrNames profiles)})"
    else profiles.${profile} (checkHardware hardware) // overrides;

  # SQL text: one SET per setting, sorted by name, so the same settings always
  # render the same bytes (and the same store path).
  render = settings:
    lib.concatStrings (map (name: "SET ${checkName name} = ${renderValue name settings.${name}};\n")
      (builtins.sort builtins.lessThan (builtins.attrNames settings)));

  initFile = { pkgs, settings, name ? "duckdb-settings" }:
    pkgs.writeText "${name}.sql" (render settings);

  # A `duckdb` that loads the settings in every mode (-c, -f, stdin, a
  # terminal). passthru.settings/.init let a consumer show or test them.
  wrap = { pkgs, settings, duckdb ? pkgs.duckdb, name ? "duckdb" }:
    let init = initFile { inherit pkgs settings; name = "${name}-settings"; }; in
    pkgs.runCommand name
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        meta.mainProgram = "duckdb";
        passthru = { inherit settings init duckdb; };
      } ''
      mkdir -p $out/bin
      makeWrapper ${duckdb}/bin/duckdb $out/bin/duckdb --add-flags "-init ${init}"
    '';
}
