# mkRustTool — typed single-binary Rust tool builder
#
# Compound abstraction over the lockfile-builder primitive. Operator
# says "I have a Rust tool here" and gets a derivation with
# bin/<name>. No knowledge of Cargo.build-spec.json or lockfile-
# builder ceremony required.
#
# Prerequisites:
#   - <src>/Cargo.toml + Cargo.lock + Cargo.gen.lock present.
#     Run `gen build .` and commit the Cargo.gen.lock DELTA alongside
#     Cargo.lock.
#
#     Do NOT commit Cargo.build-spec.json. `gen build .` writes both, but
#     only the delta is the standard: ./lockfile-delta.nix reconstructs the
#     full BuildSpec from the delta in pure Nix, IFD-free, at ~1/3 the
#     committed size. Measured 2026-08-17 over the local checkout: 425 repos
#     track Cargo.gen.lock, 11 track the spec, and substrate's own release
#     bot commits "delta-only (build-spec retired)".
#
#     The spec is still load-bearing for ONE case: a VARIANT build. A
#     non-canonical spec name (Cargo.<variant>.build-spec.json) sets
#     useDelta = false at ./lockfile-builder.nix:449 — deliberately, since
#     one delta cannot carry a freshness tie for two specs — so a variant
#     spec must be committed. See pangea-operator, which gitignores the
#     canonical spec and tracks Cargo.noruby.build-spec.json.
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

  # Cargo.toml + Cargo.lock are the operator-authored surface per the
  # doctrine — assert their presence. Cargo.build-spec.json is no
  # longer required at the consumer root; lockfile-builder's mkProject
  # IFD-fallbacks to gen when it isn't committed.
  _ = assert (builtins.pathExists (src + "/Cargo.toml")) ||
        throw "mkRustTool: ${name} — Cargo.toml not found at ${toString src}";
       assert (builtins.pathExists (src + "/Cargo.lock")) ||
        throw "mkRustTool: ${name} — Cargo.lock not found at ${toString src}";
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
