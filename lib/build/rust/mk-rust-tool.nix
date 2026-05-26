# mkRustTool — typed single-binary Rust tool builder
#
# Compound abstraction over the lockfile-builder primitive. Operator
# says "I have a Rust tool here" and gets a derivation with
# bin/<name>. No knowledge of Cargo.build-spec.json or lockfile-
# builder ceremony required.
#
# Prerequisites:
#   - <src>/Cargo.toml + Cargo.lock + Cargo.build-spec.json present.
#     Run `gen build .` to produce the spec; commit it alongside
#     Cargo.lock.
{
  name,
  src,
  # Optional: workspace_member key to pick a specific member from a
  # multi-crate workspace. null → uses rootCrate.
  member ? null,
  # Optional defaultCrateOverrides additions (per-crate buildInputs,
  # env vars, etc.). Threaded into buildRustCrate.
  crateOverrides ? {},
  # Optional pkgs override (cross-platform builds).
  buildRustCrateForPkgs ? (p: p.buildRustCrate),
  # Optional meta attrs (description, license, mainProgram, etc.).
  # Merged into the resulting derivation. Defaults: mainProgram=name.
  meta ? {},
}: { pkgs, lib ? pkgs.lib }:
let
  lockfileBuilder = import ./lockfile-builder.nix { inherit pkgs lib; };

  _ = assert (builtins.pathExists (src + "/Cargo.toml")) ||
        throw "mkRustTool: ${name} — Cargo.toml not found at ${toString src}";
       assert (builtins.pathExists (src + "/Cargo.lock")) ||
        throw "mkRustTool: ${name} — Cargo.lock not found at ${toString src}";
       assert (builtins.pathExists (src + "/Cargo.build-spec.json")) ||
        throw ''
          mkRustTool: ${name} — Cargo.build-spec.json missing at ${toString src}.
          Run `gen build .` in the tool's source directory to produce it.
        '';
       null;

  project = lockfileBuilder.mkProject {
    inherit src;
    name = name;
    defaultCrateOverrides = pkgs.defaultCrateOverrides // crateOverrides;
    inherit buildRustCrateForPkgs;
  };

  rawBuild =
    if member != null
    then (project.workspaceMembers.${member} or
          (throw "mkRustTool: ${name} — workspace member `${member}` not found in spec"))
        .build
    else project.rootCrate.build;

  finalMeta = { mainProgram = name; } // meta;
in
  # Wrap with meta overlay. derivation passthru'd; bin/<name> is
  # already on rawBuild from buildRustCrate.
  rawBuild.overrideAttrs (old: { meta = (old.meta or {}) // finalMeta; })
