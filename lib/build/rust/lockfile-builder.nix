# Lockfile-native Rust builder — pure-Nix orchestrator over the typed
# Cargo.build-spec.json that `gen lock-build` produces.
#
# The architectural split:
#   - Rust (gen-cargo) owns ALL semantic resolution: parses Cargo.toml,
#     Cargo.lock, runs cargo metadata, resolves features + per-edge
#     activations + renames + target predicates + sha256s, writes one
#     typed JSON.
#   - Nix (this file) owns DISPATCH: one fromJSON read, per-crate
#     buildRustCrate calls, attrset assembly. No parsing, no string
#     splitting, no semantic decisions.
#
# Returns the same project-attrset shape crate2nix produces
# (`{ rootCrate, workspaceMembers, allWorkspaceMembers, crates }`),
# so callers in crate2nix-builders.nix swap with no API change.
#
# Operators run `gen lock-build` whenever Cargo.lock changes — same
# trigger as crate2nix's regenerate step, but the output is JSON
# instead of executable Nix, and gen does the synthesis in typed Rust.
{ pkgs, lib ? pkgs.lib }:

let
  inherit (builtins) readFile fromJSON pathExists map elemAt length filter;

  # ── Spec loading ────────────────────────────────────────────────

  loadBuildSpec = src:
    let path = src + "/Cargo.build-spec.json";
    in if pathExists path
       then fromJSON (readFile path)
       else throw ''
         lockfile-builder: ${toString src}/Cargo.build-spec.json not found.
         Run `gen lock-build .` in the workspace root to produce it.
       '';

  # ── Source resolution per-crate ────────────────────────────────

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
      # Path source — workspace member or local path. relative_path
      # is relative to the workspace root.
      lib.cleanSourceWith {
        src = if spec.source.relative_path == "." || spec.source.relative_path == ""
              then workspaceSrc
              else workspaceSrc + "/${spec.source.relative_path}";
        filter = path: type: !(lib.hasSuffix ".nix" path);
      };

  # ── buildRustCrate entry assembly ──────────────────────────────

  mkBuildArgs = workspaceSrc: spec:
    {
      crateName = spec.name;
      version = spec.version;
      edition = spec.edition;
      src = srcOf workspaceSrc spec;
      features = spec.features;
    } // (if spec.proc_macro then { procMacro = true; } else {});

  # ── Top-level entrypoint ───────────────────────────────────────

  mkProject = {
    src,
    name ? null,                              # ignored — root_crate carries it
    defaultCrateOverrides ? pkgs.defaultCrateOverrides,
    buildRustCrateForPkgs ? (pkgs: pkgs.buildRustCrate),
  }: let
      spec = loadBuildSpec src;
      buildRustCrate = buildRustCrateForPkgs pkgs;

      # Memoized per-crate-key build. The dep graph is walked via
      # package_key, which uniquely identifies a resolved crate.
      buildByKey = key:
        let
          crate = spec.crates.${key} or (throw ''
            lockfile-builder: crate key `${key}` not in Cargo.build-spec.json
          '');
          depDrvs = lib.map (d: buildByKey d.package_key) crate.dependencies;
          baseArgs = mkBuildArgs src crate // { dependencies = depDrvs; };
          overrideFn = defaultCrateOverrides.${crate.name} or (oldAttrs: oldAttrs);
        in buildRustCrate (baseArgs // overrideFn baseArgs);

      # Workspace members exposed as { <pkg-name>.{ packageId, build, debug } }
      workspaceMembers = builtins.listToAttrs (lib.map (key:
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
        paths = lib.map (m: m.build) (builtins.attrValues workspaceMembers);
      };
    };

in {
  inherit mkProject loadBuildSpec;
}
