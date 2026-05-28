# mkRustToolFlake — zero-argument consumer flake for a Rust binary.
#
# Pure dispatch over `Cargo.build-spec.json` (gen-cargo's typed output).
# Reads `spec.flake_metadata.<member>` for tool name + repo slug — all
# TOML parsing happens in Rust.
#
# Consumer flake:
#
#   {
#     inputs.substrate.url = "github:pleme-io/substrate";
#     outputs = i: i.substrate.mkRustToolFlake {
#       inputs = i;
#       src = ./.;                           # MUST be `./.`, not `i.self`.
#       member = "<workspace-member>";       # only when multi-member workspace.
#     };
#   }
#
# `src = ./.` is required (not `inputs.self`) because we read the spec
# at eval time and `self` triggers an outputs-attrset cycle.
{
  inputs ? {},             # consumer flake inputs; substrate pre-binds defaults
  src,
  member ? null,           # workspace member name (defaults to single member)
  toolName ? null,         # override default_bin from spec
  repo ? null,             # override repo from spec
  crateOverrides ? {},
  buildInputs ? [],
  nativeBuildInputs ? [],
  module ? null,           # optional HM/NixOS/Darwin module trio spec
  shape ? "tool",          # tool | workspace | library | service | binary
}:
let
  inherit (builtins) fromJSON readFile pathExists length;

  spec =
    let path = src + "/Cargo.build-spec.json"; in
    if pathExists path then fromJSON (readFile path)
    else throw "mkRustToolFlake: ${toString src}/Cargo.build-spec.json missing — run `gen build .`";

  multiMember = length spec.workspace_members > 1;
  pickedMember =
    if member != null then member
    else if !multiMember then spec.crates.${spec.root_crate}.name
    else throw ''
      mkRustToolFlake: workspace has ${toString (length spec.workspace_members)} members; pass `member = "<one>"`.
      Members: ${builtins.concatStringsSep ", " (map (k: spec.crates.${k}.name) spec.workspace_members)}
    '';

  meta = spec.flake_metadata.${pickedMember}
    or (throw "mkRustToolFlake: spec has no flake_metadata for `${pickedMember}` — regenerate at gen v2+.");

  resolvedToolName = if toolName != null then toolName else (meta.default_bin or pickedMember);
  resolvedRepo = if repo != null then repo
    else meta.repo or (throw "mkRustToolFlake: no repo for `${pickedMember}` — pass `repo` or set [package].repository.");

  toolFlake = import ./tool-release-flake.nix {
    inherit (inputs) nixpkgs crate2nix flake-utils;
    fenix = inputs.fenix or null;
    devenv = inputs.devenv or null;
    forge = inputs.forge or null;
    # gen flows as a flake input here; the inner tool-release-flake.nix
    # resolves it to the host-tool variant (or default) for IFD use.
    gen = inputs.gen or null;
  };
in toolFlake (
  {
    toolName = resolvedToolName;
    inherit src;
    repo = resolvedRepo;
    inherit crateOverrides buildInputs nativeBuildInputs;
  }
  // (if multiMember then { packageName = pickedMember; } else {})
  // (if module != null then { inherit module; } else {})
)
