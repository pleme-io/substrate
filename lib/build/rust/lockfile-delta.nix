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

  # The one compare-and-throw shape, shared with build/go/lockfile-delta.nix
  # and build/rust/cargo-nix-tie.nix.
  tie = import ../shared/freshness-tie.nix { };

  # ── ★ THE READER REFUSES TO GUESS ──────────────────────────────────────
  #
  # `tie.held` answers "is this delta still describing its Cargo.lock?" It is
  # structurally blind to "is this delta the SHAPE this reader expects?" — and
  # this file used to answer the second question with bare `or` defaults, which
  # is a green verdict over a reconstruction that dropped everything.
  #
  # Concretely, before this: `delta.per_crate or { }` meant a delta that had
  # lost its payload reconstructed to a crate set built entirely from
  # `crateDefaults`, behind a GREEN D2 tie, with no throw and no warning. That
  # exact failure was MEASURED on the Go reader (see ../shared/freshness-tie.nix
  # §schemaViolation) and Go was hardened for it; this reader kept the
  # permissive shape while carrying 425 live consumers to Go's zero.
  #
  # The validator is shared (../shared/delta-contract.nix); only this table is
  # Rust-specific.
  contract = import ../shared/delta-contract.nix { inherit lib; } {
    subject = "lockfile-delta(rust)";
    artifact = "Cargo.gen.lock";
    adapter = "gen-cargo (pleme-io/gen)";
    schemaPath = "lockfile-delta.nix";
    regenCommand = "cd <that workspace> && gen build && git commit Cargo.gen.lock";
  };

  # ── The field table ────────────────────────────────────────────────────
  #
  # `required` is MEASURED, not chosen: every key below marked required was
  # present in 433 of 433 committed `Cargo.gen.lock` files in the fleet on
  # 2026-08-17, so hardening them breaks no repo. `manifest_sha256` was
  # present in 191 of 433, so it carries an explicit documented default
  # instead — that is the difference between a real optional field and a
  # "default it and hope".
  topLevel = {
    # KNOWN-BUT-UNUSED, declared so `closed` does not reject the producer's
    # real output for the wrong reason. Do NOT confuse it with the `version =
    # 10` this file emits: that is the BuildSpec version, a different number.
    #
    # TWO versions are live in the fleet, measured 2026-08-17 over 425 deltas:
    # v1 in 234, v2 in 191, and the split is PERFECTLY correlated with
    # `manifest_sha256` (v2 - v1 = exactly that one key; v1 - v2 = empty). So
    # `manifest_sha256` below is not vaguely optional -- it is required AT v2
    # and absent AT v1, and this field is what says which.
    schema_version    = { required = false; default = 1; note = "delta format version; 1 and 2 are both live (234 and 191 deltas)"; };
    cargo_lock_sha256 = { required = true;  note = "the D2 tie subject — without it there is no freshness check at all"; };
    per_crate         = { required = true;  note = "the payload: absent means every crate silently falls back to defaults"; };
    target_resolves   = { required = true;  note = "the resolved graph; the crate SET is derived from it, so absent means an empty build"; };
    git_nar_sha256    = { required = true;  note = "git source hashes; absent means every git dep loses its pinned NAR"; };
    flake_metadata    = { required = true;  note = "consumed verbatim by lockfile-builder"; };
    # Optional because it is VERSION-CONDITIONAL, not because its absence is
    # tolerable: absent is correct at schema_version 1 and would be a producer
    # bug at 2. Not enforced conditionally because this reader never consumes
    # the value, and a table that asserts more than the code consumes is the
    # same overclaim this contract exists to stop. The knowledge lives here so
    # whoever starts consuming it knows to gate on schema_version first.
    manifest_sha256   = { required = false; default = null; note = "KNOWN-BUT-UNUSED here; present iff schema_version >= 2 (191 of 425)"; };
  };

  stripQuery = url:
    let m = match "([^?]+)\\?.*" url;
    in if m == null then url else head m;

  # Cargo.lock `source` string → the builder's tagged source shape.
  mkSource = nameToPath: name: version: gitNar: pkg:
    let
      source = pkg.source or null;
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
        rev = elemAt parts 1;
        # Look up git_nar by the `name-version-rev` key first (post-migration
        # deltas; disambiguates two revs of one version) then fall back to the
        # legacy `name-version` key (pre-migration deltas). TOOLCHAIN-FRESHNESS
        # §X.4b.b.
        revKey = "${name}-${version}-${rev}";
        legacyKey = "${name}-${version}";
      in
      {
        kind = "git";
        url = stripQuery (elemAt parts 0);
        inherit rev;
        sha256 = gitNar.${revKey} or gitNar.${legacyKey} or null;
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
        where = tie.hint src;
        # Every top-level read goes through the table; a bare `or` here is
        # the defect this contract exists to prevent.
        closedTop = contract.closed topLevel delta where "Cargo.gen.lock top level";
        perCrate = contract.field topLevel delta where "per_crate";
        gitNar = contract.field topLevel delta where "git_nar_sha256";
        pkgs = lock.package or [ ];

        # ── D2 freshness gate — hard eval throw on stale delta ──────────
        #
        # The compare-and-throw now lives in ../shared/freshness-tie.nix,
        # shared with the Go delta and with the crate2nix Cargo.nix tie.
        # It was written here first, copied to Go, and the two wordings had
        # already begun to drift; three uses is the extraction.
        lockSha = hashFile "sha256" cargoLockPath;
        d2ok = tie.held {
          subject = "lockfile-delta (D2)";
          artifact = "Cargo.gen.lock";
          # NAME THE REPO. This message used to carry two hashes and nothing
          # else, which is a genuinely bad failure to receive: the throw
          # surfaces deep inside an unrelated consumer's module trace (a
          # stale `mado` took out `nix run .#rebuild` on cid via
          # nix-darwin -> assertions -> home-manager.sharedModules), so the
          # operator saw a nixpkgs stack and two opaque hashes with no
          # indication of WHICH of ~600 workspaces was at fault. Measured
          # 2026-08-01: identifying it required hashing every Cargo.lock in
          # the org — a five-minute scan to recover information the throw
          # site already held in `src`.
          where = tie.hint src;
          fresh = delta.cargo_lock_sha256 == lockSha;
          sides = [
            ''committed cargo_lock_sha256  = ${delta.cargo_lock_sha256}''
            ''hashFile "sha256" Cargo.lock = ${lockSha}''
          ];
          cause = ''
            Cargo.lock moved without a matching `gen build`, so the committed
            delta no longer describes it. This is a HARD EVAL FAILURE for every
            consumer of this workspace, not a warning.'';
          fix = "cd <that workspace> && gen build && git commit Cargo.gen.lock";
          fleetFix = "gen fleet-check ~/code/github/pleme-io";
        };

        # ── Workspace members: declaration-order paths → name/version ──
        #
        # cargo's `workspace_members` semantics (which gen's full-spec path
        # reads verbatim from `cargo metadata`) INCLUDE the workspace-root
        # package whenever a `[package]` table is co-located with the
        # `[workspace]` table — even when `"."` is NOT listed in
        # `[workspace].members`. sui is the canonical case: a workspace-root
        # crate `sui` plus a `members = [ "sui-eval", ... ]` array that lists
        # only the sub-crates. Reconstructing members from ONLY the explicit
        # `members` array drops that root package -> `packageName = "sui"`
        # can't be resolved by tool-release. Mirror cargo/gen here: prepend
        # `"."` when a root `[package]` exists and isn't already a member.
        hasRootPackage = toml ? package;
        wsMembers = (toml.workspace or { }).members or [ ];
        explicitMemberPaths =
          if wsMembers == [ ] then [ "." ]
          else lib.concatMap (expandMember src) wsMembers;
        # A root `[package]` is member "." (cargo convention). Only add it
        # when the explicit list didn't already claim the root (avoids a dup
        # if a member spells its path as "." or "").
        rootAlreadyMember =
          builtins.elem "." explicitMemberPaths || builtins.elem "" explicitMemberPaths;
        memberPaths =
          if hasRootPackage && !rootAlreadyMember
          then [ "." ] ++ explicitMemberPaths
          else explicitMemberPaths;
        memberTomlPath = p: if p == "." then src + "/Cargo.toml" else src + "/${p}/Cargo.toml";
        memberInfo = map
          (p: { path = p; name = (fromTOML (readFile (memberTomlPath p))).package.name; })
          memberPaths;
        nameToPath = listToAttrs (map (mi: { inherit (mi) name; value = mi.path; }) memberInfo);
        # name → version from the no-source (path) lock packages.
        nameToVer = listToAttrs
          (map (p: { inherit (p) name; value = p.version; })
            (filter (p: !(p ? source)) pkgs));

        # Git packages are indexed under BOTH the rev-key (`name-version-rev`,
        # the post-migration key that disambiguates two revs of one version —
        # TOOLCHAIN-FRESHNESS §X.4b.b) AND the legacy `name-version` key (for
        # deltas generated before the migration). Non-git: `name-version` only.
        # `resolvedKeys` (derived from the delta's edge package_keys) then
        # resolves under whichever convention the committed delta used.
        gitRevOf = p:
          let source = p.source or null;
          in
          if source != null && lib.hasPrefix "git+" source then
            let parts = lib.splitString "#" (lib.removePrefix "git+" source);
            in if builtins.length parts > 1 then elemAt parts 1 else null
          else null;
        lockByKey = listToAttrs (lib.concatMap
          (p:
            let
              base = "${p.name}-${p.version}";
              rev = gitRevOf p;
            in
            if rev != null
            then [ { name = "${base}-${rev}"; value = p; } { name = base; value = p; } ]
            else [ { name = base; value = p; } ])
          pkgs);

        # Declaration-order workspace member keys; root = first (gen convention).
        workspace_members =
          map (mi: "${mi.name}-${nameToVer.${mi.name} or "0.0.0"}") memberInfo;
        root_crate = if workspace_members == [ ] then null else head workspace_members;

        # The crate SET = the RESOLVED-GRAPH nodes, NOT every lock package.
        # Cargo.lock lists dev-deps + platform-unreachable crates (windows-*,
        # wasm-*, …) that the build-spec excludes. Derive the set from
        # target_resolves: edge OWNERS (base + per-target override keys) ∪
        # edge TARGETS (every runtime/build edge `package_key`) ∪ members.
        tr = contract.field topLevel delta where "target_resolves";
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
        # `k` is the resolved key in the delta's own convention
        # (`name-version-rev` for git in post-migration deltas, `name-version`
        # otherwise). Use it for the per_crate lookup so it matches the delta's
        # keying exactly — TOOLCHAIN-FRESHNESS §X.4b.b.
        mkCrate = k: pkg:
          crateDefaults // (perCrate.${k} or { }) // {
            inherit (pkg) name version;
            source = mkSource nameToPath pkg.name pkg.version gitNar pkg;
          };
        crates = listToAttrs (map
          (k: { name = k; value = mkCrate k lockByKey.${k}; })
          (builtins.filter (k: builtins.hasAttr k lockByKey) resolvedKeys));
      in
      seq d2ok (seq closedTop {
        version = 10;
        workspace = { root = toString src; members = [ ]; };
        inherit crates root_crate workspace_members;
        flake_metadata = contract.field topLevel delta where "flake_metadata";
        target_resolves = delta.target_resolves;
        cargo_lock_sha256 = contract.field topLevel delta where "cargo_lock_sha256";
      });
in
{
  inherit reconstruct mkSource expandMember;
}
