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
# Same prerequisites as mkRustTool — Cargo.build-spec.json must be
# committed (gen build .).
{
  name,
  src,
  crateOverrides ? {},
  buildRustCrateForPkgs ? (p: p.buildRustCrate),
}: { pkgs, lib ? pkgs.lib }:
let
  lockfileBuilder = import ./lockfile-builder.nix { inherit pkgs lib; };
  plemeCrateOverrides = import ./pleme-crate-overrides.nix;

  _ = assert (builtins.pathExists (src + "/Cargo.build-spec.json")) ||
        throw ''
          mkRustWorkspace: ${name} — Cargo.build-spec.json missing at ${toString src}.
          Run `gen build .` in the workspace root to produce it.
        '';
       null;

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
