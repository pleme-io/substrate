# Lockfile-native Rust builder. Reads Cargo.lock + Cargo.toml at eval
# time via builtins.fromTOML, builds a crate2nix-shaped project
# attrset (`{ rootCrate, workspaceMembers, allWorkspaceMembers }`)
# WITHOUT requiring a pre-generated Cargo.nix on disk.
#
# STATUS — M0 foundation: eval-time lockfile read works, fetchurl
# resolution works, workspaceMembers attrset shape correct, project.
# rootCrate.packageId returns the right name. Verified on
# caixa-sha2 (1 member, 13 crates in closure).
#
# REMAINING WORK — feature resolver. crate2nix's vendored `internal`
# block (~780 lines) handles `expandFeatures` + `enableFeatures` +
# `dependencyFeatures` to activate the right per-crate feature set
# at build time. Without that layer, compile-phase errors surface
# (E0432 unresolved imports) because optional deps aren't activated
# correctly. Port path:
#   - Translate the vendored `internal` helpers (gen-nix/assets/
#     crate2nix-internal-helpers.nix) to operate on lockfile-derived
#     `crates` data instead of crate2nix-generated `crates` data.
#   - Add per-crate `features` + `resolvedDefaultFeatures` fields
#     from a sidecar source (cargo metadata at lock time, or pre-
#     resolved feature manifest committed alongside Cargo.lock).
#   - Wire buildCrate to consult the resolver before calling
#     buildRustCrate.
# Until that work lands, this builder is the SCAFFOLD; consumers
# should keep using mkCrate2nixProject in production.
#
# This eliminates the `regenerate Cargo.nix` step entirely. The
# substrate flake reads the canonical Cargo.lock directly; updates
# propagate on the next `nix build` with zero operator action.
#
# Compat: returns the same shape crate2nix's generated Cargo.nix
# produces, so callers (mkCrate2nixProject / mkCrate2nixTool /
# mkCrate2nixDockerImage) can swap to this with no API change.
{ pkgs, lib ? pkgs.lib }:

let
  inherit (builtins) readFile fromTOML pathExists attrNames map elemAt length filter elem foldl';

  # ── Cargo.lock + workspace ingestion ────────────────────────────

  loadLockfile = src:
    let path = src + "/Cargo.lock";
    in if pathExists path
       then fromTOML (readFile path)
       else throw "lockfile-builder: ${toString src}/Cargo.lock not found";

  loadCargoToml = path:
    if pathExists path
    then fromTOML (readFile path)
    else throw "lockfile-builder: ${toString path} not found";

  # ── Workspace member discovery ─────────────────────────────────

  # Returns the list of workspace member directories (relative to src),
  # honoring `[workspace] members = [...]`. Globs (`crates/*`) are
  # expanded by listing the parent dir + filtering for Cargo.toml.
  workspaceMembersOf = src:
    let
      root = loadCargoToml (src + "/Cargo.toml");
      memberPatterns =
        if root ? workspace && root.workspace ? members
        then root.workspace.members
        else if root ? package then [ "." ]
        else [];
    in lib.concatMap (pat: expandMemberGlob src pat) memberPatterns;

  expandMemberGlob = src: pat:
    if pat == "." then [ "." ]
    else if lib.hasSuffix "/*" pat then
      let
        parent = lib.removeSuffix "/*" pat;
        parentDir = src + ("/" + parent);
      in
        if pathExists parentDir then
          lib.mapAttrsToList (n: _: parent + "/" + n) (
            lib.filterAttrs (n: t:
              t == "directory" && pathExists (parentDir + "/${n}/Cargo.toml")
            ) (builtins.readDir parentDir)
          )
        else []
    else if builtins.match ".*/\\*$" pat != null then [ pat ]
    else [ pat ];

  # ── Crate identity ─────────────────────────────────────────────

  # Cargo.lock dependency entries take three shapes:
  #   "name"                          — only one version present
  #   "name VERSION"                  — multiple versions disambiguated
  #   "name VERSION (SOURCE)"         — fully qualified
  # Returns { name = "..."; version = null|string; }
  parseDepRef = ref:
    let
      parts = lib.splitString " " ref;
      n = elemAt parts 0;
    in
      if length parts == 1 then { name = n; version = null; }
      else { name = n; version = elemAt parts 1; };

  # ── Source resolution ──────────────────────────────────────────

  # Build the per-crate src derivation. Registry crates → fetchurl
  # from crates.io with the lockfile-pinned sha256. Git crates →
  # fetchgit. Path / workspace crates → cleanSourceWith on the
  # workspace member directory.
  srcFor = workspaceSrc: pkg:
    let
      hasRegistry = pkg ? source && lib.hasPrefix "registry+" pkg.source;
      hasGit = pkg ? source && lib.hasPrefix "git+" pkg.source;
    in
      if hasRegistry then
        # crates.io tarball — content-addressed by checksum.
        # NOTE: `.crate` files are gzipped tarballs; nix's default
        # unpackPhase doesn't recognize the extension. Name the
        # fetched derivation `.tar.gz` so unpackPhase picks the
        # tarball unpacker.
        pkgs.fetchurl {
          url = "https://crates.io/api/v1/crates/${pkg.name}/${pkg.version}/download";
          sha256 = pkg.checksum;
          name = "${pkg.name}-${pkg.version}.tar.gz";
        }
      else if hasGit then
        pkgs.fetchgit {
          url = lib.head (lib.splitString "?" (lib.removePrefix "git+" pkg.source));
          rev = lib.last (lib.splitString "#" pkg.source);
          sha256 = pkg.checksum or lib.fakeSha256;
        }
      else
        # Workspace member — point at its directory under workspaceSrc.
        # crate2nix uses lib.cleanSourceWith with a filter; we do the
        # same to keep nix-store paths reproducible.
        workspaceSrc;

  # ── Crate attribute set assembly ───────────────────────────────

  # Build one entry of the `crates = { ... }` table. Mirrors the
  # crate2nix per-crate shape used by buildRustCrateWithFeatures.
  mkCrateEntry = workspaceSrc: workspaceMembersInfo: pkg:
    let
      memberInfo = lib.findFirst (m: m.name == pkg.name) null workspaceMembersInfo;
      isWorkspaceMember = memberInfo != null;
      memberToml = if isWorkspaceMember then memberInfo.toml else null;

      edition =
        if isWorkspaceMember && memberToml ? package && memberToml.package ? edition
        then (
          if builtins.isAttrs memberToml.package.edition
          then "2021"  # workspace inheritance — default to 2021 for now
          else memberToml.package.edition
        )
        else "2021";

      isProcMacro =
        isWorkspaceMember
        && memberToml ? lib
        && (memberToml.lib.proc-macro or false || memberToml.lib.proc_macro or false);

      depRefs = pkg.dependencies or [];
      depEntries = lib.map (ref:
        let p = parseDepRef ref; in {
          name = p.name;
          packageId = p.name;
        }
      ) depRefs;

      srcAttr =
        if isWorkspaceMember
        then { src = lib.cleanSourceWith {
                 src = workspaceSrc + "/${memberInfo.path}";
                 filter = path: type: !(lib.hasSuffix ".nix" path);
               }; }
        else { sha256 = pkg.checksum or null;
               src = srcFor workspaceSrc pkg; };
    in
      srcAttr // {
        crateName = pkg.name;
        version = pkg.version;
        inherit edition;
        dependencies = depEntries;
        # procMacro flag only meaningful for workspace members today;
        # registry deps' proc-macro-ness is encoded in their published
        # Cargo.toml which we don't read at eval time. crate2nix handles
        # this via its generator running cargo metadata; we trade that
        # off here. Operators can add per-crate overrides for any
        # mis-classified proc-macro via the crate-config.nix knob.
      } // lib.optionalAttrs isProcMacro { procMacro = true; };

  # ── Top-level entrypoint ───────────────────────────────────────

  mkProject = {
    src,
    name ? null,
    rootFeatures ? [ "default" ],
    defaultCrateOverrides ? pkgs.defaultCrateOverrides,
    buildRustCrateForPkgs ? (pkgs: pkgs.buildRustCrate),
  }: let
      lock = loadLockfile src;
      rootToml = loadCargoToml (src + "/Cargo.toml");
      memberPaths = workspaceMembersOf src;

      # For each workspace member path, load its Cargo.toml + record
      # the canonical name so we can look up the matching lock entry.
      workspaceMembersInfo = lib.map (p:
        let
          tomlPath = if p == "." then src + "/Cargo.toml" else src + "/${p}/Cargo.toml";
          t = loadCargoToml tomlPath;
          n = t.package.name or null;
        in {
          path = p;
          name = n;
          toml = t;
        }
      ) (filter (p: pathExists (if p == "." then src + "/Cargo.toml" else src + "/${p}/Cargo.toml")) memberPaths);

      # Build the crates attrset keyed by package name.
      crates = builtins.listToAttrs (lib.map (pkg: {
        name = pkg.name;
        value = mkCrateEntry src workspaceMembersInfo pkg;
      }) lock.package);

      # buildRustCrate caller — resolves dependencies into derivations.
      buildRustCrate = buildRustCrateForPkgs pkgs;

      # Memoized crate builds. Walk the dep graph; each crate name
      # resolves to one derivation.
      buildCrate = name:
        let
          crate = crates.${name} or (throw "lockfile-builder: package `${name}` not in Cargo.lock");
          depDrvs = lib.map (d: buildCrate d.packageId) (crate.dependencies or []);
          overrideFn = defaultCrateOverrides.${name} or (oldAttrs: oldAttrs);
          baseArgs = removeAttrs crate [ "dependencies" ] // {
            dependencies = depDrvs;
          };
        in buildRustCrate (baseArgs // (overrideFn baseArgs));

      # Workspace member entries — what crate2nix emits as
      # workspaceMembers.<name>.{packageId, build, debug}.
      workspaceMembers = builtins.listToAttrs (lib.map (m: {
        name = m.name;
        value = rec {
          packageId = m.name;
          build = buildCrate packageId;
          debug = buildCrate packageId;
        };
      }) (filter (m: m.name != null) workspaceMembersInfo));

      # rootCrate — first member by convention, or the workspace name
      # caller passed via `name` (matches crate2nix's `rootCrate` slot).
      rootName =
        if name != null then name
        else if length workspaceMembersInfo > 0
             then (elemAt workspaceMembersInfo 0).name
        else throw "lockfile-builder: no workspace members + no `name` arg";

      rootCrate = rec {
        packageId = rootName;
        build = buildCrate packageId;
        debug = buildCrate packageId;
      };

    in {
      inherit rootCrate workspaceMembers crates;
      allWorkspaceMembers = pkgs.symlinkJoin {
        name = "all-workspace-members";
        paths = lib.map (m: m.build) (builtins.attrValues workspaceMembers);
      };
    };

in {
  inherit mkProject;
  # Lower-level helpers exported for advanced use cases (overrides,
  # introspection, fleet sweeps).
  inherit loadLockfile workspaceMembersOf parseDepRef srcFor;
}
