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
#
# A produced node record MUST carry `archive` (the compiled `.a` path) and
# `isStd` so dependents can wire it into their importcfg (see resolveEdge).
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
  # Returns { nodes; root; members; stdTree; }.
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
    { inherit nodes root members stdTree; };
}
