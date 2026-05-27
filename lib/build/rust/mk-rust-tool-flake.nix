# mkRustToolFlake — zero-argument consumer flake for a Rust binary.
#
# Pure dispatch over `Cargo.build-spec.json` (gen-cargo's typed output).
# Reads `spec.flake_metadata.<packageName>` for the tool name + repo
# slug — no Cargo.toml parsing in Nix.
#
# Consumer flake collapses to:
#
#   {
#     inputs.substrate.url = "github:pleme-io/substrate";
#     outputs = i: i.substrate.mkRustToolFlake {
#       inherit (i) self;
#       inputs = i;
#       packageName = "<workspace member>";   # only when workspace
#     };
#   }
#
# Single-crate workspaces don't need `packageName` — the spec's
# `root_crate` field identifies the only buildable. Per-consumer overrides
# (crateOverrides, buildInputs, nativeBuildInputs) pass through verbatim.
{
  inputs,
  src,
  packageName ? null,    # required when the workspace has multiple members
  toolName ? null,       # override autodetected default-bin
  repo ? null,           # override autodetected owner/name
  systems ? null,
  module ? null,
  crateOverrides ? {},
  buildInputs ? [],
  nativeBuildInputs ? [],
  buildMode ? "auto",
  ...
} @ args:
let
  inherit (builtins) fromJSON readFile pathExists;

  specPath = src + "/Cargo.build-spec.json";
  spec =
    if pathExists specPath
    then fromJSON (readFile specPath)
    else throw ''
      mkRustToolFlake: ${toString src}/Cargo.build-spec.json is missing.
      Run `gen build .` in the workspace root first.
    '';

  # Pick the workspace member name. Single-member workspaces use the
  # root_crate's name; multi-member ones require packageName.
  rootKey = spec.root_crate;
  rootCrateName = spec.crates.${rootKey}.name;
  pickedName =
    if packageName != null then packageName
    else if builtins.length spec.workspace_members == 1 then rootCrateName
    else throw ''
      mkRustToolFlake: workspace has multiple members; pass `packageName = "<one of these>"`.
      Members: ${builtins.concatStringsSep ", " (map (k: spec.crates.${k}.name) spec.workspace_members)}
    '';

  meta = spec.flake_metadata.${pickedName} or (throw ''
    mkRustToolFlake: spec has no flake_metadata for `${pickedName}`. Did you
    regenerate the spec with gen ≥ v0.1.1?
  '');

  resolvedToolName =
    if toolName != null then toolName
    else meta.default_bin or pickedName;

  resolvedRepo =
    if repo != null then repo
    else meta.repo or (throw ''
      mkRustToolFlake: spec has no repo for `${pickedName}`. Pass `repo = "owner/name"`
      or add `repository = "https://github.com/owner/name"` to the member's Cargo.toml.
    '');

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
  // (if builtins.length spec.workspace_members > 1
      then { packageName = pickedName; }
      else {})
  // (if systems != null then { inherit systems; } else {})
  // (if module != null then { inherit module; } else {})
  // passthrough;
in
  toolFlake baseArgs
