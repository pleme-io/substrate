# Lockfile-native Rust builder — pure-Nix orchestrator over the typed
# Cargo.build-spec.json that `gen lock-build` produces.
#
# ARCHITECTURAL CONTRACT — deeply and consistently algorithmic:
#
#   Rust (gen-cargo) owns ALL semantics — parsing, cargo metadata,
#   feature resolution, target/cfg evaluation (via cargo's
#   --filter-platform), rename synthesis, source URL + sha256
#   resolution, dep-split into runtime/build buckets. The Cargo.build-
#   spec.json schema delivers EVERY field substrate's buildRustCrate
#   call needs in its final shape — no Nix-side derivation.
#
#   Nix (this file) is PURE DISPATCH — one fromJSON read, per-crate
#   buildRustCrate call, memoized dep-graph walk, attrset assembly.
#   Zero parsing, zero filtering, zero shape transformation, zero
#   semantic decisions. New format quirks land in the Rust side; this
#   file is invariant.
#
# Returns the same project-attrset shape crate2nix produces
# (`{ rootCrate, workspaceMembers, allWorkspaceMembers, crates }`).
# Operators run `gen lock-build` (or `gen build`) whenever Cargo.lock
# changes; the JSON sidecar is committed alongside Cargo.lock.
{ pkgs, lib ? pkgs.lib }:

let
  inherit (builtins) readFile fromJSON pathExists map elemAt;

  # ── Spec loading ────────────────────────────────────────────────

  loadBuildSpec = src:
    let path = src + "/Cargo.build-spec.json";
    in if pathExists path
       then fromJSON (readFile path)
       else throw ''
         lockfile-builder: ${toString src}/Cargo.build-spec.json not found.
         Run `gen build .` in the workspace root to produce it.
       '';

  # ── Source resolution (one-line dispatch per kind) ─────────────

  srcOf = workspaceSrc: spec:
    if spec.source.kind == "registry" then
      pkgs.fetchurl {
        url = spec.source.url;
        sha256 = spec.source.sha256;
        name = spec.source.name_with_ext;
      }
    else if spec.source.kind == "git" then
      pkgs.fetchgit {
        # Strip cargo's `?branch=...` / `?tag=...` / `?rev=...` suffix
        # — fetchgit treats URL literally; the `?` form isn't valid git.
        url = lib.head (lib.splitString "?" spec.source.url);
        rev = spec.source.rev;
        sha256 = spec.source.sha256 or lib.fakeSha256;
      }
    else
      lib.cleanSourceWith {
        src = if spec.source.relative_path == "." || spec.source.relative_path == ""
              then workspaceSrc
              else workspaceSrc + "/${spec.source.relative_path}";
        filter = path: type: !(lib.hasSuffix ".nix" path);
      };

  # ── Top-level entrypoint ───────────────────────────────────────

  mkProject = {
    src,
    name ? null,
    defaultCrateOverrides ? pkgs.defaultCrateOverrides,
    buildRustCrateForPkgs ? (p: p.buildRustCrate),
  }: let
      spec = loadBuildSpec src;
      buildRustCrate = buildRustCrateForPkgs pkgs;

      # Workspace members get their declared bins; transitive deps
      # get crateBin=[] to suppress auto-discovery of broken
      # example/test bins under src/bin/ (e.g. alloc-no-stdlib's
      # heap_alloc.rs which uses #![no_std] + no main).
      memberKeys = builtins.listToAttrs
        (map (k: { name = k; value = true; }) spec.workspace_members);
      isWorkspaceMember = key: memberKeys ? ${key};

      # MEMOIZED per-crate-key build via attrset materialization.
      #
      # PRIOR BUG: `buildByKey = key: let ... in buildRustCrate ...;`
      # is a function — each invocation re-evaluates. With high dep
      # re-use (serde depended on by 50 crates → buildByKey "serde"
      # computed 50 times → each of those triggers serde's own deps
      # recursively → exponential).
      #
      # FIX: build an attrset once via mapAttrs over spec.crates. Each
      # value is a thunk computed lazily ONCE; subsequent reads hit
      # the cached value. O(N) eval cost across the entire graph.
      built = lib.mapAttrs (key: crate: let
          deps = map (d: built.${d.package_key}) crate.runtime_dependencies;
          buildDeps = map (d: built.${d.package_key}) crate.build_dependencies;
          binList =
            if isWorkspaceMember key
            then map (b: { name = b.name; path = b.path; }) (crate.binaries or [])
            else [];
          baseArgs = {
            crateName = crate.name;
            version = crate.version;
            edition = crate.edition;
            src = srcOf src crate;
            features = crate.features;
            crateRenames = crate.crate_renames;
            dependencies = deps;
            buildDependencies = buildDeps;
            crateBin = binList;
            release = true;
          }
          // (if crate.proc_macro then { procMacro = true; } else {})
          // (if crate.build_script != null then { build = crate.build_script; } else {});
          overrideFn = defaultCrateOverrides.${crate.name} or (oldAttrs: oldAttrs);
        in buildRustCrate (baseArgs // overrideFn baseArgs)
      ) spec.crates;

      buildByKey = key: built.${key} or (throw ''
        lockfile-builder: crate key `${key}` not in Cargo.build-spec.json
      '');

      workspaceMembers = builtins.listToAttrs (map (key:
        let c = spec.crates.${key}; in {
          name = c.name;
          value = {
            packageId = c.name;
            build = buildByKey key;
            debug = buildByKey key;
          };
        }
      ) spec.workspace_members);

      rootKey = spec.root_crate or (elemAt spec.workspace_members 0);
      rootName = (spec.crates.${rootKey}).name;
      rootCrate = {
        packageId = rootName;
        build = buildByKey rootKey;
        debug = buildByKey rootKey;
      };
    in {
      inherit rootCrate workspaceMembers;
      crates = spec.crates;
      allWorkspaceMembers = pkgs.symlinkJoin {
        name = "all-workspace-members";
        paths = map (m: m.build) (builtins.attrValues workspaceMembers);
      };
    };

in {
  inherit mkProject loadBuildSpec;
}
