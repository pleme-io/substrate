# mk-embed-cfg.nix (Go) — synthesize a package node's `-embedcfg` JSON (Go-I9).
#
# A package with `//go:embed` directives must be compiled with
# `go tool compile -embedcfg <file>`, where the file is JSON of the shape:
#
#   { "Patterns": { "<pattern>": [ "<file>", ... ], ... },
#     "Files":    { "<file>": "<on-disk-path>", ... } }
#
# `go list` reports `EmbedPatterns` + `EmbedFiles` per package; the encoder
# carries them onto the node's `embed` spec. The interpreter compiles each node
# with `cd <relative_path>` (Go-I3), so every embed file's on-disk path is just
# the file entry itself (relative to the package dir) — hence `Files[f] = f`.
#
# ── Pattern→file grouping ────────────────────────────────────────────────────
# The exact per-pattern file grouping is `go list` `EmbedPatternFiles`-shaped
# data; when the encoder provides it (`embed.pattern_files`), the interpreter
# uses it verbatim (the correct, non-degraded path). When only the flat
# `patterns` + `files` lists are present, M1 falls back to mapping every pattern
# to the full file set — the go compiler treats `Patterns[p]` as the authoritative
# list, so this is exact for the single-pattern case (the common one) and a
# documented M1 over-approximation for the multi-pattern case (M-embed-exact
# lifts this to the encoder-provided grouping). All 8 akeyless embed packages
# are expected to ship `pattern_files` from the encoder.
{ lib }:
{
  # A node's embed spec is empty when it has no resolved embed files.
  isEmpty = embed:
    ((embed.files or [ ]) == [ ]) && ((embed.patterns or [ ]) == [ ]);

  # Build the -embedcfg JSON text.
  #   patterns     : list of //go:embed patterns (provenance / fallback grouping)
  #   files        : list of resolved embed files (relative to the package dir)
  #   patternFiles : optional { "<pattern>" = [ "<file>" ... ]; } exact grouping.
  mkEmbedCfgText =
    { patterns ? [ ]
    , files ? [ ]
    , patternFiles ? null
    }:
    let
      # Files: logical embed path → on-disk path (== the path itself, because
      # the compile runs from the package dir).
      filesMap =
        builtins.listToAttrs (map (f: { name = f; value = f; }) files);

      # Patterns: encoder-provided exact grouping when present; else the M1
      # full-set fallback (exact for one pattern, over-approx for many).
      patternsMap =
        if patternFiles != null
        then patternFiles
        else builtins.listToAttrs (map (p: { name = p; value = files; }) patterns);
    in
    builtins.toJSON { Patterns = patternsMap; Files = filesMap; };
}
