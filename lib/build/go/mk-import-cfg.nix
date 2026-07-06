# mk-import-cfg.nix (Go) — synthesize a package node's `importcfg` lines.
#
# The core per-node wiring job of the gen-gomod M1 incremental interpreter
# (theory/GEN-TYPED-SPEC-CONTRACT.md; grounded in the M1 build plan §5b).
#
# `go build -x` reveals that, for every package, the toolchain writes an
# `importcfg` file mapping each imported path → the on-disk `.a` archive, then
# invokes `go tool compile -importcfg <that file>`. This primitive synthesizes
# those lines PURELY (no store realize) from the node's RESOLVED import edges —
# each edge already carrying the store path of its dependency node's compiled
# archive (produced by the `lib.fix` graph in package-graph.nix).
#
# Two line kinds are emitted here (the NODE-SPECIFIC half):
#   * `importmap <src>=<actual>`  — vendor/`replace` rewrite (go list ImportMap).
#   * `packagefile <ip>=<archive>` — one per direct NON-STD import edge.
#
# Std packagefile lines are intentionally NOT emitted here: the shared std tree
# (std-tree.nix) ships a complete `importcfg.base` carrying EVERY std package's
# archive, which the interpreter appends at BUILD time (a file reference, never
# an eval-time `readFile` → no IFD). Re-emitting std lines would duplicate the
# base and `go tool compile` rejects duplicate `packagefile` entries.
#
# ── Go-I1 (interpreter-side defense) ─────────────────────────────────────────
# Every edge MUST carry a non-null `archive`. The graph resolves `archive` from
# `self.<dep>` and throws (naming the node) when an edge points at no node; this
# guard is the belt-and-suspenders re-check so a hand-shaped edge list can never
# silently compile against a missing archive. This mirrors the rust interpreter
# refusing a dep edge that resolves to no crate.
{ lib }:
let
  inherit (builtins) concatStringsSep filter;
in
{
  # Build the NODE-SPECIFIC importcfg text (importmap + non-std packagefile
  # lines). `importPath` names the node (used in the Go-I1 throw + a header
  # comment). `edges` is the list of resolved direct imports:
  #   { key; importPath; archive; isStd; }
  mkImportCfgText =
    { importPath
    , importMap ? { }
    , edges
    }:
    let
      # Go-I1: no edge may resolve to a null archive.
      badEdge = lib.findFirst (e: (e.archive or null) == null) null edges;
      _guard =
        if badEdge != null
        then throw ''
          mk-import-cfg(go): node '${importPath}' has an unresolved import edge
          '${badEdge.key or "<unknown>"}' — no compiled archive for it. The build
          graph is missing a node for this import (Go-I1). The encoder must emit
          every direct import as a node key in `packages`.
        ''
        else null;

      importmapLines =
        lib.mapAttrsToList (from: to: "importmap ${from}=${to}") importMap;

      # One packagefile per NON-std direct edge. Std edges are covered by the
      # std tree's importcfg.base (appended by the interpreter at build time).
      packagefileLines =
        map (e: "packagefile ${e.importPath}=${toString e.archive}")
          (filter (e: !(e.isStd or false)) edges);
    in
    builtins.seq _guard (
      concatStringsSep "\n" (
        [ "# importcfg for ${importPath}" ]
        ++ importmapLines
        ++ packagefileLines
      ) + "\n"
    );
}
