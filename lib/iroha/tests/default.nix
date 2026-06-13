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
    wrapped-package = ./wrapped-package.nix;
    typed-app = ./typed-app.nix;
    mcp = ./mcp.nix;
    vm-check = ./vm-check.nix;
    settings-shikumi = ./settings-shikumi.nix;
    fleet-inventory = ./fleet-inventory.nix;
    host-matrix = ./host-matrix.nix;
    flake-unit = ./flake-unit.nix;
    component-flake = ./component-flake.nix;
    service-module = ./service-module.nix;
    service-bundle = ./service-bundle.nix;
    registry-accumulator = ./registry-accumulator.nix;
    activation-hook = ./activation-hook.nix;
    scheduled-job = ./scheduled-job.nix;
    config-owner = ./config-owner.nix;
    remote-builders = ./remote-builders.nix;
    conf-checks = ./conf-checks.nix;
    udev-tune = ./udev-tune.nix;
    gitops = ./gitops.nix;
    resource-policy = ./resource-policy.nix;
    launchd-unit = ./launchd-unit.nix;
  };

  suites = lib.mapAttrs (_: f: import f { inherit lib iroha; }) suiteFiles;

  tree = iroha.mkSuiteTree {
    name = "iroha";
    inherit suites;
  };
in
tree
