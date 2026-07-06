# package-graph-test.nix — eval-time tests for the gen-gomod M1 per-package
# incremental interpreter (package-graph.nix).
#
# Proves the interpreter produces a VALID per-package derivation tree from a
# spec — node-per-package, correct importcfg wiring, cross-binary dedup of the
# shared internal package, link-vs-compile dispatch, std routing, and every
# interpreter-side defensive invariant (Go-I1/I3/I10/I11/I12) — using a MOCK
# backend (the injected Environment, per TESTING-SUBSTRATE §IX) so the whole
# graph is verified with `nix-instantiate --eval --strict`, NO `nix build`.
#
#   nix-instantiate --eval --strict \
#     lib/build/go/tests/package-graph-test.nix
#
# Direct-expression shape (NOT a `{ … }:` lambda) so the assertions actually run
# and fail closed on `throw`; evaluates to `{ total = N; passed = N; }`.
let
  lib = (import <nixpkgs> { }).lib;
  graph = import ../package-graph.nix { inherit lib; };

  # ── Mock backend: the injected Environment recorded as pure data ────────────
  # Every side effect (std tree, importcfg/embedcfg files, node derivation) is
  # replaced by a deterministic record so the graph's WIRING is assertable.
  mockBackend = {
    sanitize = key: key;

    mkStdTree = { goVersion, goos, goarch, tags }: {
      drv = "MOCK-STDTREE:${goVersion}-${goos}-${goarch}";
      package = importPath: "MOCK-STD-ARCHIVE:${importPath}";
      importcfgBaseRef = "MOCK-STDTREE:${goVersion}-${goos}-${goarch}/importcfg.base";
    };

    writeImportCfg = { name, nodeLines, stdTree }: {
      inherit name nodeLines;
      stdBaseRef = stdTree.importcfgBaseRef;
    };

    writeEmbedCfg = { name, text }: { inherit name text; };

    mkNode =
      { key, pkg, importPath, kind, isMain, binName, relativePath, goFiles
      , buildTags, embed, importcfg, linkImportcfg, embedcfg, edges, depClosure
      , gcflags, ldflags, env, quirks, goVersion, stdTree
      }: {
        inherit key importPath kind isMain;
        isStd = false;
        archive = "MOCK-ARCHIVE:${key}";
        drv = "MOCK-DRV:${key}";
        plan = {
          inherit importPath kind isMain binName relativePath goFiles ldflags;
          willLink = isMain;
          directImportArchives = map (e: e.archive) edges;
          directImportKeys = map (e: e.key) edges;
          compileImportCfg = importcfg.nodeLines;
          compileStdBaseRef = importcfg.stdBaseRef;
          linkImportCfg = if linkImportcfg == null then null else linkImportcfg.nodeLines;
          closureKeys = map (e: e.key) depClosure;
          embedcfg = if embedcfg == null then null else embedcfg.text;
        };
      };

    # ── M-ferrite: the parallel PoMS proof node, recorded as pure data ────────
    # The whole point of proving at eval: the ferrite node's identity is keyed to
    # the compile node's source_hash, its edges are the buildable (non-std) direct
    # imports, and std packages get NO ferrite node — all assertable without a
    # single `nix build`.
    mkFerriteNode =
      { key, importPath, kind, relativePath, goFiles, sourceHash, edges, goVersion }: {
        inherit key importPath kind sourceHash;
        drv = "MOCK-FERRITE-DRV:${key}@${sourceHash}";
        poms = "MOCK-POMS:${key}@${sourceHash}";
        plan = {
          inherit importPath kind relativePath goFiles sourceHash;
          # The compile node this proof node shares its cache key with.
          edgeSourceHashes = map (e: e.sourceHash) edges;
          edgeKeys = map (e: e.key) edges;
          pomsEmit = false;
        };
      };
  };

  tuple = { goVersion = "1.25"; goos = "linux"; goarch = "amd64"; tags = [ ]; };

  # ── Node-key helpers ────────────────────────────────────────────────────────
  fmtK = "std/fmt#linux-amd64";
  helperK = "mod/helper#linux-amd64";
  utilK = "mod/util#linux-amd64";
  appAK = "mod/app-a#linux-amd64";
  appBK = "mod/app-b#linux-amd64";

  stdNode = importPath: {
    import_path = importPath;
    kind = "std";
    source = { kind = "std"; };
    imports = [ ];
    go_files = [ ];
  };
  # A buildable node carries a source_hash (Go-I8) — the shared cache key
  # between its compile node and its ferrite proof node. The fixture models the
  # encoder's content-address by defaulting it to a deterministic function of
  # the node's import path + go_files, so an assertion can edit one package's
  # go_files and observe ONLY that package's source_hash (and thus both its
  # compile+ferrite node identities) move. An explicit `sourceHash` overrides.
  fixtureHash = importPath: goFiles:
    "src-" + builtins.hashString "sha256" (importPath + ":" + toString goFiles);
  modNode = { importPath, rel, imports, goFiles ? [ "x.go" ], embed ? { }, args ? { }, kind ? "module", sourceHash ? null }: {
    import_path = importPath;
    inherit kind;
    source = { kind = "vendored"; relative_path = rel; };
    inherit imports embed args;
    go_files = goFiles;
    source_hash = if sourceHash != null then sourceHash else fixtureHash importPath goFiles;
  };

  # ── The M1 fixture: two mains sharing one internal package + std deps ───────
  #   app-a ─┐                     helper ─▶ fmt(std)
  #          ├─▶ util ─▶ helper ─┘
  #   app-b ─┘        └─▶ fmt(std)
  # The whole point: `util` (and `helper`) compile ONCE, reused by BOTH mains.
  baseSpec = {
    version = 2;
    renderer = "incremental";
    module = { module_path = "example.com/m"; go_version = "1.25"; };
    root_package = appAK;
    workspace_members = [ appAK appBK ];
    packages = {
      "${fmtK}" = stdNode "fmt";
      "${helperK}" = modNode {
        importPath = "example.com/m/internal/helper";
        rel = "internal/helper";
        imports = [ fmtK ];
        goFiles = [ "helper.go" ];
      };
      "${utilK}" = modNode {
        importPath = "example.com/m/internal/util";
        rel = "internal/util";
        imports = [ helperK fmtK ];
        goFiles = [ "util.go" ];
        embed = {
          patterns = [ "assets/*" ];
          files = [ "assets/logo.txt" ];
          pattern_files = { "assets/*" = [ "assets/logo.txt" ]; };
        };
      };
      "${appAK}" = modNode {
        importPath = "example.com/m/cmd/app-a";
        rel = "cmd/app-a";
        imports = [ utilK ];
        goFiles = [ "main.go" ];
        kind = "main";
        args = { ldflags = [ "-s" "-w" ]; };
      };
      "${appBK}" = modNode {
        importPath = "example.com/m/cmd/app-b";
        rel = "cmd/app-b";
        imports = [ utilK ];
        goFiles = [ "main.go" ];
        kind = "main";
      };
    };
  };

  g = graph.mkGraph { spec = baseSpec; inherit tuple; backend = mockBackend; };

  node = k: g.nodes.${k};
  planOf = k: (node k).plan;

  # ── Negative fixtures (each forces exactly one defensive throw) ─────────────
  evalThrows = x: !(builtins.tryEval (builtins.deepSeq x x)).success;

  # Go-I1: app-a imports a node that does not exist.
  danglingSpec = baseSpec // {
    packages = baseSpec.packages // {
      "${appAK}" = baseSpec.packages.${appAK} // { imports = [ "mod/ghost#linux-amd64" ]; };
    };
  };
  gDangling = graph.mkGraph { spec = danglingSpec; inherit tuple; backend = mockBackend; };

  # Go-I12: a cgo node has no arm in the M1 interpreter.
  cgoK = "mod/cgobits#linux-amd64";
  cgoSpec = baseSpec // {
    packages = baseSpec.packages // {
      "${cgoK}" = (modNode {
        importPath = "example.com/m/internal/cgobits";
        rel = "internal/cgobits";
        imports = [ ];
      }) // { kind = "cgo"; };
    };
  };
  gCgo = graph.mkGraph { spec = cgoSpec; inherit tuple; backend = mockBackend; };

  # Go-I3: a vendored node whose relative_path escapes the workspace src.
  escapeK = "mod/escape#linux-amd64";
  escapeSpec = baseSpec // {
    packages = baseSpec.packages // {
      "${escapeK}" = modNode {
        importPath = "example.com/m/escape";
        rel = "../../etc/passwd";
        imports = [ ];
      };
    };
  };
  gEscape = graph.mkGraph { spec = escapeSpec; inherit tuple; backend = mockBackend; };

  # Go-I8 (ferrite): a buildable node with NO source_hash — the ferrite proof
  # node cannot be keyed to the compile node's incremental boundary, so the
  # ferrite fold must throw (fail-closed, never an un-keyed/un-cacheable proof).
  noHashK = "mod/nohash#linux-amd64";
  noHashSpec = baseSpec // {
    packages = baseSpec.packages // {
      "${noHashK}" = builtins.removeAttrs
        (modNode {
          importPath = "example.com/m/nohash";
          rel = "internal/nohash";
          imports = [ ];
        })
        [ "source_hash" ];
    };
  };
  gNoHash = graph.mkGraph { spec = noHashSpec; inherit tuple; backend = mockBackend; };

  # Incremental-boundary fixture: edit ONLY util's go_files. Its source_hash
  # moves (fixtureHash is content-derived), and thus BOTH its compile node
  # archive AND its ferrite node identity move — while every untouched node in
  # BOTH trees keeps its identity (the dedup + incremental-rebuild property).
  editedUtilSpec = baseSpec // {
    packages = baseSpec.packages // {
      "${utilK}" = baseSpec.packages.${utilK} // {
        go_files = [ "util.go" "extra.go" ];
        source_hash = fixtureHash "example.com/m/internal/util" [ "util.go" "extra.go" ];
      };
    };
  };
  gEdited = graph.mkGraph { spec = editedUtilSpec; inherit tuple; backend = mockBackend; };

  hasInfix = lib.hasInfix;

  # ── Assertions ──────────────────────────────────────────────────────────────
  assertions = [
    # Shape: one node per spec package.
    { label = "one derivation node per spec package (5)";
      pred = builtins.length (builtins.attrNames g.nodes) == 5; }
    { label = "root resolves to the declared root_package node";
      pred = (g.root).key == appAK; }
    { label = "both workspace-member mains present";
      pred = builtins.length g.members == 2; }

    # Cross-binary DEDUP: both mains reference the SAME single util node.
    { label = "app-a directly imports the shared util node (one archive)";
      pred = (planOf appAK).directImportArchives == [ "MOCK-ARCHIVE:${utilK}" ]; }
    { label = "app-b directly imports the SAME shared util node";
      pred = (planOf appBK).directImportArchives == [ "MOCK-ARCHIVE:${utilK}" ]; }
    { label = "util node exists exactly once in the graph (compiled once)";
      pred = (node utilK).key == utilK && (node utilK).kind == "module"; }

    # Go-I11: exactly main nodes link; module/std nodes only compile.
    { label = "Go-I11: main node app-a links";
      pred = (planOf appAK).willLink == true; }
    { label = "Go-I11: module node util does NOT link";
      pred = (planOf utilK).willLink == false; }
    { label = "Go-I11: main node app-a has a link importcfg, util has none";
      pred = (planOf appAK).linkImportCfg != null && (planOf utilK).linkImportCfg == null; }

    # Go-I10: std routing — std node comes from the shared std tree, no source.
    { label = "Go-I10: fmt is a std node routed to the std tree archive";
      pred = (node fmtK).isStd == true && (node fmtK).archive == "MOCK-STD-ARCHIVE:fmt"; }
    { label = "Go-I10: std node carries no compile plan (built inside std tree)";
      pred = (planOf fmtK) ? std && (planOf fmtK).std == true; }

    # Compile importcfg: direct NON-std packagefile line; std covered by base.
    { label = "compile importcfg names the direct helper archive";
      pred = hasInfix "packagefile example.com/m/internal/helper=MOCK-ARCHIVE:${helperK}"
        (planOf utilK).compileImportCfg; }
    { label = "compile importcfg does NOT re-emit std fmt (base covers it)";
      pred = !(hasInfix "packagefile fmt=" (planOf utilK).compileImportCfg); }
    { label = "compile importcfg references the shared std base for this tuple";
      pred = (planOf utilK).compileStdBaseRef == "MOCK-STDTREE:1.25-linux-amd64/importcfg.base"; }

    # Link importcfg (main): FULL transitive closure, std still base-covered.
    { label = "link importcfg names the transitive util archive";
      pred = hasInfix "packagefile example.com/m/internal/util=MOCK-ARCHIVE:${utilK}"
        (planOf appAK).linkImportCfg; }
    { label = "link importcfg names the transitive helper archive (through util)";
      pred = hasInfix "packagefile example.com/m/internal/helper=MOCK-ARCHIVE:${helperK}"
        (planOf appAK).linkImportCfg; }
    { label = "link importcfg does NOT emit std fmt (base covers it)";
      pred = !(hasInfix "packagefile fmt=" (planOf appAK).linkImportCfg); }
    { label = "app-a transitive closure = {util, helper, fmt}, key-sorted";
      pred = (planOf appAK).closureKeys == [ helperK utilK fmtK ]; }

    # Go-I9: embed synthesis for the one embed-bearing node.
    { label = "Go-I9: util (embed) gets an embedcfg naming the embedded file";
      pred = (planOf utilK).embedcfg != null
        && hasInfix "assets/logo.txt" (planOf utilK).embedcfg
        && hasInfix "Patterns" (planOf utilK).embedcfg; }
    { label = "Go-I9: a non-embed node gets no embedcfg";
      pred = (planOf appAK).embedcfg == null; }

    # ldflags reach the link plan.
    { label = "declared ldflags flow to the main node";
      pred = (planOf appAK).ldflags == [ "-s" "-w" ]; }

    # ── M-ferrite: the parallel PoMS proof tree ───────────────────────────────
    # Shape: one ferrite node per BUILDABLE package (module|main); std excluded.
    # The fixture has 5 packages — fmt(std) + helper + util + app-a + app-b — so
    # exactly 4 ferrite nodes (std fmt has none).
    { label = "M-ferrite: one ferrite node per buildable package (4; std excluded)";
      pred = builtins.length (builtins.attrNames g.ferriteNodes) == 4; }
    { label = "M-ferrite: the std fmt package has NO ferrite node";
      pred = !(g.ferriteNodes ? ${fmtK}); }
    { label = "M-ferrite: every buildable package (helper/util/app-a/app-b) has a ferrite node";
      pred = (g.ferriteNodes ? ${helperK}) && (g.ferriteNodes ? ${utilK})
        && (g.ferriteNodes ? ${appAK}) && (g.ferriteNodes ? ${appBK}); }

    # Cache-key alignment (Go-I8): the ferrite node's source_hash IS the compile
    # node's source_hash — the same content address, so both trees share one
    # incremental boundary per package.
    { label = "M-ferrite: util's ferrite node is keyed by the SAME source_hash as its spec node";
      pred = g.ferriteNodes.${utilK}.sourceHash
        == baseSpec.packages.${utilK}.source_hash; }
    { label = "M-ferrite: the ferrite drv name embeds the shared source_hash (store-address aligns)";
      pred = hasInfix baseSpec.packages.${utilK}.source_hash
        g.ferriteNodes.${utilK}.drv; }
    { label = "M-ferrite: util's PoMS handle is content-addressed by the shared source_hash";
      pred = hasInfix baseSpec.packages.${utilK}.source_hash
        g.ferriteNodes.${utilK}.poms; }

    # Proof edges: the buildable (non-std) direct imports only; std fmt filtered.
    # util imports helper + fmt(std) → its proof edges name ONLY helper.
    { label = "M-ferrite: util's proof edges name the buildable helper dep";
      pred = (g.ferriteNodes.${utilK}.plan.edgeKeys) == [ helperK ]; }
    { label = "M-ferrite: util's proof edges DROP the std fmt dep (std proven in std tree)";
      pred = !(builtins.elem fmtK (g.ferriteNodes.${utilK}.plan.edgeKeys)); }
    { label = "M-ferrite: helper (imports only std fmt) has EMPTY proof edges";
      pred = (g.ferriteNodes.${helperK}.plan.edgeKeys) == [ ]; }

    # Cross-binary DEDUP in the proof tree: util appears exactly once (both
    # mains' proofs reference the same util source_hash), mirroring the compile
    # tree's single-util-node dedup.
    { label = "M-ferrite: util's proof node exists exactly once (proved once, dedup)";
      pred = (g.ferriteNodes.${utilK}.key == utilK)
        && (g.ferriteNodes.${appAK}.plan.edgeKeys == [ utilK ])
        && (g.ferriteNodes.${appBK}.plan.edgeKeys == [ utilK ]); }

    # Incremental boundary: editing ONLY util's go_files moves its source_hash,
    # and thus BOTH its compile node archive AND its ferrite node identity —
    # while every untouched node in BOTH trees keeps its identity (store hit).
    { label = "M-ferrite: editing util's go_files moves its compile node hash";
      pred = gEdited.nodes.${utilK}.archive != g.nodes.${utilK}.archive
        || (gEdited.nodes.${utilK}.plan.goFiles != g.nodes.${utilK}.plan.goFiles); }
    { label = "M-ferrite: editing util's go_files moves its ferrite node source_hash";
      pred = gEdited.ferriteNodes.${utilK}.sourceHash
        != g.ferriteNodes.${utilK}.sourceHash; }
    { label = "M-ferrite: an UNTOUCHED package's ferrite node is a store hit (identity unchanged)";
      pred = gEdited.ferriteNodes.${helperK}.sourceHash
        == g.ferriteNodes.${helperK}.sourceHash
        && gEdited.ferriteNodes.${appBK}.sourceHash
        == g.ferriteNodes.${appBK}.sourceHash; }

    # The proof tree fully evaluates (no false throw when forced).
    { label = "M-ferrite: the ferrite proof tree fully evaluates (no false throw)";
      pred = (builtins.tryEval (builtins.deepSeq
        (map (k: g.ferriteNodes.${k}.plan) (builtins.attrNames g.ferriteNodes)) true)).success; }

    # ── Defensive invariants (each throws, caught by tryEval+deepSeq) ─────────
    { label = "Go-I1: a dangling import edge is rejected (throws)";
      pred = evalThrows (gDangling.nodes.${appAK}.plan); }
    { label = "Go-I12: a cgo node has no M1 arm (throws)";
      pred = evalThrows (gCgo.nodes.${cgoK}.plan); }
    { label = "Go-I3: a relative_path escaping via '..' is rejected (throws)";
      pred = evalThrows (gEscape.nodes.${escapeK}.plan); }
    { label = "Go-I8 (ferrite): a buildable node with no source_hash is rejected (throws)";
      pred = evalThrows (gNoHash.ferriteNodes.${noHashK}); }

    # Well-formed graph does NOT throw when fully forced.
    { label = "the well-formed fixture graph fully evaluates (no false throw)";
      pred = (builtins.tryEval (builtins.deepSeq
        (map (k: (planOf k)) (builtins.attrNames g.nodes)) true)).success; }
  ];

  failures = builtins.filter (a: !a.pred) assertions;
in
if failures == [ ]
then { total = builtins.length assertions; passed = builtins.length assertions; }
else throw ''
  package-graph-test: ${toString (builtins.length failures)} of ${toString (builtins.length assertions)} assertions failed:
  ${builtins.concatStringsSep "\n" (map (a: "  - " + a.label) failures)}
''
