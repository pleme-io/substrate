# Monorepo Flake Aggregator (`mkMonorepoFlake`)
#
# Typed primitive for "dendritic monorepo" flakes — repos that contain N
# sub-projects, each with its own `flake.nix` (typically using
# `rust-tool-release-flake.nix`, `go-tool-flake.nix`, `zig-tool-release-flake.nix`,
# etc.), aggregated under a single root flake so that:
#
#   * `nix build .#<sub-name>`        → sub-tool's `packages.default`
#   * `nix run   .#<sub-name>`        → sub-tool's `apps.default`
#   * `nix develop .#<sub-name>`      → sub-tool's `devShells.default`
#
# Without this helper every monorepo aggregator hand-rolls
#   - an `mkSubTool` that imports `flake.nix` and re-passes shared inputs
#   - a `getPkg`/`getDevShell`/`getApp` projection per output kind
#   - a `filterNulls` over `eachSystem` to skip platform-missing outputs
#   - manual lists of every sub-tool repeated in three attrsets
#
# The pattern was first ripened in `pleme-io/dev-tools` (4 of 11 sub-flakes
# wired). Lifting it to substrate means:
#   1. Adding a new sub-tool is one entry in `subTools`.
#   2. Other monorepos (libraries, pangea-gems, future N-tool repos) consume
#      the same typed surface — no per-repo aggregator drift.
#   3. The `outPath` rebase trick (so each sub-flake sees its own dir as
#      `self`) lives in one place.
#
# USAGE — minimal:
#
#   outputs = { self, nixpkgs, flake-utils, crate2nix, substrate, ... }@inputs:
#     (import "${substrate}/lib/util/monorepo-flake.nix" {
#       inherit (inputs) nixpkgs flake-utils;
#     }) {
#       inherit self;
#       sharedInputs = { inherit nixpkgs flake-utils crate2nix substrate; };
#       subTools = {
#         nix-post-build-hook = "nix-hooks";
#         nix-codesign        = "nix-codesign";
#         nix-macos           = "nix-macos";
#         libkrun-bootstrap   = "libkrun-bootstrap";
#       };
#     };
#
# subTools is `{ <publicName> = <subdir>; ... }` — `publicName` is the
# attr exposed under `packages` / `apps` / `devShells`; `subdir` is the
# directory under `self` that contains the sub-flake.
#
# OPTIONAL knobs:
#
#   systems         — list of systems (default: 4 standard pleme-io systems)
#   extraOutputs    — fn returning an attrset merged into the per-system outputs
#                     after aggregation (e.g. add a `default` shell, formatter…)
{
  nixpkgs,
  flake-utils,
}:
{
  self,
  sharedInputs,
  subTools,
  systems ? [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ],
  extraOutputs ? (_: {}),
}:
let
  lib = nixpkgs.lib;

  # Import each sub-flake and call its `outputs` with shared inputs, rebasing
  # `self.outPath` so the sub-flake sees its own subdir as the flake root.
  mkSubTool = dir:
    let
      subFlake = import (self + "/${dir}/flake.nix");
    in
      subFlake.outputs (sharedInputs // {
        self = self // { outPath = self + "/${dir}"; };
      });

  # Materialize every sub-flake once (outside `eachSystem`) so each is only
  # imported once per evaluation.
  subToolOutputs = lib.mapAttrs (_: dir: mkSubTool dir) subTools;
in
flake-utils.lib.eachSystem systems (system: let
  getPkg = outputs: name:
    (outputs.packages or {}).${system}.${name} or null;

  getApp = outputs: name:
    (outputs.apps or {}).${system}.${name} or null;

  getDevShell = outputs: name:
    (outputs.devShells or {}).${system}.${name} or null;

  filterNulls = lib.filterAttrs (_: v: v != null);

  packages  = filterNulls (lib.mapAttrs (_: o: getPkg      o "default") subToolOutputs);
  apps      = filterNulls (lib.mapAttrs (_: o: getApp      o "default") subToolOutputs);
  devShells = filterNulls (lib.mapAttrs (_: o: getDevShell o "default") subToolOutputs);

  baseOutputs = { inherit packages apps devShells; };
in
  baseOutputs // (extraOutputs { inherit system packages apps devShells subToolOutputs; }))
