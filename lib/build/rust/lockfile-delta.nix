# lockfile-delta.nix — reconstruct a BuildSpec-shaped attrset from the slim
# `Cargo.gen.lock` delta + the lock-owned half derived in PURE NIX from
# `Cargo.lock`/`Cargo.toml` via `builtins.fromTOML`.
#
# Consumer half of gen's CARGO-LOCK-DELTA-CONTRACT (D1–D4)
# (`gen/docs/CARGO-LOCK-DELTA-CONTRACT.md`). It DELIBERATELY introduces
# `fromTOML` to the substrate Rust builder — the older lockfile-builder
# header ("no fromTOML") describes the full-build-spec path; the delta path
# trades a 3.4× smaller committed artifact for this reconstruction, IFD-free
# and cache-shared exactly like the full path.
#
# Output shape == `Cargo.build-spec.json` (fed where `committedSpec` is fed,
# so the whole downstream ladder is unchanged). Dep edges + features live in
# `target_resolves` (verbatim from the delta); per-crate dep/rename fields
# are `skip_serializing` in v9+ and read empty, so they're omitted here.
{ lib }:
let
  inherit (builtins)
    fromJSON fromTOML readFile pathExists hashFile listToAttrs map elemAt head
    match filter seq readDir;

  stripQuery = url:
    let m = match "([^?]+)\\?.*" url;
    in if m == null then url else head m;

  # Cargo.lock `source` string → the builder's tagged source shape.
  mkSource = nameToPath: name: version: gitNar: pkg:
    let
      source = pkg.source or null;
      key = "${name}-${version}";
    in
    if source == null then
      { kind = "path"; relative_path = nameToPath.${name} or "."; }
    else if lib.hasPrefix "registry+" source then
      {
        kind = "registry";
        url = "https://static.crates.io/crates/${name}/${name}-${version}.crate";
        sha256 = pkg.checksum or "";
        name_with_ext = "${name}-${version}.tar.gz";
      }
    else if lib.hasPrefix "git+" source then
      let
        after = lib.removePrefix "git+" source;
        parts = lib.splitString "#" after;
      in
      {
        kind = "git";
        url = stripQuery (elemAt parts 0);
        rev = elemAt parts 1;
        sha256 = gitNar.${key} or null;
      }
    else
      throw "lockfile-delta: unrecognized Cargo.lock source `${source}` for ${name}";

  # Expand a `[workspace].members` entry to concrete relative paths
  # (handles the `crates/*` glob convention + explicit paths).
  expandMember = src: m:
    if lib.hasSuffix "/*" m then
      let
        base = lib.removeSuffix "/*" m;
        baseDir = src + "/${base}";
      in
      if pathExists baseDir then
        lib.mapAttrsToList (n: _: "${base}/${n}")
          (lib.filterAttrs
            (n: t: t == "directory" && pathExists (baseDir + "/${n}/Cargo.toml"))
            (readDir baseDir))
      else [ ]
    else [ m ];

  reconstruct = src:
    let
      genLockPath = src + "/Cargo.gen.lock";
      cargoLockPath = src + "/Cargo.lock";
      cargoTomlPath = src + "/Cargo.toml";
    in
    if !(pathExists genLockPath && pathExists cargoLockPath && pathExists cargoTomlPath)
    then null
    else
      let
        delta = fromJSON (readFile genLockPath);
        lock = fromTOML (readFile cargoLockPath);
        toml = fromTOML (readFile cargoTomlPath);
        perCrate = delta.per_crate or { };
        gitNar = delta.git_nar_sha256 or { };
        pkgs = lock.package or [ ];

        # ── D2 freshness gate — hard eval throw on stale delta ──────────
        lockSha = hashFile "sha256" cargoLockPath;
        d2ok =
          if delta.cargo_lock_sha256 == lockSha then true
          else throw ''
            lockfile-delta: Cargo.gen.lock is STALE (D2 freshness tie failed).
              committed cargo_lock_sha256 = ${delta.cargo_lock_sha256}
              hashFile "sha256" Cargo.lock = ${lockSha}
            Re-run `gen build` to regenerate Cargo.gen.lock from the current lock.
          '';

        # ── Workspace members: declaration-order paths → name/version ──
        wsMembers = (toml.workspace or { }).members or [ ];
        # Single-crate repos have a `[package]` but no `[workspace].members`:
        # the sole package at "." IS both the root crate and the only member.
        memberPaths =
          if wsMembers == [ ] then [ "." ]
          else lib.concatMap (expandMember src) wsMembers;
        memberTomlPath = p: if p == "." then src + "/Cargo.toml" else src + "/${p}/Cargo.toml";
        memberInfo = map
          (p: { path = p; name = (fromTOML (readFile (memberTomlPath p))).package.name; })
          memberPaths;
        nameToPath = listToAttrs (map (mi: { inherit (mi) name; value = mi.path; }) memberInfo);
        # name → version from the no-source (path) lock packages.
        nameToVer = listToAttrs
          (map (p: { inherit (p) name; value = p.version; })
            (filter (p: !(p ? source)) pkgs));

        lockByKey = listToAttrs
          (map (p: { name = "${p.name}-${p.version}"; value = p; }) pkgs);

        # Declaration-order workspace member keys; root = first (gen convention).
        workspace_members =
          map (mi: "${mi.name}-${nameToVer.${mi.name} or "0.0.0"}") memberInfo;
        root_crate = if workspace_members == [ ] then null else head workspace_members;

        # The crate SET = the RESOLVED-GRAPH nodes, NOT every lock package.
        # Cargo.lock lists dev-deps + platform-unreachable crates (windows-*,
        # wasm-*, …) that the build-spec excludes. Derive the set from
        # target_resolves: edge OWNERS (base + per-target override keys) ∪
        # edge TARGETS (every runtime/build edge `package_key`) ∪ members.
        tr = delta.target_resolves or { };
        edgeMaps = [ (tr.base or { }) ]
          ++ lib.mapAttrsToList (_: t: t.overrides or { }) (tr.targets or { });
        edgeOwnerKeys = lib.concatMap builtins.attrNames edgeMaps;
        edgePackageKeys = lib.concatMap
          (m: lib.concatMap
            (ce: map (e: e.package_key)
              ((ce.runtime_dependencies or [ ]) ++ (ce.build_dependencies or [ ])))
            (builtins.attrValues m))
          edgeMaps;
        resolvedKeys = lib.unique (edgeOwnerKeys ++ edgePackageKeys ++ workspace_members);

        # Every reconstructed crate must carry the FULL per-crate shape the
        # lockfile-builder reads — the delta is slim (per_crate stores only
        # non-default scalars; crates with all-default scalars are absent),
        # so we layer the stored scalars over complete defaults. The builder
        # forces `proc_macro`/`build_script` as conditions (legacyArgs) and
        # reads `features`/`crate_renames`; for v10 the real per-target
        # features come from `target_resolves`, so the per-crate `features`
        # here is just the old-spec fallback default. (Field-subset
        # equivalence oracle missed this; the system-build canary caught it.)
        crateDefaults = {
          edition = "2021";
          proc_macro = false;
          build_script = null;
          links = null;
          lib_target = null;
          binaries = [ ];
          features = [ ];
          crate_renames = { };
          quirks = [ ];
        };
        mkCrate = pkg:
          let
            key = "${pkg.name}-${pkg.version}";
            scalars = perCrate.${key} or { };
          in
          crateDefaults // scalars // {
            inherit (pkg) name version;
            source = mkSource nameToPath pkg.name pkg.version gitNar pkg;
          };
        crates = listToAttrs (map
          (k: { name = k; value = mkCrate lockByKey.${k}; })
          (builtins.filter (k: builtins.hasAttr k lockByKey) resolvedKeys));
      in
      seq d2ok {
        version = 10;
        workspace = { root = toString src; members = [ ]; };
        inherit crates root_crate workspace_members;
        flake_metadata = delta.flake_metadata or { };
        target_resolves = delta.target_resolves;
        cargo_lock_sha256 = delta.cargo_lock_sha256;
      };
in
{
  inherit reconstruct mkSource expandMember;
}
