# Pure-dispatch Rust builder over gen's typed Cargo.build-spec.json.
#
# Rust (gen-cargo) does the parsing + sha256 prefetch + URL
# normalization + workspace inheritance. This file is the Nix
# composition layer: tagged-enum source dispatch, lazy mapAttrs over
# the dep graph, attrset assembly. No string munging, no regex, no
# fromTOML, no override-as-data decoding.
#
# Override composition: callers compose `defaultCrateOverrides` upstream
# (nixpkgs defaults + plemeCrateOverrides + user overrides) and pass the
# merged attrset in. Single composition channel — same shape nixpkgs
# uses everywhere.
{ pkgs, lib ? pkgs.lib }:

let
  inherit (builtins) fromJSON readFile pathExists map;

  loadBuildSpec = src:
    let path = src + "/Cargo.build-spec.json"; in
    if pathExists path
    then fromJSON (readFile path)
    else throw ''
      lockfile-builder: ${toString src}/Cargo.build-spec.json not found.
      Run `gen build .` in the workspace root to produce it.
    '';

  # Strip any `?branch=…` / `?ref=…` query string from a git URL.
  #
  # gen is supposed to pre-clean URLs into pkgs.fetchgit's expected
  # shape, but historically it has lifted the literal Cargo.lock
  # `source` URL (which is `git+https://host/repo?branch=main#<rev>`)
  # and emitted `https://host/repo?branch=main` into Cargo.build-spec.
  # json. git CLI then interprets the `?branch=main` as part of the
  # repo path — `git ls-remote https://github.com/foo/bar?branch=main`
  # asks GitHub for the repo named `bar?branch=main`, which 404s.
  #
  # The substrate's load-bearing fix is here: normalize the URL once
  # before handing to fetchgit, so every consumer (namimado, nami,
  # future Cargo.build-spec.json builds) is immune to that gen bug
  # class without touching individual repos. Per the prime-directive
  # "fix upstream, not the local symptom" rule.
  stripUrlQuery = url:
    let m = builtins.match "([^?]+)\\?.*" url; in
    if m == null then url else builtins.head m;

  # Registry URL canonicalization. Old gen versions (< 70774a2) emitted
  # `https://crates.io/api/v1/crates/<name>/<ver>/download`, which is
  # the redirect entrypoint. crates.io has started serving HTTP 403 on
  # that URL for any request without a `User-Agent` header — and
  # nixpkgs' fetchurl invokes curl without one by default. Rewrite to
  # the canonical immutable CDN URL (`static.crates.io`) the redirect
  # would have pointed at. Idempotent: URLs already in CDN form pass
  # through unchanged.
  canonicalRegistryUrl = name: version: url:
    let
      apiPrefix = "https://crates.io/api/v1/crates/";
      isApiUrl = lib.hasPrefix apiPrefix url;
    in if isApiUrl
       then "https://static.crates.io/crates/${name}/${name}-${version}.crate"
       else url;

  # Tagged-enum dispatch on source.kind. URLs are pre-cleaned by gen
  # — `stripUrlQuery` is belt-and-suspenders for the documented gen
  # `?branch=main`-leak class.
  #
  # Workspace-subdir narrowing for git deps: gen-cargo emits one
  # `source` entry per crate, but multiple crates can share the same
  # git rev when the repo is a Cargo workspace (e.g. tatara-lisp
  # ships tatara-lisp + tatara-lisp-derive + 14 others at the same
  # rev). For those, the fetched tarball is the workspace root, not
  # the crate root. We narrow by name when `${full}/${crateName}/
  # Cargo.toml` exists — that's the conventional layout. Falls
  # through to the unnarrowed root when the repo is a single-crate
  # source.
  # Factory: produce `srcOf` closed over `fetchPkgs` (host pkgs, not
  # the cross-target pkgs). When `pkgs` is pkgsStatic (cross-musl),
  # `pkgs.fetchgit` inherits the pkgsStatic cross-build stdenv
  # (NIX_CFLAGS_LINK=-static, --host=x86_64-unknown-linux-musl, etc.).
  # FODs running under that stdenv lose host network — fetchgit's
  # git-clone fails with "Could not resolve host: github.com" on hosts
  # whose DNS is dnsmasq-mediated (rio). Use hostPkgs.fetchgit so the
  # FOD runs in the host-native stdenv with normal network access.
  # Source fetches are platform-independent — they just download bytes.
  mkSrcOf = fetchPkgs: workspaceSrc: spec:
    if spec.source.kind == "registry" then
      fetchPkgs.fetchurl {
        url = canonicalRegistryUrl spec.name spec.version spec.source.url;
        sha256 = spec.source.sha256;
        name = spec.source.name_with_ext;
      }
    else if spec.source.kind == "git" then
      let
        full = fetchPkgs.fetchgit {
          url = stripUrlQuery spec.source.url;
          rev = spec.source.rev;
          sha256 = spec.source.sha256 or lib.fakeSha256;
        };
        # Conventional workspace-member layouts we look for, in order.
        # Adding a new layout = one entry here; the first hit wins.
        # tatara/escriba ship members at `<root>/<name>` (flat); ishou
        # ships them at `<root>/crates/<name>` (the "crates/" convention).
        # Tier 3+ repos can opt in by following one of these conventions.
        candidates = [
          (full + "/${spec.name}")
          (full + "/crates/${spec.name}")
        ];
        firstMatch = lib.findFirst
          (p: builtins.pathExists (p + "/Cargo.toml"))
          null
          candidates;
      in
        if firstMatch != null
        then firstMatch
        else full
    else
      # Path source = workspace member (or root). ALWAYS use the full
      # workspace root so `include_str!("../../sibling.lisp")` from a
      # member's src/lib.rs can reach files at the workspace root.
      # libPath / build_script in build_rust_crate_args must be prefixed
      # with relative_path to compensate — handled in `prefixForMember`.
      workspaceSrc;

  # Triple-aware: imported as a function `triple -> overrides`. Each
  # tree-builder specializes the overrides for its target triple, so
  # substrate-level safety nets (e.g. apple-only feature strip on
  # notify) fire only on the targets they're protecting.
  plemeCrateOverridesFor = import ./pleme-crate-overrides.nix;
  # Mechanical dispatch layer for typed `CrateQuirk` variants emitted
  # by gen-cargo. Class-helper functions (forceCfg /
  # foldNormalIntoBuild / substituteSource); per-crate knowledge of
  # WHICH crates need WHICH quirks lives in
  # `gen-cargo/src/quirks.rs::REGISTRY` (Rust source of truth).
  quirkApply = import ./quirk-apply.nix { inherit lib; };
  mkProject = {
    src,
    # Substrate guarantee: every fleet-wide buildRustCrate quirk in
    # plemeCrateOverrides applies by default. Callers can still pass an
    # explicit `defaultCrateOverrides` to extend — the merge order is
    # nixpkgs defaults → pleme overrides → caller overrides (later wins).
    # Default merges plemeCrateOverrides specialized to the *target*
    # triple — host-tree builds further specialize via overrideFor's
    # triple-aware path inside mkBuiltTree. Callers that pass their
    # own defaultCrateOverrides override the default entirely. The
    # triple is computed from `pkgs` directly (rather than referencing
    # the `targetTriple` let-binding defined later in mkProject) to
    # keep the parameter default self-contained.
    defaultCrateOverrides ? (pkgs.defaultCrateOverrides // (plemeCrateOverridesFor pkgs.stdenv.hostPlatform.rust.rustcTarget)),
    buildRustCrateForPkgs ? (p: p.buildRustCrate),
    # Auto-detected: pulls from `pkgs.gen` when substrate's rust
    # overlay (or any overlay that adds `gen`) is composed. Per the
    # GEN TYPED-SPEC CONTRACT (`theory/GEN-TYPED-SPEC-CONTRACT.md`),
    # regeneration is BACKGROUND TO REBUILD — never a manual step.
    # When `gen` is reachable AND the committed spec is missing or
    # invariant-violating (stale), the build-spec is regenerated via
    # IFD before lockfile composition. Operators see "auto-regen"
    # transparently as part of `nix build`; they never run
    # `gen build .` by hand. Callers may pass an explicit `gen` to
    # override the auto-detection.
    gen ? (pkgs.gen or null),
    # Host pkgs for the IFD auto-regen. When `pkgs` is pkgsStatic (cross
    # builds), `pkgs.buildPackages` is pkgsStatic itself — not the
    # build-machine's darwin/linux native pkgs. The IFD always runs at
    # eval time on the build host, so it needs native cargo/rustc/cacert.
    # Default falls back to `pkgs.buildPackages` for native builds where
    # the two are equivalent; cross consumers (tool-release.nix) pass
    # the explicit darwin/linux host pkgs.
    hostPkgs ? pkgs.buildPackages,
  }: let
    specInvariants = import ./spec-invariants.nix;
    # I4 — per-platform spec emission. gen-cargo's --filter-platform
    # has cargo resolve cfg(target_os=…) / cfg(target_vendor=…) /
    # cfg(any/all/not(…)) / custom-cfg expressions for the given
    # triple; substrate consumes the resolved dep edges directly. No
    # Nix-side cfg parsing, no risk of getting it wrong on the
    # gnarly nested cfg expressions real-world crates emit
    # (rustix_use_experimental_asm, getrandom_backend, …). For
    # cross-builds the target tree and host tree get separate
    # platform-filtered specs.
    # rustc-style triple (aarch64-apple-darwin) vs Nix-style
    # (arm64-apple-darwin); nixpkgs exposes the canonical rustc form
    # under `.rust.rustcTarget` on every platform object. Use that
    # consistently so `gen build --filter-platform=<triple>` matches
    # what rustc expects.
    targetTriple = pkgs.stdenv.hostPlatform.rust.rustcTarget;
    # Must use the explicit hostPkgs — NOT pkgs.buildPackages. For
    # pkgsStatic, `pkgs.buildPackages` is pkgsStatic itself (same
    # store path), so its rustcTarget == targetTriple and isCross
    # falsely reports false. Without this fix, cross-musl builds
    # never engage the dual-tree dispatch.
    hostTriple = hostPkgs.stdenv.hostPlatform.rust.rustcTarget;
    isCross = targetTriple != hostTriple;

    # 1) Try the committed spec first (cheap, no IFD). Note: committed
    #    specs are typically multi-platform (no --filter-platform was
    #    passed when emitted), so they may contain cfg-conditional
    #    deps that don't apply to the current target. For native
    #    builds where the committed spec was generated on the same
    #    platform, this is usually fine. For cross-builds or where
    #    cfg-impossible deps exist, regen via IFD with the explicit
    #    target triple is required.
    committedPath = src + "/Cargo.build-spec.json";
    committedSpec =
      if builtins.pathExists committedPath
      then fromJSON (readFile committedPath)
      else null;
    committedViolations =
      if committedSpec == null then [ "spec-missing" ]
      else specInvariants committedSpec;
    # Per the primary theory ('regeneration is BACKGROUND to rebuild,
    # never an operator step'), trigger auto-regen on EVERY eval where
    # `gen` is reachable — the committed spec is a cache hint, not the
    # source of truth. Without this, native-platform builds with a
    # clean-but-unfiltered committed spec would silently use cfg-
    # impossible dep edges (the rio darwin-only-on-linux trap). cargo's
    # resolver via gen --filter-platform is the only correct source
    # of platform-resolved dep edges.
    #
    # Cost: each build triggers an IFD running `gen build` (~30s-2min
    # on first run; cached afterwards). The hermetic gen-cargo rewrite
    # (no cargo metadata shell-out, no network) collapses this to a
    # pure derivation. Until then, the cost is the price of correctness.
    #
    # When gen is unavailable, fall back to the committed spec +
    # invariant violations as the regen trigger (lower correctness,
    # higher availability).
    needsRegenTarget =
      if gen != null then true
      else committedViolations != [];

    # 2) Per-tree IFD: each tree gets its own platform-filtered spec
    #    when gen is reachable. Native builds reuse the target spec
    #    for the host tree (targetTriple == hostTriple so the filter
    #    yields identical results). Cross-builds emit two specs.
    targetSpecDrv =
      if needsRegenTarget && gen != null
      then import ./mk-build-spec.nix {
        inherit hostPkgs gen src;
        target = targetTriple;
      }
      else null;
    hostSpecDrv =
      if needsRegenTarget && gen != null && isCross
      then import ./mk-build-spec.nix {
        inherit hostPkgs gen src;
        target = hostTriple;
      }
      else targetSpecDrv;  # native: reuse.

    specTarget =
      if targetSpecDrv != null
      then loadBuildSpec targetSpecDrv
      else loadBuildSpec src;
    specHost =
      if hostSpecDrv != null && hostSpecDrv != targetSpecDrv
      then loadBuildSpec hostSpecDrv
      else specTarget;

    # `spec` retained for upstream callers that read it from the
    # return value (workspaceMembers, root_crate). Use the target
    # spec since that's the workload-facing view.
    spec = specTarget;
    needsRegen = needsRegenTarget;  # legacy alias for _regenAssert.
    # If regen wasn't possible (gen unavailable) but the committed spec
    # had violations, surface a traced warning so the operator knows
    # the build is running on synthesized fallbacks instead of a true
    # regen. Hard error only when the synthesis can't cover (e.g.
    # missing-spec without gen).
    _regenAssert =
      if needsRegen && gen == null then
        if committedSpec == null then
          throw ''
            substrate/lockfile-builder: ${toString src}/Cargo.build-spec.json
            not found AND `gen` is not reachable (pkgs.gen is unset).
            Either:
              (a) compose substrate's rust overlay (provides pkgs.gen) →
                  auto-regen will take over, OR
              (b) pass `gen = substrate.packages.<system>.gen` to
                  lockfileBuilder.mkProject explicitly, OR
              (c) run `gen build .` once in the workspace root to
                  produce the committed spec.
            Per the GEN TYPED-SPEC CONTRACT, (a) is the directive-
            aligned default — no per-repo regen toil.
          ''
        else builtins.trace ''
          substrate/lockfile-builder: committed Cargo.build-spec.json has
          invariant violations:
          ${builtins.concatStringsSep "\n  " (map (v: "  - " + v) committedViolations)}
          `gen` is unreachable (pkgs.gen unset) — falling back to
          spec-side synthesis (lib_target etc.). Compose substrate's
          rust overlay or pass `gen` to mkProject for true auto-regen.
        '' null
      else null;
    # Single sentinel forces evaluation of both side-effect-only
    # bindings (`builtins.seq` chains them deterministically).
    _ = builtins.seq _specVersionAssert _regenAssert;
    # Invariant E: schema-version gate. Substrate's lockfile-builder
    # is contracted against `Cargo.build-spec.json` v3+ (pre-shaped
    # `build_rust_crate_args`). Older specs must be regenerated; we
    # accept v2 transitionally during M5 with a warning that points
    # operators at `gen build .`. Sunset at M6.
    _specVersionAssert =
      let v = spec.version or 0; in
      if v >= 3 then null
      else if v == 2 then builtins.trace ''
        substrate/lockfile-builder: ${toString src}/Cargo.build-spec.json is v2.
        Regenerate with `gen build .` (gen >= c9a0067) — legacyArgs
        backward-compat will sunset at M6. Spec v3 adds typed
        `build_rust_crate_args` + universal `preBuild` + `links`.
      '' null
      else throw ''
        substrate/lockfile-builder: ${toString src}/Cargo.build-spec.json
        has unsupported schema version ${toString v}. Run `gen build .`
        in the workspace root (gen >= c9a0067) to regenerate against
        SCHEMA_VERSION 3.
      '';
    # I2 — proc-macro host placement (GEN TYPED-SPEC CONTRACT invariant).
    #
    # Proc-macro crates run INSIDE rustc at compile time on the BUILD
    # (host) architecture — never the workload's target arch. cargo
    # follows this rule by default. substrate's earlier single-pkgs
    # design collapsed this distinction and cross-compiled proc-macros
    # to the workload's target (e.g. musl), producing a `-lgcc_s` link
    # failure (musl static linking lacks libgcc_s).
    #
    # Two parallel built trees mirror crate2nix-internal-helpers.nix:
    # - `built` uses `pkgs.buildRustCrate` (workload/target arch).
    #   runtime_dependencies dispatch by spec.crates.${id}.proc_macro:
    #   true → builtBuild (host); false → built (target).
    #   build_dependencies ALWAYS route to builtBuild (build.rs runs on
    #   host).
    # - `builtBuild` uses `pkgs.buildPackages.buildRustCrate` (host
    #   arch); EVERY dep routes to builtBuild — the proc-macro graph is
    #   transitively host.
    #
    # For native builds (hostPkgs == pkgs), the two trees yield
    # identical derivations — the dispatch is a no-op. Real divergence
    # only happens for cross-builds (musl-from-gnu, darwin-from-linux,
    # etc.). hostPkgs is required here (NOT pkgs.buildPackages) because
    # pkgsStatic.buildPackages == pkgsStatic, which collapses the
    # host/target distinction and routes proc-macro builds to the
    # workload's static musl stdenv → autocfg/E0461 target mismatch.
    buildRustCrateTarget = buildRustCrateForPkgs pkgs;
    buildRustCrateHost = buildRustCrateForPkgs hostPkgs;

    workspaceKeys = builtins.listToAttrs
      (map (k: { name = k; value = true; }) spec.workspace_members);
    isWorkspaceMember = key: workspaceKeys ? ${key};

    # Workspace members declare their [[bin]]s explicitly from the
    # spec. Transitive deps get `crateBin = []` to SUPPRESS
    # buildRustCrate's `src/bin/*.rs` auto-detection — those bin
    # files (alloc-no-stdlib's `heap_alloc.rs`, brotli's `brotli.rs`,
    # dotenvy's `dotenvy.rs`, etc.) typically require feature-gated
    # deps (clap, --extern <crate>) that the substrate doesn't pass
    # in, so the bin build fails even though every consumer only
    # ever needs the lib. The explicit `crateBin = []` sets
    # `hasCrateBin` in buildRustCrate, which short-circuits the
    # auto-detection and still allows the lib to build normally.
    # Per-crate overrides in `pleme-crate-overrides.nix` are no
    # longer needed for the alloc-no-stdlib / brotli class of bug —
    # the fix is uniform here.
    # crateBin is the one buildRustCrate arg that depends on
    # workspace-membership context (Nix-side knowledge), so it's
    # computed here rather than in gen. Workspace members keep their
    # declared bins; transitive deps get `crateBin = []` to suppress
    # buildRustCrate's `src/bin/*.rs` auto-detection.
    binsFor = key: crate:
      let bins = map (b: { inherit (b) name path; }) (crate.binaries or []);
      in
        if isWorkspaceMember key
        # ANY workspace member: if the spec says no bins, declare
        # `crateBin = []` explicitly to suppress buildRustCrate's
        # default `src/main.rs` auto-detection. Workspace-relative
        # src means that detection lands on the workspace ROOT's
        # src/main.rs (an orphan file in repos like tatara that
        # split into a multi-crate layout), compiling it as a bin
        # named after the wrong package and failing on dozens of
        # unresolved imports the orphan source uses. The empty list
        # matches cargo metadata's authoritative "no bin targets".
        then (if bins != [] then { crateBin = bins; } else { crateBin = []; })
        else { crateBin = []; };

    # Always layer plemeCrateOverrides in — even when the caller passed
    # their own `defaultCrateOverrides`. Consumers that import
    # lockfile-builder directly (escriba's flake.nix is the canonical
    # example) would otherwise silently drop every fleet-wide quirk we
    # ship (wgpu-hal cfg, openraft BTreeSet patch, document-features
    # lib_target, etc.). Compose per-crate: pleme rules apply first,
    # caller wins on key collision.
    #
    # Triple-aware: each tree-builder (target or host) computes its
    # own plemeCrateOverrides map specialized to the triple it's
    # building for. Substrate-level safety nets (apple-only feature
    # strip on notify, etc.) fire only on the triples they protect.
    overrideFor = triple: name:
      let
        plemeForTriple = plemeCrateOverridesFor triple;
        pleme  = plemeForTriple.${name}    or null;
        caller = defaultCrateOverrides.${name} or null;
      in
        if pleme == null && caller == null then (oldAttrs: oldAttrs)
        else if pleme == null then caller
        else if caller == null then pleme
        else (attrs: (pleme attrs) // (caller attrs));

    # gen ≥ 3e9fbc6 emits `build_rust_crate_args` pre-shaped for
    # buildRustCrate (procMacro, build, links, libName, libPath, …).
    # Nix spreads it verbatim and fills only what it must: `src`
    # (path resolution + workspace narrowing) and the cross-derivation
    # `dependencies` / `buildDependencies`. For older specs that
    # predate the field, reconstruct from the legacy fields so the
    # transition is silent.
    # Rustc crate-name = `[lib].name` when set, else package name with
    # `-` → `_`. Used to set CARGO_CRATE_NAME universally for crates
    # that read it at compile time (rmcp etc). Matches gen-cargo's
    # computation for `build_rust_crate_args.preBuild`.
    rustcCrateName = crate:
      if (crate.lib_target or null) != null
      then crate.lib_target.name
      else builtins.replaceStrings [ "-" ] [ "_" ] crate.name;

    # I1 — Workspace-member lib_target synthesis (stale-spec defense).
    # Per the GEN TYPED-SPEC CONTRACT (theory/GEN-TYPED-SPEC-CONTRACT.md,
    # invariant I1), gen-cargo ≥ 09f6311 always emits lib_target for
    # workspace-member lib crates. Pre-09f6311 specs (still committed in
    # some downstream repos like ishou pre-regeneration) suppressed it
    # for default-named members → substrate would pass no libName/libPath
    # to buildRustCrate → with src = workspaceSrc, rustc resolved
    # `src/lib.rs` against the workspace root (no such file) → no rlib
    # built → consumer's --extern hard-failed.
    #
    # Synthesis is the interpreter side of the contract: when a
    # path-source member with a non-trivial relative_path arrives
    # WITHOUT lib_target AND WITHOUT binaries, assume the conventional
    # `src/lib.rs` + `rustcCrateName` and let `prefixForMember` glue the
    # relative_path on. The fleet self-heals against stale specs without
    # every consumer needing to push a regen.
    synthLibTarget = crate:
      let
        srcKind = crate.source.kind or null;
        rel = crate.source.relative_path or "";
        hasMember = srcKind == "path" && rel != "" && rel != ".";
        hasNoTargets = (crate.lib_target or null) == null
          && ((crate.binaries or []) == []);
      in
        if hasMember && hasNoTargets
        then { libName = rustcCrateName crate; libPath = "src/lib.rs"; }
        else {};

    legacyArgs = crate:
      { crateName = crate.name; version = crate.version; edition = crate.edition;
        features = crate.features; crateRenames = crate.crate_renames; release = true;
        preBuild = "export CARGO_CRATE_NAME=${rustcCrateName crate};"; }
      // (if crate.proc_macro then { procMacro = true; } else {})
      // (if crate.build_script != null then { build = crate.build_script; } else {})
      // (if (crate.links or null) != null then { links = crate.links; } else {})
      // (if (crate.lib_target or null) != null
          then { libName = crate.lib_target.name; libPath = crate.lib_target.path; }
          else {});

    # Apply lib_target synthesis to ANY args-source missing libName/libPath
    # (legacyArgs OR spread build_rust_crate_args). Idempotent: if the args
    # already declare libName, the synthesis no-ops. When the spec
    # carries `binaries` but no `lib_target` (a bin-only workspace
    # member), explicitly point `libPath` at the member's own
    # `<relative_path>/src/lib.rs` — which doesn't exist — so
    # buildRustCrate's existence check skips the lib build instead
    # of auto-detecting the workspace ROOT's orphan src/lib.rs
    # (present in repos like tatara that split a former monolithic
    # crate into N workspace members; the orphan lib.rs at root
    # gets compiled as a lib named after EVERY bin-only member and
    # fails on dozens of unresolved imports the orphan source uses).
    applySynthLibTarget = crate: args:
      # NOTE: `args ? libName` is `true` even when the attr's value is
      # `null` (Rust's `lib_name: Option<String> = None` serializes to
      # JSON null which Nix reads as the value null, with the attr
      # PRESENT). Filter explicitly on null so the bin-only branch
      # fires when build_rust_crate_args carries libName=null.
      if (args ? libName) && args.libName != null then args
      else
        let
          # Only path-source workspace members trigger the orphan-rm. For
          # registry/git crates, gen-cargo intentionally suppresses
          # lib_target when name+path match the buildRustCrate defaults
          # (see gen/crates/gen-cargo/src/build_spec.rs:756 — `is_default &&
          # !is_member`), letting buildRustCrate's auto-discovery handle
          # the lib build with `crate-type = ["proc-macro", "rlib"]` etc.
          # The orphan-rm must NOT fire on those — clap-4.6.1 ships
          # lib_target=None + binaries=[{stdio-fixture}] for this exact
          # reason. Removing its src/lib.rs would yield an empty drv.
          binsOnly = crate.source.kind == "path"
            && (crate.lib_target or null) == null
            && ((crate.binaries or []) != []);
          rel = crate.source.relative_path or "";
          # Substrate uses `src = workspaceSrc` for path-source workspace
          # members so `include_str!("../sibling.lisp")` works. Side
          # effect: the unpacked source tree HAS the workspace root,
          # not the member subdir. nixpkgs' buildRustCrate's
          # build-crate.nix lib-build logic:
          #
          #   if   [[ -e "$LIB_PATH"  ]] then build_lib "$LIB_PATH"
          #   elif [[ -e src/lib.rs   ]] then build_lib src/lib.rs
          #
          # ...has an `elif` that fires on the workspace-root orphan
          # `src/lib.rs` (present in repos like tatara that split a
          # former monolithic crate into a workspace, leaving the old
          # ./src/lib.rs at root) even when LIB_PATH is a non-existent
          # `<rel>/src/lib.rs`. Setting LIB_PATH alone is insufficient;
          # the orphan must be physically removed from the unpacked
          # source before buildPhase. Inject the removal into preBuild.
          binsOnlyPreBuild = ''
            # Suppress workspace-root orphan src/lib.rs detection.
            # Spec says this member is bin-only (no lib_target); the
            # workspace root's leftover src/lib.rs is not OUR lib.
            if [[ -e src/lib.rs && ! -e "${rel}/src/lib.rs" ]]; then
              rm src/lib.rs
              echo "substrate: removed workspace-root orphan src/lib.rs (no lib_target for ${crate.name})"
            fi
            if [[ -e src/main.rs && ! -e "${rel}/src/main.rs" ]]; then
              rm src/main.rs
              echo "substrate: removed workspace-root orphan src/main.rs (no orphan-bin allowed for ${crate.name})"
            fi
          '';
          existingPreBuild = args.preBuild or "";
        in
          if binsOnly
          then args // { preBuild = existingPreBuild + "\n" + binsOnlyPreBuild; }
          else args // synthLibTarget crate;

    # Path-source workspace members now use src = workspaceSrc (so
    # include_str! to sibling files works). libPath / build / crateBin
    # entries need a `<relative_path>/` prefix to compensate. Pure
    # string transform on the args attrset.
    prefixForMember = crate: args:
      if crate.source.kind != "path" then args
      else let rel = crate.source.relative_path or ""; in
        if rel == "" || rel == "." then args
        else let p = path: rel + "/" + path; in args
          // (if args ? libPath then { libPath = p args.libPath; } else {})
          // (if args ? build then { build = p args.build; } else {})
          // (if args ? crateBin && args.crateBin != []
              then { crateBin = map (b: b // { path = p b.path; }) args.crateBin; }
              else {});

    # Typed per-tree construction. Each tree iterates ITS OWN
    # platform-filtered spec (per I4) — `specTarget` for the workload
    # tree, `specHost` for the build-arch tree. `depFor`/`buildDepFor`
    # close over the appropriate target/host trees per I2 dispatch.
    # `buildRustCrate` is the per-tree builder (target vs. host pkgs).
    #
    # Multi-target spec support (schema v5+, #25): when the spec
    # carries `target_resolves[triple]`, dep edges come from that
    # target's section — eliminates the gen-bootstrap chicken-and-egg.
    # Fall back to per-crate `runtime_dependencies` / `build_dependencies`
    # for older specs (schema < 5).
    depsFor = treeSpec: triple: key: crate:
      let
        sectionCrates = (treeSpec.target_resolves or {}).${triple} or null;
        section = if sectionCrates != null then sectionCrates.crates.${key} or null else null;
      in
        if section != null
        then { runtime = section.runtime_dependencies; build = section.build_dependencies; }
        else { runtime = crate.runtime_dependencies; build = crate.build_dependencies; };

    mkBuiltTree = { treeSpec, triple, buildRustCrate, depFor, buildDepFor }:
      let
        # Multi-target spec (#25): iterate only crates ACTUALLY REACHABLE
        # for the current target — restricts `built` to the per-target
        # subset. Without this, apple-only crates (wgpu-core-deps-apple,
        # core-graphics-types, objc-sys) exist as keys in `built` for
        # linux trees because they live in the spec's universe
        # (`spec.crates`). Some dep paths transitively reach those keys
        # through the per-crate `runtime_dependencies` fallback for
        # crates missing from target_resolves — which builds apple-only
        # sources on linux and fails with E0455 "link kind framework
        # is only supported on Apple targets".
        #
        # Restricting iteration to target_resolves[triple].crates keys
        # closes the leak. Old specs (no target_resolves) fall back to
        # spec.crates — the legacy single-target behavior.
        targetCrates =
          let
            section = (treeSpec.target_resolves or {}).${triple} or null;
          in
            if section != null
            then builtins.intersectAttrs section.crates treeSpec.crates
            else treeSpec.crates;
      in
      lib.mapAttrs (key: crate: let
        deps = depsFor treeSpec triple key crate;
        # Per-target features (schema v5+): cargo's resolver computes
        # different features per target due to cfg-conditional feature
        # activations (e.g. macos_fsevent on apple-only). Without this,
        # substrate passed crate.features (the universe) to rustc on
        # every target, leaking apple features into linux builds.
        # Fall back to crate.features for old specs.
        featuresFor =
          let
            section = (treeSpec.target_resolves or {}).${triple} or null;
            sectionCrate = if section != null then section.crates.${key} or null else null;
          in
            if sectionCrate != null && sectionCrate ? features
            then sectionCrate.features
            else crate.features;
        baseArgs = (if crate ? build_rust_crate_args && crate.build_rust_crate_args != {}
                then crate.build_rust_crate_args
                else legacyArgs crate) // {
          src = (mkSrcOf hostPkgs) src crate;
          dependencies = map depFor deps.runtime;
          buildDependencies = map buildDepFor deps.build;
          features = featuresFor;
        } // binsFor key crate;
        # Apply lib_target synthesis BEFORE prefixForMember so the
        # synthesized libPath gets the same `<relative_path>/` glue as a
        # declared one. Self-heals stale specs (pre-09f6311 gen-cargo
        # emission) without requiring every consumer repo to regenerate.
        argsSynth = applySynthLibTarget crate baseArgs;
        argsPrefixed = prefixForMember crate argsSynth;
        # Mechanical dispatch from typed CrateQuirk variants (emitted by
        # gen-cargo into `crate.quirks`) to their class-helper apply
        # functions. Zero per-crate Nix-attrset knowledge — the registry
        # is in Rust at `gen-cargo/src/quirks.rs::REGISTRY`. Quirks
        # contribute additional override fields that merge on top of the
        # base args; the consumer's own override (overrideFor) wins on
        # collision.
        quirkAttrs = quirkApply.applyQuirks (crate.quirks or []) argsPrefixed;
        args = argsPrefixed // quirkAttrs;
        # Iterate `targetCrates` (per-target subset), NOT treeSpec.crates
        # (the multi-target universe). Restricts `built` to crates actually
        # reachable for this target — keeps apple-only drvs out of linux
        # trees and vice versa. See targetCrates definition above.
      in buildRustCrate (args // overrideFor triple crate.name args)) targetCrates;

    # Target tree: workload arch + target-filtered dep edges (I4).
    # Dispatch runtime deps via the typed `dep.tree` field gen-cargo
    # populates per the BuildTree enum (#12). Old specs (schema < 4)
    # don't carry `tree` — fall back to the proc_macro lookup for
    # backward compat. New specs (schema >= 4) bypass that and read
    # the typed field directly — the dispatch decision lives in Rust
    # at spec-emission time, not in Nix at evaluation time.
    built = mkBuiltTree {
      treeSpec = specTarget;
      triple = targetTriple;
      buildRustCrate = buildRustCrateTarget;
      depFor = d:
        let
          legacy = specTarget.crates.${d.package_key}.proc_macro or false;
          tree = d.tree or (if legacy then "host" else "target");
        in if tree == "host"
           then builtBuild.${d.package_key}
           else built.${d.package_key};
      buildDepFor = d: builtBuild.${d.package_key};
    };

    # Host tree: build/native arch + host-filtered dep edges (I4).
    # Transitively all-host.
    builtBuild = mkBuiltTree {
      treeSpec = specHost;
      triple = hostTriple;
      buildRustCrate = buildRustCrateHost;
      depFor = d: builtBuild.${d.package_key};
      buildDepFor = d: builtBuild.${d.package_key};
    };

    memberRecord = key: let c = spec.crates.${key}; in {
      name = c.name;
      value = { packageId = c.name; build = built.${key}; debug = built.${key}; };
    };
  in {
    rootCrate = { packageId = spec.crates.${spec.root_crate}.name; build = built.${spec.root_crate}; debug = built.${spec.root_crate}; };
    workspaceMembers = builtins.listToAttrs (map memberRecord spec.workspace_members);
    crates = spec.crates;
    allWorkspaceMembers = pkgs.symlinkJoin {
      name = "all-workspace-members";
      paths = map (k: built.${k}) spec.workspace_members;
    };
  };
in {
  inherit mkProject loadBuildSpec;
}
