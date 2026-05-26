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
        url = spec.source.url;
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

      # Memoized per-crate-key build. Walks the dep graph; each
      # package_key resolves to one derivation. The dep-list / build-
      # dep-list / crateRenames fields come pre-shaped from the spec
      # — no Nix-side derivation, no synthesis.
      buildByKey = key:
        let
          crate = spec.crates.${key} or (throw ''
            lockfile-builder: crate key `${key}` not in Cargo.build-spec.json
          '');
          dependencies = map (d: buildByKey d.package_key) crate.runtime_dependencies;
          buildDependencies = map (d: buildByKey d.package_key) crate.build_dependencies;
          baseArgs = {
            crateName = crate.name;
            version = crate.version;
            edition = crate.edition;
            src = srcOf src crate;
            features = crate.features;
            crateRenames = crate.crate_renames;
            inherit dependencies buildDependencies;
            release = true;
          }
          // (if crate.proc_macro then { procMacro = true; } else {})
          // (if crate.build_script != null then { build = crate.build_script; } else {});
          overrideFn = defaultCrateOverrides.${crate.name} or (oldAttrs: oldAttrs);
        in buildRustCrate (baseArgs // overrideFn baseArgs);

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
