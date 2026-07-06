# package-graph.nix (Go) — the PURE per-package build-graph algorithm.
#
# The heart of the gen-gomod M1 incremental interpreter. This is the Go analogue
# of the `lib.fix (self: mapAttrs …)` crate graph in
# substrate/lib/build/rust/lockfile-builder.nix (~L800): each spec node becomes
# one lazily-built value, wired to its dependency nodes through `self`, so a node
# is computed ONCE and reused by every dependent (the "shared internal package
# compiled once, linked into every binary" win).
#
# ── The mockable Environment seam (TESTING-SUBSTRATE §IX) ────────────────────
# This module owns ONLY the graph logic + the interpreter-side defensive
# invariants (Go-I1/I3/I10/I11/I12). Everything with a side effect — realizing a
# derivation, writing an importcfg/embedcfg file, building the std tree — is
# abstracted behind an injected `backend` ("Environment trait"). The production
# backend (package-builder.nix::realBackend) wires `pkgs.stdenv.mkDerivation` +
# `pkgs.go`; the test backend (tests/package-graph-test.nix::mockBackend) records
# the compile plan as pure data. The whole graph — dedup, importcfg wiring,
# link-vs-compile dispatch, std routing, every defensive throw — is therefore
# proven at eval time with `nix-instantiate --eval --strict`, no `nix build`.
#
# ── Backend contract ("Environment trait") ───────────────────────────────────
#   sanitize       : nodeKey -> derivation-name-safe string
#   mkStdTree      : { goVersion; goos; goarch; tags; }
#                      -> { drv; package :: importPath -> archivePath;
#                           importcfgBaseRef; }   -- built ONCE per tuple (§5a)
#   writeImportCfg : { name; nodeLines; stdTree; } -> importcfg
#   writeEmbedCfg  : { name; text; } -> embedcfg
#   mkNode         : { key; pkg; importPath; kind; isMain; binName; relativePath;
#                      goFiles; buildTags; embed; importcfg; embedcfg; edges;
#                      gcflags; ldflags; env; quirks; goVersion; stdTree; }
#                      -> a node record { key; importPath; kind; isStd=false;
#                                         isMain; archive; drv; plan; }
#   mkFerriteNode  : { key; importPath; kind; relativePath; goFiles; sourceHash;
#                      edges; goVersion; }
#                      -> a ferrite-node record { key; importPath; kind;
#                                                 sourceHash; drv; poms; plan; }
#
# A produced node record MUST carry `archive` (the compiled `.a` path) and
# `isStd` so dependents can wire it into their importcfg (see resolveEdge).
#
# ── The parallel ferrite proof tree (M-ferrite) ───────────────────────────────
# Alongside `nodes` (the compile tree), mkGraph returns `ferriteNodes` — a SECOND
# node tree over the SAME packages. Each buildable (module|main) package gets one
# ferrite node that runs `ferrite-check -ferrite.poms-dir` over that package's
# sources and emits a per-package PoMS JSON. Its store address is a pure function
# of the SAME `pkg.source_hash` the compile node uses (Go-I8) + its import edges,
# so editing one package's go_files re-proves ONLY its ferrite node (and its
# compile node); every other ferrite node is a store/cache hit — the exact
# analogue of gen-cargo I2's `builtBuild` parallel tree. std packages are proven
# inside the shared std tree by the real toolchain (Go-I10) and carry no
# per-package source, so they get NO ferrite node (ferrite proves your code, not
# std). The PoMS files content-address into the sui store identically to the
# compile `.a` archives, and feed the tameshi/cartorio attest leg (surface c).
{ lib }:
let
  mkImportCfg = import ./mk-import-cfg.nix { inherit lib; };
  mkEmbedCfg = import ./mk-embed-cfg.nix { inherit lib; };

  # Kinds the M1 incremental interpreter can build. Anything else — `cgo`,
  # `tool`, an asm-bearing package — is UNREPRESENTABLE in the M1 graph:
  # dispatch throws (Go-I12). The encoder rejects cgo/asm upstream; this is the
  # interpreter-side defense so a hand-edited spec can never silently mis-build.
  m1Kinds = [ "std" "module" "main" ];
in
{
  inherit m1Kinds;

  # Build the lazy per-package derivation/plan graph.
  #
  # spec    : the loaded Go BuildSpec (§3). `spec.packages` is keyed by node key
  #           ("<import-path>#<goos>-<goarch>[+tags]" / "std/<path>#…").
  # tuple   : { goVersion; goos; goarch; tags; } — the single M1 target tuple.
  # backend : the injected Environment (see contract above).
  #
  # Returns { nodes; ferriteNodes; root; members; stdTree; }.
  #   nodes        : the compile tree (one node per package).
  #   ferriteNodes : the parallel PoMS proof tree (one node per module|main
  #                  package; std packages excluded — proven in the std tree).
  mkGraph =
    { spec
    , tuple
    , backend
    }:
    let
      packages = spec.packages or { };
      keys = builtins.attrNames packages;

      # The shared std tree for this tuple — built ONCE, imported by every
      # workload node (Go-I10 / §5a).
      stdTree = backend.mkStdTree {
        inherit (tuple) goVersion goos goarch tags;
      };

      # ── Go-I3: relative_path sanity for in-tree (vendored) nodes ──────────
      # A vendored node's source is a subdir of the ONE workspace src; the
      # prefix must be a real, non-escaping relative path (handles GOPATH
      # `go/src/…`, `vendor/…`, and in-tree `replace` targets uniformly).
      checkRelPath = key: pkg:
        let
          src = pkg.source or { };
          kind = src.kind or null;
          rel = src.relative_path or null;
        in
        if kind == "vendored" then
          (if rel == null then
            throw "package-graph(go): node '${key}' is vendored but carries no relative_path (Go-I3)."
          else if lib.hasInfix ".." rel then
            throw "package-graph(go): node '${key}' relative_path '${rel}' escapes the workspace src via '..' (Go-I3)."
          else if lib.hasPrefix "/" rel then
            throw "package-graph(go): node '${key}' relative_path '${rel}' is absolute; it must be a subdir of the workspace src (Go-I3)."
          else true)
        else true;

      # ── Go-I12: kind dispatch guard ───────────────────────────────────────
      checkKind = key: pkg:
        let k = pkg.kind or "<missing>"; in
        if builtins.elem k m1Kinds then true
        else throw ''
          package-graph(go): node '${key}' has kind '${k}', which the M1
          incremental interpreter cannot build (only ${builtins.concatStringsSep " / " m1Kinds}).
          cgo/asm/tool nodes are deferred to M-cgo; a spec carrying one is
          rejected here so it can never silently mis-build (Go-I12).
        '';

      # ── the lazy fixpoint: each node computed once, referenced by many ─────
      nodes = lib.fix (self:
        lib.mapAttrs (key: pkg:
          let
            _rel = checkRelPath key pkg;
            _kind = checkKind key pkg;
            kind = pkg.kind;
            importPath = pkg.import_path;
          in
          builtins.seq _rel (builtins.seq _kind (
            if kind == "std" then
              # Go-I10: std nodes NEVER carry per-node source; they resolve to
              # the shared std tree's archive. Defensive: reject a std node whose
              # source isn't `std` (encoder marks Standard pkgs Std/Std source).
              let
                _std =
                  if (pkg.source.kind or "std") != "std"
                  then throw "package-graph(go): std node '${key}' must have source kind 'std', not '${pkg.source.kind or "<?>"}' (Go-I10)."
                  else null;
              in
              builtins.seq _std {
                inherit key importPath kind;
                isStd = true;
                isMain = false;
                archive = stdTree.package importPath;
                drv = stdTree.drv;
                # Std's own transitive closure is carried by the std tree's
                # importcfg.base, so a std node exposes an empty dep closure to
                # the graph — dependents never re-emit std packagefile lines.
                depClosure = [ ];
                plan = { std = true; inherit importPath; };
              }
            else
              # module | main → compile this package against its resolved edges.
              let
                # Go-I1: resolve each direct import edge to its node; throw
                # (naming the node) when an edge points at no node in the graph.
                resolveEdge = depKey:
                  if self ? ${depKey} then
                    let n = self.${depKey}; in
                    {
                      key = depKey;
                      inherit (n) importPath archive isStd;
                    }
                  else
                    throw ''
                      package-graph(go): node '${key}' imports '${depKey}', but no
                      such node exists in the build graph (Go-I1). The encoder must
                      emit every direct import as a node key in `packages`.
                    '';
                edges = map resolveEdge (pkg.imports or [ ]);

                # ── Transitive dep closure (for the linker) ─────────────────
                # `go tool compile` needs only DIRECT imports in its importcfg,
                # but `go tool link` needs the FULL transitive closure. Fold the
                # DAG once (memoized by lib.fix): the closure is this node's
                # direct edges ∪ every direct edge's own closure, de-duplicated
                # by node key (listToAttrs keeps the last, attrValues is
                # key-sorted → deterministic).
                depClosure =
                  let
                    flat = lib.concatMap
                      (e: [ e ] ++ (self.${e.key}.depClosure or [ ]))
                      edges;
                  in
                  builtins.attrValues
                    (builtins.listToAttrs (map (e: { name = e.key; value = e; }) flat));

                # Compile importcfg: DIRECT imports only.
                nodeLines = mkImportCfg.mkImportCfgText {
                  inherit importPath edges;
                  importMap = pkg.import_map or { };
                };
                importcfg = backend.writeImportCfg {
                  name = "importcfg-${backend.sanitize key}";
                  inherit nodeLines stdTree;
                };

                # Link importcfg (main nodes only): the FULL transitive closure.
                linkImportcfg =
                  if kind == "main" then
                    backend.writeImportCfg {
                      name = "linkcfg-${backend.sanitize key}";
                      nodeLines = mkImportCfg.mkImportCfgText {
                        inherit importPath;
                        edges = depClosure;
                        importMap = pkg.import_map or { };
                      };
                      inherit stdTree;
                    }
                  else null;

                embed = pkg.embed or { };
                hasEmbed = !(mkEmbedCfg.isEmpty embed);
                embedcfg =
                  if hasEmbed then
                    backend.writeEmbedCfg {
                      name = "embedcfg-${backend.sanitize key}";
                      text = mkEmbedCfg.mkEmbedCfgText {
                        patterns = embed.patterns or [ ];
                        files = embed.files or [ ];
                        patternFiles = embed.pattern_files or null;
                      };
                    }
                  else null;

                # Go-I11: exactly `main` nodes link; others compile -pack only.
                isMain = kind == "main";
                binName =
                  if isMain
                  then (pkg.bin_name or (baseNameOf importPath))
                  else null;

                args = pkg.args or { };
              in
              (backend.mkNode {
                inherit key pkg importPath kind isMain binName edges importcfg linkImportcfg embedcfg embed;
                relativePath = pkg.source.relative_path;
                goFiles = pkg.go_files or [ ];
                buildTags = pkg.build_tags or [ ];
                gcflags = args.gcflags or [ ];
                ldflags = args.ldflags or [ ];
                env = args.env or { };
                quirks = pkg.quirks or [ ];
                goVersion = tuple.goVersion;
                inherit stdTree depClosure;
              } // { inherit depClosure; })
          ))
        ) packages);

      # ── The parallel ferrite proof tree (M-ferrite) ──────────────────────
      # One ferrite node per BUILDABLE (module|main) package, computed over the
      # same package set as `nodes`. std packages are excluded: they carry no
      # per-package source (Go-I10) and are proven inside the shared std tree by
      # the real toolchain, so a ferrite node for std would have nothing of the
      # operator's code to prove. Each ferrite node is keyed by the SAME
      # `source_hash` as its compile node (Go-I8) so its store address aligns
      # exactly with the compile node's incremental boundary — edit one
      # package's go_files, only its compile node AND its ferrite node re-run;
      # every untouched node in BOTH trees is a store/cache hit.
      #
      # The ferrite node's edges are the package's DIRECT import edges (the same
      # `pkg.imports`): a package whose imports changed re-proves (its facts may
      # shift with a dependency's exported ownership), while an unchanged package
      # hits the store. We DO NOT re-run the compile-tree fixpoint here — the
      # ferrite fold reuses the same `pkg.imports` list, resolved lazily against
      # `self` so a dangling edge is caught here too (Go-I1), mirroring the
      # compile tree's resolveEdge (fail-closed, not silently under-proving).
      ferriteNodes = lib.fix (self:
        lib.mapAttrs (key: pkg:
          let
            _rel = checkRelPath key pkg;
            _kind = checkKind key pkg;
            kind = pkg.kind;
            importPath = pkg.import_path;
          in
          builtins.seq _rel (builtins.seq _kind (
            # Go-I8: the source_hash is the shared cache key with the compile
            # node. The encoder emits it on every buildable node; a missing
            # source_hash on a module|main node is an encoder bug — fail closed
            # so a spec can never produce an un-keyed (un-cacheable) proof node.
            let
              sourceHash =
                if pkg ? source_hash then pkg.source_hash
                else throw ''
                  package-graph(go): buildable node '${key}' carries no
                  source_hash; the ferrite proof node cannot be keyed to the
                  compile node's incremental boundary (Go-I8). The gen-gomod
                  encoder must emit source_hash on every module|main package.
                '';
              # An import edge has a buildable ferrite sibling iff the key exists
              # in the fold AND its fold value is non-null (std nodes resolve to
              # `null` — they are proven inside the shared std tree, expose no
              # ferrite node, and cannot weaken a package's own memory-safety
              # proof, so they are dropped from the proof edges).
              isBuildableSibling = dk: (self ? ${dk}) && (self.${dk} != null);
              # A dangling edge (key absent entirely) is fail-closed (Go-I1), the
              # same contract the compile tree enforces — never silently
              # under-proving against a graph with a missing node.
              resolveFerriteEdge = depKey:
                let n = self.${depKey}; in { key = depKey; inherit (n) sourceHash; };
              _danglingCheck = map
                (dk:
                  if (self ? ${dk}) then true
                  else throw ''
                    package-graph(go): ferrite node '${key}' imports '${dk}', but
                    no such node exists in the build graph (Go-I1).
                  '')
                (pkg.imports or [ ]);
              ferriteEdges =
                builtins.seq (builtins.deepSeq _danglingCheck _danglingCheck)
                  (map resolveFerriteEdge
                    (builtins.filter isBuildableSibling (pkg.imports or [ ])));
            in
            if kind == "std" then null
            else
              backend.mkFerriteNode {
                inherit key importPath kind sourceHash;
                relativePath = pkg.source.relative_path;
                goFiles = pkg.go_files or [ ];
                edges = ferriteEdges;
                goVersion = tuple.goVersion;
              }
          ))
        ) packages);

      # The buildable (non-std) ferrite proof nodes, std entries dropped.
      buildableFerriteNodes =
        lib.filterAttrs (_: n: n != null) ferriteNodes;

      # Root + members (Go-I11 buildable-node set).
      rootKey =
        if (spec.root_package or null) != null then spec.root_package
        else if keys == [ ] then throw "package-graph(go): spec has no packages."
        else lib.head keys;
      root =
        if nodes ? ${rootKey} then nodes.${rootKey}
        else throw "package-graph(go): root_package '${rootKey}' is not a node in the graph.";
      members = map
        (k:
          if nodes ? ${k} then nodes.${k}
          else throw "package-graph(go): workspace_member '${k}' is not a node in the graph.")
        (spec.workspace_members or [ ]);
    in
    {
      inherit nodes root members stdTree;
      # The parallel PoMS proof tree; std entries filtered out (a std key maps
      # to `null` in the raw fold, dropped here). One ferrite node per buildable
      # (module|main) package, each keyed by the compile node's source_hash.
      ferriteNodes = buildableFerriteNodes;
    };
}
