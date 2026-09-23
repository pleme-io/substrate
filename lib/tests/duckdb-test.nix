# Pure eval tests for lib/duckdb.nix.
#
# The load-bearing ones are the refusals: a typo'd setting name, a percentage
# memory limit (DuckDB rejects '%' — measured on 1.4.3) and an unknown profile
# must fail at EVAL, because the alternative is a wrapped duckdb that prints an
# error on every start, on the machine, later. And the render must be
# byte-stable, since the rendered text is a store path.
#
# Usage: nix eval -f lib/tests/duckdb-test.nix --arg lib '(import <nixpkgs> {}).lib' summary
# Wired as a derivation via `asCheck pkgs` in substrate's flake checks.
{ lib }:

let
  testHelpers = import ../test-helpers.nix { inherit lib; };
  duckdb = import ../duckdb.nix { inherit lib; };

  workstation = { memoryGiB = 48; performanceCores = 10; efficiencyCores = 4; scratchGiB = 8; };
  shell = duckdb.settingsFor { profile = "interactive"; hardware = workstation; };
  build = duckdb.settingsFor { profile = "build"; hardware = workstation; };

  throws = expr: !(builtins.tryEval (builtins.deepSeq expr expr)).success;
  has = infix: text: lib.hasInfix infix text;

  tests = [
    # ── Refusals at eval time ─────────────────────────────────────────
    (testHelpers.mkTest "unknown-setting-throws"
      (throws (duckdb.render { threds = 4; }))
      "a misspelt setting must not evaluate — DuckDB would reject it only at load time")

    (testHelpers.mkTest "percentage-memory-throws"
      (throws (duckdb.render { memory_limit = { size = "50%"; }; }))
      "DuckDB takes no percentage memory limit; the surface must refuse it, not render it")

    (testHelpers.mkTest "wrong-kind-throws"
      (throws (duckdb.render { threads = "four"; }))
      "threads takes an int or an expression, never a string")

    (testHelpers.mkTest "unknown-profile-throws"
      (throws (duckdb.settingsFor { profile = "turbo"; hardware = workstation; }))
      "a profile outside the closed set must not evaluate")

    (testHelpers.mkTest "missing-hardware-throws"
      (throws (duckdb.settingsFor { profile = "interactive"; hardware = { }; }))
      "hardware facts are declared, so an empty declaration is an error, not a default")

    # ── What the profiles render (the measured defects they fix) ──────
    (testHelpers.mkTest "spills-go-to-tmpdir-not-cwd"
      (has "getenv('TMPDIR')" (duckdb.render shell) && has "getenv('TMPDIR')" (duckdb.render build))
      "DuckDB's default temp_directory is '.tmp' in the CWD — a spill dirties the repo you ran it from")

    (testHelpers.mkTest "spills-are-capped"
      (has "SET max_temp_directory_size = '8GiB';" (duckdb.render shell))
      "the default cap is 90% of free disk; on a near-full disk that is the nix store's last room")

    (testHelpers.mkTest "interactive-takes-half-the-ram"
      (has "SET memory_limit = '24GiB';" (duckdb.render shell))
      "48 GiB declared → 24 GiB interactive, leaving the rest to builds, the browser, the VM")

    (testHelpers.mkTest "build-defers-to-nix-cores"
      (has "getenv('NIX_BUILD_CORES')" (duckdb.render build))
      "a build uses nix's own core allotment instead of every build claiming every core")

    (testHelpers.mkTest "build-memory-is-a-per-job-share"
      (has "SET memory_limit = '2106MiB';" (duckdb.render build))
      "60% of 48 GiB over 14 jobs = 2106 MiB, so 14 concurrent builds cannot overcommit")

    (testHelpers.mkTest "storage-format-left-at-default"
      (!(has "storage_compatibility_version" (duckdb.render shell)) && !(has "storage_compatibility_version" (duckdb.render build)))
      "'latest' measured 7% LARGER than the default on 1.4.3 — not rendered without a receipt")

    (testHelpers.mkTest "overrides-win"
      (has "SET threads = 3;" (duckdb.render (duckdb.settingsFor { profile = "interactive"; hardware = workstation; overrides = { threads = 3; }; })))
      "a consumer's override replaces the profile's value")

    # ── Rendering is stable ───────────────────────────────────────────
    (testHelpers.mkTest "render-is-sorted-and-stable"
      (duckdb.render { threads = 2; enable_progress_bar = true; }
        == "SET enable_progress_bar = true;\nSET threads = 2;\n")
      "one SET per line, sorted by name — the same settings are the same bytes")

    (testHelpers.mkTest "sizes-render-as-duckdb-parses-them"
      (duckdb.render { memory_limit = { size = "24GiB"; }; } == "SET memory_limit = '24GiB';\n"
        && !(has "." (duckdb.render shell)))
      "no float formatting leaks into a size — nix prints 8.0 as \"8.000000\"")

    (testHelpers.mkTest "strings-are-quoted-safely"
      (duckdb.render { temp_directory = "it's"; } == "SET temp_directory = 'it''s';\n")
      "a quote inside a string value is doubled, never left to end the literal")
  ];

  result = testHelpers.runTests tests;
in
{
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  asCheck = pkgs:
    if result.allPassed
    then pkgs.runCommand "duckdb-test" { } ''
      echo "duckdb: ${result.summary}" > $out
    ''
    else throw ''
      duckdb tests FAILED (${result.summary}):
        - ${builtins.concatStringsSep "\n  - " result.failures}'';
}
