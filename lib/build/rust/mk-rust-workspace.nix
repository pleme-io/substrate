# mkRustWorkspace — typed multi-binary/multi-library workspace builder
#
# Sibling of mkRustTool for workspace-shaped repos. Returns an attrset
# `{ workspaceMembers = { <name> = derivation; ... }; allWorkspaceMembers = ...; }`
# so consumers can pick specific members by name without knowing about
# the lockfile-builder internals.
#
# Usage:
#   let ws = (mkRustWorkspace { name = "myworkspace"; src = ./.; }) { inherit pkgs; };
#   in ws.workspaceMembers.cli-tool
#
# Under the operator-surface doctrine (theory/COMMITTED-SPEC-FRESHNESS-GATE.md
# + #76), Cargo.build-spec.json is no longer required at the consumer's
# source root. lockfile-builder's mkProject does the typed dispatch:
# committed spec when present (fast path, no IFD), gen-driven IFD when
# absent. The previous `assert pathExists ... // Cargo.build-spec.json`
# guard predated that doctrine and is dropped — it blocked every
# consumer that retired their committed spec (seki, …) from reaching
# the IFD fallback.
{
  name,
  src,
  crateOverrides ? {},
  buildRustCrateForPkgs ? (p: p.buildRustCrate),
}: { pkgs, lib ? pkgs.lib }:
let
  lockfileBuilder = import ./lockfile-builder.nix { inherit pkgs lib; };
  # Triple-aware: pleme-crate-overrides exports `triple -> overrides`.
  # mkRustWorkspace builds for the workspace's native target (no cross-
  # compilation here), so specialize for `pkgs.stdenv.hostPlatform`.
  plemeCrateOverrides =
    (import ./pleme-crate-overrides.nix) pkgs.stdenv.hostPlatform.rust.rustcTarget;

  project = lockfileBuilder.mkProject {
    inherit src;
    name = name;
    defaultCrateOverrides = pkgs.defaultCrateOverrides // plemeCrateOverrides // crateOverrides;
    inherit buildRustCrateForPkgs;
  };
in {
  inherit (project) rootCrate workspaceMembers allWorkspaceMembers crates;
  /* Convenience: pull a specific member derivation by name. */
  binaryOf = memberName:
    (project.workspaceMembers.${memberName} or
      (throw "mkRustWorkspace: ${name} — member `${memberName}` not found")).build;
}
