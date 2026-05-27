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

  # Tagged-enum dispatch on source.kind. URLs are pre-cleaned by gen.
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
      if spec.source.relative_path == "." || spec.source.relative_path == ""
      then workspaceSrc
      else workspaceSrc + "/${spec.source.relative_path}";

  mkProject = {
    src,
    defaultCrateOverrides ? pkgs.defaultCrateOverrides,
    buildRustCrateForPkgs ? (p: p.buildRustCrate),
  }: let
    spec = loadBuildSpec src;
    buildRustCrate = buildRustCrateForPkgs pkgs;

    workspaceKeys = builtins.listToAttrs
      (map (k: { name = k; value = true; }) spec.workspace_members);
    isWorkspaceMember = key: workspaceKeys ? ${key};

    # Workspace members declare [[bin]]s explicitly; transitive deps
    # leave buildRustCrate's auto-detection in place (passing
    # `crateBin = []` would suppress library compilation for sys crates).
    binsFor = key: crate:
      let bins = map (b: { inherit (b) name path; }) (crate.binaries or []);
      in if isWorkspaceMember key && bins != [] then { crateBin = bins; } else {};

    extraFor = crate:
      (if crate.proc_macro then { procMacro = true; } else {})
      // (if crate.build_script != null then { build = crate.build_script; } else {});

    overrideFor = name: defaultCrateOverrides.${name} or (oldAttrs: oldAttrs);

    # Lazy memoization: each thunk is computed once via mapAttrs.
    built = lib.mapAttrs (key: crate: let
      args = {
        crateName = crate.name;
        version = crate.version;
        edition = crate.edition;
        src = srcOf src crate;
        features = crate.features;
        crateRenames = crate.crate_renames;
        dependencies = map (d: built.${d.package_key}) crate.runtime_dependencies;
        buildDependencies = map (d: built.${d.package_key}) crate.build_dependencies;
        release = true;
      } // binsFor key crate // extraFor crate;
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
