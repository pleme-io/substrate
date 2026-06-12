# iroha (いろは) — the pleme-io Nix primitive alphabet.
#
# One controlled, consistent, composable primitive set covering derivations,
# overlays, modules (NixOS / nix-darwin / home-manager), flakes, and
# flake-parts. The classical iroha poem uses every kana exactly once —
# every primitive here exists once; duplication is structurally absent.
#
# Pure { lib } — zero pkgs at import time (pkgs binds late, only inside
# emitted modules and asCheck). Import from anywhere:
#
#   iroha = import "${substrate}/lib/iroha" { lib = nixpkgs.lib; };
#
# Layer model (bottom-up):
#   L0 core            — bands, classes, field types       (core.nix)
#   L1 option algebra  — generated option surfaces         (option-surface.nix)
#   L2 module units    — package modules + daemon units    (package-module.nix, daemon.nix)
#   L3 projections     — overlay algebra                   (overlay.nix)
#   L4 composition     — manifest + profiles               (manifest.nix, profile.nix)
#   L6 proof           — eval-check harness + catalog      (checks.nix, catalog.nix)
#   law                — deprecation shims                 (shim.nix)
#
# Self-test: every letter ships tests/<letter>.nix in the same commit;
# the aggregate is `(import ./tests { inherit lib; })`. Inner loop:
#
#   nix eval --impure --expr \
#     'let fl = builtins.getFlake (toString <substrate>); in
#      (import <substrate>/lib/iroha/tests { lib = fl.inputs.nixpkgs.lib; }).summary'
{ lib }:
let
  core = import ./core.nix { inherit lib; };
  checks = import ./checks.nix { inherit lib; };
  optionSurface = import ./option-surface.nix { inherit lib; };
  daemon = import ./daemon.nix { inherit lib; };
  packageModule = import ./package-module.nix { inherit lib; };
  overlay = import ./overlay.nix { inherit lib; };
  manifest = import ./manifest.nix { inherit lib; };
  profile = import ./profile.nix { inherit lib; };
  shim = import ./shim.nix { inherit lib; };
in
core
// checks
// optionSurface
// daemon
// packageModule
// overlay
// manifest
// profile
// shim
// {
  catalog = import ./catalog.nix { inherit lib; };
  tests = import ./tests { inherit lib; };
  version = "0.1.0";
}
