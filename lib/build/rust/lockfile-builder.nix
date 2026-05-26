# Lockfile-native Rust builder — pure-Nix orchestrator over the typed
# Cargo.build-spec.json that `gen lock-build` produces.
#
# The architectural split:
#   - Rust (gen-cargo) owns ALL semantic resolution: parses Cargo.toml,
#     Cargo.lock, runs cargo metadata, resolves features + per-edge
#     activations + renames + target predicates + sha256s, writes one
#     typed JSON.
#   - Nix (this file) owns DISPATCH: one fromJSON read, per-crate
#     buildRustCrate calls, dep-graph walk, crateRenames synthesis.
#     No parsing, no string splitting, no semantic decisions.
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
      lib.cleanSourceWith {
        src = if spec.source.relative_path == "." || spec.source.relative_path == ""
              then workspaceSrc
              else workspaceSrc + "/${spec.source.relative_path}";
        filter = path: type: !(lib.hasSuffix ".nix" path);
      };

  # ── crateRenames synthesis ─────────────────────────────────────
  #
  # nixpkgs's buildRustCrate consumes `crateRenames` as an attrset
  # mapping canonical-published-name → [{ version; rename; }, ...].
  # The local alias (`extern crate <name>`) lives in our spec's
  # CrateDepSpec.name; the canonical package key tells us the
  # published name + version.
  #
  # Example: rustix declares `errno = { package = "libc_errno", ... }`
  # — wait, actually the inverse: rustix declares
  # `libc_errno = { package = "errno", version = "0.3" }`.
  # Then Spec.name = "libc_errno" (local), Spec.package_key =
  # "errno-0.3.14" (canonical). The rename is "libc_errno"; the
  # crateRenames entry needs to be keyed by canonical "errno" with
  # the rename "libc_errno".
  crateRenamesFor = spec: depEntries:
    let
      depWithRename = filter (d:
        let canonical = (spec.crates.${d.package_key}).name;
        in d.name != canonical
      ) depEntries;
      grouped = lib.groupBy (d: (spec.crates.${d.package_key}).name) depWithRename;
    in
      lib.mapAttrs (canonical: deps:
        map (d: {
          version = (spec.crates.${d.package_key}).version;
          rename = d.name;
        }) deps
      ) grouped;

  # ── Dep filtering ──────────────────────────────────────────────
  #
  # Spec.dependencies includes normal + build deps. Filter into the
  # two buckets buildRustCrate expects.
  isNormal = d: (d.kind or "normal") == "normal";
  isBuild = d: (d.kind or "normal") == "build";

  # cfg() expressions are RESOLVED BY RUST. gen lock-build calls
  # `cargo metadata --filter-platform=<host>` so the spec's
  # dependencies list ONLY contains deps active for the target.
  # Nix never evaluates cfg() — that's the correct line between Rust
  # (semantic decisions) and Nix (dispatch).
  #
  # The `target` field is still emitted on dep entries for diagnostics
  # and cross-target re-rendering (gen lock-build --target ...), but
  # the Nix side trusts the resolver and includes every dep present.

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
      # package_key resolves to one derivation.
      buildByKey = key:
        let
          crate = spec.crates.${key} or (throw ''
            lockfile-builder: crate key `${key}` not in Cargo.build-spec.json
          '');

          # The Rust side already filtered to host-active deps.
          normalDeps = filter isNormal crate.dependencies;
          buildDeps = filter isBuild crate.dependencies;

          dependencies = map (d: buildByKey d.package_key) normalDeps;
          buildDependencies = map (d: buildByKey d.package_key) buildDeps;
          crateRenames = crateRenamesFor spec (normalDeps ++ buildDeps);

          baseArgs = {
            crateName = crate.name;
            version = crate.version;
            edition = crate.edition;
            src = srcOf src crate;
            features = crate.features;
            inherit dependencies buildDependencies crateRenames;
            release = true;
          } // (if crate.proc_macro then { procMacro = true; } else {});

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
  inherit mkProject loadBuildSpec crateRenamesFor;
}
