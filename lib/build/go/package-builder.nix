# package-builder.nix (Go) — the renderer-dispatching per-package interpreter.
#
# The production entry point of the gen-gomod M1 incremental interpreter, the
# Go analogue of substrate/lib/build/rust/lockfile-builder.nix but keyed on a Go
# PACKAGE (not a whole module): each spec node → one content-addressed Nix
# derivation compiling that package against its already-built dependency closure
# (vendored, zero network), so editing one package rebuilds only that node + its
# transitive dependents, and internal/shared packages compile ONCE and are
# reused across every binary in the monorepo.
#
# Two renderers, dispatched on `spec.renderer` (coarse specs omit the field):
#   * coarse       → the existing whole-module buildGoModule path
#                    (./lockfile-builder.nix resolve → buildGoModule args).
#   * incremental  → the per-package graph (./package-graph.nix), wired here to
#                    the real Environment: pkgs.stdenv.mkDerivation + pkgs.go.
#
# The graph algorithm + every interpreter-side invariant (Go-I1/I3/I10/I11/I12)
# live in the PURE, backend-injected ./package-graph.nix; this file only wires
# the real (side-effecting) backend and the renderer dispatch. The mockable seam
# is proven at eval time by ./tests/package-graph-test.nix.
#
# Filesystem-free per ★★ MAGMA-NATIVE / super-cache-ci intent: the one sanctioned
# reach is the source tree + the Go toolchain the OS must exec; every archive is
# a per-package derivation output the sui store content-addresses.
{ pkgs, lib ? pkgs.lib }:

let
  inherit (builtins) fromJSON readFile pathExists;

  graph = import ./package-graph.nix { inherit lib; };
  coarse = import ./lockfile-builder.nix { inherit pkgs lib; };
  quirkApply = import ../gomod/quirk-apply.nix { inherit lib; };
  mkStdTreeFor = import ./std-tree.nix { inherit pkgs lib; };

  # ── ferrite#check resolution (M-ferrite) ────────────────────────────────────
  # The ferrite compile-time memory-safety analyzer, resolved from the committed
  # ferrite-pin.json via `builtins.getFlake` (mirrors gen-pin.json's self-heal).
  # This IFD-time getFlake against the locked rev does NOT grow any lock. A caller
  # may inject `ferriteCheck` directly (e.g. tests, or a fleet that pins ferrite
  # in its own flake) — the pin is the fallback single source of truth.
  resolveFerriteCheck = ferriteCheck:
    if ferriteCheck != null then ferriteCheck
    else
      let
        ferritePin = builtins.fromJSON (builtins.readFile ./ferrite-pin.json);
        ferriteFlake = builtins.getFlake "github:pleme-io/ferrite/${ferritePin.rev}";
        sys = pkgs.stdenv.hostPlatform.system;
      in
      ferriteFlake.packages.${sys}.check
        or ferriteFlake.packages.${sys}.default;

  # Nix store names allow only [a-zA-Z0-9+._?=-]; a node key
  # ("<import-path>#<goos>-<goarch>[+tag,tag]") carries '/', '#', ',', ':', and
  # spaces. Flatten every disallowed char to '-' so the derivation name is valid.
  sanitize = key:
    lib.replaceStrings [ "/" "#" "," ":" " " ] [ "-" "-" "-" "-" "-" ] key;

  # ── Load the full spec via the shared delta > committed > IFD ladder ────────
  loadBuildSpec = { src, gen ? null, hostPkgs ? pkgs.buildPackages }:
    coarse.resolveSpec { inherit src gen hostPkgs; };

  # ── Resolve the single M1 target tuple ──────────────────────────────────────
  # goVersion from the module; goos/goarch/tags from an explicit `spec.target`
  # when the encoder emits one, else the build platform's Go identifiers.
  goHostOs =
    if pkgs.stdenv.hostPlatform.isDarwin then "darwin"
    else if pkgs.stdenv.hostPlatform.isLinux then "linux"
    else pkgs.stdenv.hostPlatform.parsed.kernel.name;
  goHostArch =
    if pkgs.stdenv.hostPlatform.isAarch64 then "arm64"
    else if pkgs.stdenv.hostPlatform.isx86_64 then "amd64"
    else pkgs.stdenv.hostPlatform.parsed.cpu.name;

  resolveTuple = spec:
    let
      m = spec.module or { };
      t = spec.target or { };
    in
    {
      goVersion = m.go_version or (lib.versions.majorMinor pkgs.go.version);
      goos = t.goos or goHostOs;
      goarch = t.goarch or goHostArch;
      tags = t.tags or [ ];
    };

  # ── Toolchain-parity gate (mirror of mkGoTool's goVersionAssert) ────────────
  # The spec's `-lang` follows go_version; compiling go1.26 source with a go1.25
  # toolchain yields subtly-wrong archives. Refuse at eval, pointing the operator
  # at the fleet rule: pin go.mod to the toolchain minor, never a patch ahead.
  goLangAssert = spec:
    let
      req = (spec.module or { }).go_version or null;
      tool = pkgs.go.version;
    in
    if req != null && builtins.compareVersions req tool > 0
    then throw ''
      package-builder(go): spec go_version ${req} is AHEAD of the substrate Go
      toolchain ${tool}. Compiling with a mismatched -lang produces wrong
      archives. Pin the module's go directive to the toolchain minor
      (${lib.versions.majorMinor tool}) — never a patch ahead of the builder —
      or bump build/go/toolchain.nix.
    ''
    else null;

  # ── The real Environment (side-effecting backend) ───────────────────────────
  realBackend = { workspaceSrc, tuple, hostPkgs, ferriteCheck ? null }:
    let
      resolvedFerrite = resolveFerriteCheck ferriteCheck;
    in
    {
    inherit sanitize;

    mkStdTree = mkStdTreeFor;

    # Node importcfg: node-specific lines then the std base file, concatenated at
    # BUILD time (importcfgBaseRef is a store reference, never readFile → no IFD).
    writeImportCfg = { name, nodeLines, stdTree }:
      pkgs.runCommand name { } ''
        cp ${pkgs.writeText "${name}-node" nodeLines} "$out"
        chmod +w "$out"
        printf '\n' >> "$out"
        cat ${stdTree.importcfgBaseRef} >> "$out"
      '';

    writeEmbedCfg = { name, text }: pkgs.writeText name text;

    # One derivation per Go package (buildGoPackage-style): `go tool compile
    # -pack` → pkg.a; `go tool link` for main nodes (Go-I11). src is the ONE
    # workspace tree; `cd relativePath` selects the package (Go-I3). The
    # per-package derivation hash is the real incremental boundary — editing a
    # node's go_files changes only its hash + its dependents'.
    mkNode =
      { key
      , pkg
      , importPath
      , kind
      , isMain
      , binName
      , relativePath
      , goFiles
      , buildTags
      , embed
      , importcfg
      , linkImportcfg
      , embedcfg
      , edges
      , depClosure
      , gcflags
      , ldflags
      , env
      , quirks
      , goVersion
      , stdTree
      }:
      let
        # Typed GomodQuirk dispatch (build-tag/ldflag/cgo-off/substitute-source/
        # force-vendor-hash) → extra mkDerivation attrs; consumer wins on
        # collision. Zero per-node Nix-attr knowledge (gomod/quirk-apply.nix).
        quirkAttrs = quirkApply.applyQuirks quirks { };

        goos = env.GOOS or tuple.goos;
        goarch = env.GOARCH or tuple.goarch;
        langMinor = lib.versions.majorMinor goVersion;

        drv = pkgs.stdenv.mkDerivation ({
          name = "gopkg-${sanitize key}";
          src = workspaceSrc;
          dontConfigure = true;
          nativeBuildInputs = [ pkgs.go ];

          buildPhase = ''
            runHook preBuild

            export HOME="$TMPDIR"
            export GOCACHE="$TMPDIR/gocache"
            export GOOS="${goos}"
            export GOARCH="${goarch}"
            export CGO_ENABLED=0

            cd ${lib.escapeShellArg relativePath}

            go tool compile \
              -p ${lib.escapeShellArg importPath} \
              -importcfg ${importcfg} \
              ${lib.optionalString (embedcfg != null) "-embedcfg ${embedcfg}"} \
              -complete \
              -lang=go${langMinor} \
              -trimpath "$PWD=>${importPath}" \
              -o pkg.a \
              ${lib.escapeShellArgs goFiles} ${lib.escapeShellArgs gcflags}

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out"
            cp pkg.a "$out/pkg.a"
            ${lib.optionalString isMain ''
              mkdir -p "$out/bin"
              go tool link \
                -importcfg ${linkImportcfg} \
                -buildmode=exe \
                ${lib.escapeShellArgs ldflags} \
                -o "$out/bin/${binName}" pkg.a
            ''}
            runHook postInstall
          '';

          passthru = { inherit importPath key kind; };
        } // quirkAttrs);
      in
      {
        inherit key importPath kind isMain;
        isStd = false;
        archive = "${drv}/pkg.a";
        inherit drv;
        plan = {
          inherit importPath kind isMain binName relativePath goFiles buildTags;
          willLink = isMain;
        };
      };

    # One ferrite proof derivation per buildable package (M-ferrite). Runs the
    # ferrite compile-time memory-safety analyzer over THIS package's go_files
    # and writes a per-package PoMS JSON to `$out/poms/`. src is the ONE
    # workspace tree; `cd relativePath` selects the package (Go-I3) — the same
    # hermetic env as the compile node (CGO_ENABLED=0, GOPROXY=off). Because the
    # graph keys this node's identity to the compile node's `source_hash`
    # (Go-I8), its derivation is a pure function of the same package source, so
    # an unchanged package's proof is a store hit — the memory-safety proof is
    # not recomputed. `edges` carry the direct-dep source_hashes purely for the
    # audit `plan`; the proof itself runs against the vendored source tree.
    #
    # LiveTODO (honest, inline): the shipped ferrite-check has no per-package
    # PoMS emission flag yet — that is surface (f0) (ferrite/poms-emit), which
    # lands on ferrite main via PR. Until the ferrite-pin.json rev is bumped to
    # the poms-emit rev, `ferriteFlagAvailable` is false: this derivation runs
    # `ferrite-check <pkg>` (the analyzer, exit 0 on a clean pass) and records a
    # `pending-poms-emit` marker instead of a real PoMS. The graph WIRING +
    # cache-key alignment is proven at eval regardless; the realize path emits a
    # true PoMS only once f0 ships. Never round this up to "emits a PoMS today".
    mkFerriteNode =
      { key
      , importPath
      , kind
      , relativePath
      , goFiles
      , sourceHash
      , edges
      , goVersion
      }:
      let
        # Whether the resolved ferrite-check exposes the -ferrite.poms-dir flag
        # (surface f0). Detected by a passthru marker on the ferrite package; a
        # ferrite build predating f0 lacks it, so we fall back to a proof-only
        # run + a pending marker rather than passing an unknown flag.
        ferriteFlagAvailable =
          resolvedFerrite.passthru.pomsEmit or false;

        # The pre-f0 honest pending marker, emitted through the typed JSON
        # serializer (builtins.toJSON → pkgs.writeText — TYPED EMISSION surface
        # #3, never a heredoc of hand-composed JSON). Copied into the PoMS dir
        # when the pinned ferrite predates the -ferrite.poms-dir flag.
        pendingMarker = pkgs.writeText "ferrite-poms-pending-${sanitize key}.json"
          (builtins.toJSON {
            schema = "pleme-io.ferrite.poms/pending";
            status = "pending-f0";
            import_path = importPath;
            source_hash = sourceHash;
            note = "ferrite-check ran clean but the pinned ferrite predates the -ferrite.poms-dir emission flag (surface f0). Bump ferrite-pin.json to the poms-emit rev for a real PoMS.";
          });

        drv = pkgs.stdenv.mkDerivation {
          name = "ferrite-poms-${sanitize key}";
          src = workspaceSrc;
          dontConfigure = true;
          nativeBuildInputs = [ pkgs.go resolvedFerrite ];

          # The proof is keyed to the compile node's incremental boundary: the
          # source_hash is a passthru + an env var so the derivation hash tracks
          # the same content address the compile node uses (Go-I8). Editing the
          # package's go_files moves both node hashes together; nothing else.
          FERRITE_SOURCE_HASH = sourceHash;

          buildPhase = ''
            runHook preBuild

            export HOME="$TMPDIR"
            export GOCACHE="$TMPDIR/gocache"
            export GOOS="${tuple.goos}"
            export GOARCH="${tuple.goarch}"
            export CGO_ENABLED=0
            export GOFLAGS=-mod=vendor
            export GOPROXY=off

            cd ${lib.escapeShellArg relativePath}
            mkdir -p "$TMPDIR/poms"

            ${if ferriteFlagAvailable then ''
              # f0-capable ferrite: emit a real per-package PoMS.
              ferrite-check -ferrite.poms-dir="$TMPDIR/poms" ./
            '' else ''
              # Pre-f0 interim: run the analyzer (exit 0 on a clean pass) and
              # record an honest pending marker — NOT a real PoMS. Tier-honest:
              # the proof leaf is not emitted until ferrite/poms-emit ships. The
              # marker itself is the typed-JSON `pendingMarker` store path.
              ferrite-check ./
              cp ${pendingMarker} "$TMPDIR/poms/pending-poms-emit.json"
            ''}

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/poms"
            cp -r "$TMPDIR/poms/." "$out/poms/"
            runHook postInstall
          '';

          passthru = {
            inherit importPath key kind sourceHash;
            pomsEmit = ferriteFlagAvailable;
          };
        };
      in
      {
        inherit key importPath kind sourceHash drv;
        poms = "${drv}/poms";
        plan = {
          inherit importPath kind relativePath goFiles sourceHash;
          # The direct-dep source_hashes this proof node depends on (audit only;
          # the derivation input is the vendored source, not these hashes).
          edgeSourceHashes = map (e: e.sourceHash) edges;
          pomsEmit = ferriteFlagAvailable;
        };
      };
  };

  # ── Renderer dispatch ───────────────────────────────────────────────────────
  mkProject =
    { src
    , spec ? loadBuildSpec { inherit src; }
    , tuple ? resolveTuple spec
    , hostPkgs ? pkgs.buildPackages
      # Optional caller-injected ferrite#check; else resolved from ferrite-pin.json
      # at IFD (M-ferrite). Threaded to the real backend's mkFerriteNode.
    , ferriteCheck ? null
    }:
    let
      renderer = spec.renderer or "coarse";
    in
    if renderer == "coarse" then
    # The whole-module buildGoModule path. Resolve the typed args; the caller
    # (mkGoTool) spreads them into buildGoModule. Incremental is opt-in via
    # `renderer: incremental` in the spec.
      {
        renderer = "coarse";
        coarseArgs = coarse.resolve { inherit src hostPkgs; };
      }
    else if renderer == "incremental" then
      let
        _ = goLangAssert spec;
        backend = realBackend { workspaceSrc = src; inherit tuple hostPkgs ferriteCheck; };
        g = graph.mkGraph { inherit spec tuple backend; };
      in
      builtins.seq _ {
        renderer = "incremental";
        inherit (g) nodes ferriteNodes root members stdTree;
        # The linked root binary + a symlinkJoin of every main (the many-mains
        # monorepo shape: logan/gator/auth/… each a member).
        rootBin = g.root.drv;
        allMains = pkgs.symlinkJoin {
          name = "go-all-mains";
          paths = map (m: m.drv) g.members;
        };
        # The whole per-package memory-safety proof surface: one PoMS dir per
        # buildable package, joined into one tree. Each is a content-addressed
        # derivation output the sui TieredBackend store dedups exactly like the
        # compile `.a` archives — the attest leg (surface c) reads this.
        allPoms = pkgs.symlinkJoin {
          name = "go-all-poms";
          paths = map (n: n.drv) (builtins.attrValues g.ferriteNodes);
        };
      }
    else throw "package-builder(go): unknown renderer '${renderer}' (expected coarse | incremental).";

in
{
  inherit mkProject loadBuildSpec resolveTuple sanitize;
  # Expose the pure graph builder for advanced/composed use.
  inherit (graph) mkGraph m1Kinds;
}
