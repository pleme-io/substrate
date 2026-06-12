# Tests — iroha.catalog (CATALOG REFLECTION invariants).
#
# The bijection test: every letter file on disk has a catalog entry, every
# catalog entry points at a file that exists. Adding a letter without its
# catalog entry — or deleting a letter while its entry lingers — fails here.
{ lib, iroha }:
let
  catalog = iroha.catalog;

  # Letter files on disk = every *.nix in the iroha dir except default.nix
  # (the aggregator) and the tests/ directory.
  dir = builtins.readDir ../.;
  letterFiles = builtins.filter (
    n: lib.hasSuffix ".nix" n && n != "default.nix" && (dir.${n} == "regular")
  ) (builtins.attrNames dir);

  catalogFiles = map (e: e.file) (builtins.attrValues catalog);

  tiers = [
    "kernel"
    "standard"
    "extended"
  ];
in
{
  every-letter-file-has-a-catalog-entry = {
    expr = builtins.sort builtins.lessThan letterFiles;
    expected = builtins.sort builtins.lessThan catalogFiles;
  };
  every-entry-file-exists = {
    expr = builtins.all (f: builtins.pathExists (../. + "/${f}")) catalogFiles;
    expected = true;
  };
  every-entry-is-fully-described = {
    expr = builtins.all (
      e:
      e ? file
      && e ? tier
      && e ? maturity
      && e ? since
      && e ? description
      && e ? subsumes
      && e ? dependsOn
      && e ? exports
    ) (builtins.attrValues catalog);
    expected = true;
  };
  every-tier-is-valid = {
    expr = builtins.all (e: builtins.elem e.tier tiers) (builtins.attrValues catalog);
    expected = true;
  };
  every-maturity-is-valid-and-histogram-partitions = {
    # CATALOG REFLECTION: maturity gates use the canonical vocabulary and
    # the histogram sums to the catalog size (partition complete).
    expr =
      let
        maturities = [
          "Working"
          "M2Typed"
          "M3Typed"
          "M4Typed"
          "Informational"
        ];
        entries = builtins.attrValues catalog;
        histogram = map (m: builtins.length (builtins.filter (e: e.maturity == m) entries)) maturities;
      in
      {
        allValid = builtins.all (e: builtins.elem e.maturity maturities) entries;
        partitions = builtins.foldl' builtins.add 0 histogram == builtins.length entries;
      };
    expected = {
      allValid = true;
      partitions = true;
    };
  };
  depends-on-edges-point-at-letters = {
    expr = builtins.all (e: builtins.all (d: catalog ? ${d}) e.dependsOn) (
      builtins.attrValues catalog
    );
    expected = true;
  };
  depends-on-graph-is-acyclic = {
    # Topological-order solvability: repeatedly strip nodes whose deps are
    # all already stripped; a fixpoint short of the full set is a cycle.
    expr =
      let
        names = builtins.attrNames catalog;
        step =
          done:
          done
          ++ builtins.filter (
            n: !(builtins.elem n done) && builtins.all (d: builtins.elem d done) catalog.${n}.dependsOn
          ) names;
        go =
          done:
          let
            next = step done;
          in
          if builtins.length next == builtins.length done then done else go next;
      in
      builtins.length (go [ ]) == builtins.length names;
    expected = true;
  };
  every-declared-export-exists = {
    expr = builtins.all (
      name:
      let
        e = catalog.${name};
      in
      builtins.all (x: name == "catalog" || iroha ? ${x}) e.exports
    ) (builtins.attrNames catalog);
    expected = true;
  };
  no-export-collisions = {
    # Every exported name belongs to exactly one letter.
    expr =
      let
        allExports = lib.concatMap (e: e.exports) (builtins.attrValues catalog);
      in
      builtins.length allExports == builtins.length (lib.unique allExports);
    expected = true;
  };
}
