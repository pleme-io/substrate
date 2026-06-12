# iroha test aggregator — every letter's suite, one tree.
#
# Inner loop (no builds, no flake — new files visible immediately):
#
#   nix eval --impure --expr 'let
#     fl = builtins.getFlake (toString /Users/drzzln/code/github/pleme-io/substrate);
#   in (import /Users/drzzln/code/github/pleme-io/substrate/lib/iroha/tests {
#     lib = fl.inputs.nixpkgs.lib;
#   }).summary'
#
# Full failure detail: swap `.summary` for `.all.failures`.
# Flake check (after git add): checks.<system>.iroha in substrate's flake.
{ lib }:
let
  iroha = import ../. { inherit lib; };

  suiteFiles = {
    core = ./core.nix;
    checks = ./checks.nix;
    option-surface = ./option-surface.nix;
    package-module = ./package-module.nix;
    daemon = ./daemon.nix;
    overlay = ./overlay.nix;
    manifest = ./manifest.nix;
    profile = ./profile.nix;
    shim = ./shim.nix;
    catalog = ./catalog.nix;
  };

  suites = lib.mapAttrs (_: f: import f { inherit lib iroha; }) suiteFiles;

  tree = iroha.mkSuiteTree {
    name = "iroha";
    inherit suites;
  };
in
tree
