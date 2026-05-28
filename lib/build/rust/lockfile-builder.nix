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
  srcOf = workspaceSrc: spec:
    if spec.source.kind == "registry" then
      pkgs.fetchurl {
        url = canonicalRegistryUrl spec.name spec.version spec.source.url;
        sha256 = spec.source.sha256;
        name = spec.source.name_with_ext;
      }
    else if spec.source.kind == "git" then
      let
        full = pkgs.fetchgit {
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
      if spec.source.relative_path == "." || spec.source.relative_path == ""
      then workspaceSrc
      else workspaceSrc + "/${spec.source.relative_path}";

  plemeCrateOverrides = import ./pleme-crate-overrides.nix;
  mkProject = {
    src,
    # Substrate guarantee: every fleet-wide buildRustCrate quirk in
    # plemeCrateOverrides applies by default. Callers can still pass an
    # explicit `defaultCrateOverrides` to extend — the merge order is
    # nixpkgs defaults → pleme overrides → caller overrides (later wins).
    defaultCrateOverrides ? (pkgs.defaultCrateOverrides // plemeCrateOverrides),
    buildRustCrateForPkgs ? (p: p.buildRustCrate),
    # Optional: substrate-bound gen package. When supplied, the
    # build-spec is derived on demand via IFD instead of read from
    # the committed `Cargo.build-spec.json`. Consumers stop
    # committing the JSON; bumping gen propagates fleet-wide.
    gen ? null,
  }: let
    specSrc =
      if gen != null
      then import ./mk-build-spec.nix { inherit pkgs gen src; }
      else src;
    spec = loadBuildSpec specSrc;
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
    _ = _specVersionAssert;
    buildRustCrate = buildRustCrateForPkgs pkgs;

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
        then (if bins != [] then { crateBin = bins; } else {})
        else { crateBin = []; };

    # Always layer plemeCrateOverrides in — even when the caller passed
    # their own `defaultCrateOverrides`. Consumers that import
    # lockfile-builder directly (escriba's flake.nix is the canonical
    # example) would otherwise silently drop every fleet-wide quirk we
    # ship (wgpu-hal cfg, openraft BTreeSet patch, document-features
    # lib_target, etc.). Compose per-crate: pleme rules apply first,
    # caller wins on key collision.
    overrideFor = name:
      let
        pleme  = plemeCrateOverrides.${name}  or null;
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

    # Lazy memoization: each thunk is computed once via mapAttrs.
    built = lib.mapAttrs (key: crate: let
      args = (if crate ? build_rust_crate_args && crate.build_rust_crate_args != {}
              then crate.build_rust_crate_args
              else legacyArgs crate) // {
        src = srcOf src crate;
        dependencies = map (d: built.${d.package_key}) crate.runtime_dependencies;
        buildDependencies = map (d: built.${d.package_key}) crate.build_dependencies;
      } // binsFor key crate;
    in buildRustCrate (args // overrideFor crate.name args)) spec.crates;

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
