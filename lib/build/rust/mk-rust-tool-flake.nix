# mkRustToolFlake — zero-argument consumer flake for a Rust binary.
#
# Derives `toolName`, `packageName`, and `repo` from the source's
# Cargo.toml. The whole consumer flake collapses to:
#
#   {
#     inputs.substrate.url = "github:pleme-io/substrate";
#     inputs.nixpkgs.follows = "substrate/nixpkgs";
#     inputs.flake-utils.follows = "substrate/flake-utils";
#     inputs.crate2nix.follows = "substrate/crate2nix";
#     outputs = i: i.substrate.lib.mkRustToolFlake { src = i.self; inputs = i; };
#   }
#
# When the top-level Cargo.toml is a workspace, pass `packageName` to pick
# the member; the bin name comes from that member's [[bin]] (or
# [package].name fallback).
#
# Per-consumer overrides (crateOverrides, buildInputs, nativeBuildInputs)
# pass through verbatim to rust-tool-release-flake.
{
  inputs,                # the consumer flake's inputs attrset (needs nixpkgs / crate2nix / flake-utils / substrate)
  src,
  packageName ? null,    # nullable; if the workspace has one bin we infer it
  toolName ? null,       # override autodetected bin name
  repo ? null,           # override autodetected repository
  systems ? null,
  module ? null,
  crateOverrides ? {},
  buildInputs ? [],
  nativeBuildInputs ? [],
  buildMode ? "auto",
  ...
} @ args:
let
  inherit (builtins) fromTOML readFile pathExists head;

  rootToml = fromTOML (readFile (src + "/Cargo.toml"));

  # Resolve workspace + package toml. Workspace consumers expose `[workspace]`;
  # single-crate consumers expose `[package]` directly.
  isWorkspace = rootToml ? workspace;

  # Pick member toml when a workspace + a packageName were given.
  memberToml =
    if isWorkspace && packageName != null
    then
      let
        candidatePaths = map (m: src + "/${m}/Cargo.toml") (rootToml.workspace.members or []);
        match = builtins.filter (p:
          pathExists p && (fromTOML (readFile p)).package.name == packageName
        ) candidatePaths;
      in if match == []
         then throw "mkRustToolFlake: packageName `${packageName}` not in workspace members."
         else fromTOML (readFile (head match))
    else rootToml;

  rawPackageBlock = memberToml.package or (throw ''
    mkRustToolFlake: ${toString src}/Cargo.toml has no [package]. If this is
    a workspace, pass `packageName = "<member>"`.
  '');

  # Cargo workspace inheritance: a member field can be `{ workspace = true; }`,
  # meaning "look up `[workspace.package].<field>` in the workspace root".
  # Resolve those at parse time so consumers see flat strings.
  workspacePackage = rootToml.workspace.package or {};
  resolveInherited = field: value:
    if builtins.isAttrs value && value ? workspace && value.workspace == true
    then workspacePackage.${field} or (throw ''
      mkRustToolFlake: ${packageBlock.name or "<member>"}.${field} inherits from
      [workspace.package] but ${toString src}/Cargo.toml has no
      [workspace.package].${field}.
    '')
    else value;
  packageBlock = builtins.mapAttrs resolveInherited rawPackageBlock;

  # bin name precedence: explicit toolName arg > first [[bin]].name > package.name
  binTable = if memberToml ? bin && builtins.length memberToml.bin > 0
             then head memberToml.bin
             else null;
  resolvedToolName =
    if toolName != null then toolName
    else if binTable != null && binTable ? name then binTable.name
    else packageBlock.name;

  resolvedPackageName =
    if packageName != null then packageName
    else packageBlock.name;

  # repo: explicit arg > [package].repository ('https://github.com/owner/name[.git]') > throw
  parseRepoUrl = url:
    let
      stripped = lib.removeSuffix ".git" url;
      parts = lib.splitString "/" stripped;
      len = builtins.length parts;
    in
      if len < 2
      then throw "mkRustToolFlake: cannot parse `${url}` into owner/repo."
      else
        let
          owner = builtins.elemAt parts (len - 2);
          name = builtins.elemAt parts (len - 1);
        in "${owner}/${name}";

  lib = inputs.substrate.inputs.nixpkgs.lib or inputs.nixpkgs.lib;
  resolvedRepo =
    if repo != null then repo
    else if packageBlock ? repository
    then parseRepoUrl packageBlock.repository
    else throw ''
      mkRustToolFlake: pass `repo = "owner/name"` or set
      [package].repository in ${toString src}/Cargo.toml.
    '';

  toolFlake = import ./tool-release-flake.nix {
    inherit (inputs) nixpkgs crate2nix flake-utils;
    fenix = inputs.fenix or null;
    devenv = inputs.devenv or null;
    forge = inputs.forge or null;
  };

  passthrough = builtins.removeAttrs args [
    "inputs" "src" "packageName" "toolName" "repo" "systems" "module"
    "crateOverrides" "buildInputs" "nativeBuildInputs" "buildMode"
  ];

  baseArgs = {
    toolName = resolvedToolName;
    inherit src;
    repo = resolvedRepo;
    inherit crateOverrides buildInputs nativeBuildInputs buildMode;
  }
  // (if packageName != null || isWorkspace
      then { packageName = resolvedPackageName; }
      else {})
  // (if systems != null then { inherit systems; } else {})
  // (if module != null then { inherit module; } else {})
  // passthrough;
in
  toolFlake baseArgs
