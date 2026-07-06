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
  modNode = { importPath, rel, imports, goFiles ? [ "x.go" ], embed ? { }, args ? { }, kind ? "module" }: {
    import_path = importPath;
    inherit kind;
    source = { kind = "vendored"; relative_path = rel; };
    inherit imports embed args;
    go_files = goFiles;
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

    # ── Defensive invariants (each throws, caught by tryEval+deepSeq) ─────────
    { label = "Go-I1: a dangling import edge is rejected (throws)";
      pred = evalThrows (gDangling.nodes.${appAK}.plan); }
    { label = "Go-I12: a cgo node has no M1 arm (throws)";
      pred = evalThrows (gCgo.nodes.${cgoK}.plan); }
    { label = "Go-I3: a relative_path escaping via '..' is rejected (throws)";
      pred = evalThrows (gEscape.nodes.${escapeK}.plan); }

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
