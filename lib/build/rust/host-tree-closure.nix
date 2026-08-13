# host-tree-closure.nix — the I2 corollary, as a named function.
#
# lockfile-builder.nix compiles a crate graph as TWO trees (invariant I2):
# `built` on the workload's target arch, and `builtBuild` on the build/host
# arch. Every `tree == "host"` runtime edge and EVERY build_dependency of the
# target tree resolves in the host tree.
#
# The consequence is easy to miss and was missed: the set of crates the host
# tree must be able to answer for is a property of the TARGET triple's
# resolve, not of the host's. A multi-target spec stores one resolve section
# per triple, so filtering the host tree by the host triple's section alone
# silently omits any proc-macro or build-dep that is reachable on the target
# and not on the host. It then fails as a bare
#
#   error: attribute '"openssl-macros-0.1.1"' missing
#
# out of `builtBuild.${d.package_key}` — a message that names neither the
# tree split nor the triple pair, on an output (`<tool>-<target>`) most
# consumers only evaluate under `nix flake check`.
#
# `mergeHostSection` is what lockfile-builder actually uses. `unresolved` is
# the predicate that says whether the result is CLOSED — it is the thing
# worth asserting, and it is what the test drives, so a future edit that
# widens the key set without widening the edge source is caught rather than
# rediscovered by a consumer.
{ lib }:
let
  # Which tree a runtime edge resolves in. Mirrors lockfile-builder's
  # `built.depFor` exactly: schema >= 4 carries the typed `tree` field;
  # older specs fall back to the crate's `proc_macro` flag.
  treeOf = universe: d:
    let legacy = universe.${d.package_key}.proc_macro or false;
    in d.tree or (if legacy then "host" else "target");
in
rec {
  # The host tree's resolve section: the host triple's section, filled in
  # with the target triple's entries for keys the host triple does not
  # resolve at all.
  #
  # HOST WINS on collision, deliberately. A crate present on both triples
  # keeps the host triple's edges and features — that is the resolution the
  # host tree is compiling. Only target-only keys come from the target
  # section, which for them is the only resolution that exists.
  #
  # Merging the SECTION rather than just the key set is load-bearing: a key
  # present with no edges falls through to the per-crate universe edges,
  # which reintroduces the same missing attribute one level down.
  mergeHostSection = { hostSection, targetSection }:
    if hostSection == null then null
    else if targetSection == null then hostSection
    else { crates = targetSection.crates // hostSection.crates; };

  # Every key the TARGET tree routes into the host tree: host-tree runtime
  # edges plus all build dependencies, across the whole target section.
  hostRoutedKeys = { targetSection, universe ? { } }:
    if targetSection == null then [ ]
    else
      lib.unique (lib.concatLists (lib.mapAttrsToList
        (_: edges:
          (map (d: d.package_key)
            (lib.filter (d: treeOf universe d == "host")
              (edges.runtime_dependencies or [ ])))
          ++ (map (d: d.package_key) (edges.build_dependencies or [ ])))
        targetSection.crates));

  # The keys a host tree built from `section` would be asked for and could
  # not answer — transitively, since a host-routed crate's own edges are
  # resolved in the host tree too. EMPTY is the invariant; a non-empty
  # result is exactly the `attribute '<key>' missing` this file exists to
  # prevent, named before it is thrown.
  unresolved = { section, targetSection, universe ? { } }:
    let
      answers = if section == null then { } else section.crates;
      step = seen: key:
        if seen ? ${key} then seen
        else
          let
            edges = answers.${key} or null;
            next = seen // { ${key} = edges == null; };
          in
            if edges == null then next
            else lib.foldl' step next
              (map (d: d.package_key)
                ((edges.runtime_dependencies or [ ])
                  ++ (edges.build_dependencies or [ ])));
      visited = lib.foldl' step { } (hostRoutedKeys { inherit targetSection universe; });
    in
      lib.sort (a: b: a < b) (lib.attrNames (lib.filterAttrs (_: missing: missing) visited));
}
