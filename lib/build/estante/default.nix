# substrate/lib/build/estante — Nix builders for the estante shell-package
# manager.
#
# Three layers of API surface:
#
#   1. Author side:    `mkShellPackage`         — build one (defshellpkg …)
#                      `mkShellPackageFlake`    — zero-boilerplate flake.nix
#                                                  shape for a package repo
#
#   2. Consumer side:  `mkShellEnv`             — materialize every package
#                                                  from `shellpkg.lock.nix`
#                                                  into one symlinkJoin
#                                                  derivation. The contract
#                                                  with `frost-lisp::defload`
#                                                  is exactly this:
#                                                  materialized_path ↔ /nix/store/...-shell-env
#                      `loadLockfile`           — parse shellpkg.lock.nix
#                                                  into a typed attrset
#
#   3. Script side:    `mkScriptBinary`         — wrap a tatara-lisp script
#                                                  with deps materialized
#                                                  alongside; emits a Nix
#                                                  derivation suitable for
#                                                  `nix profile install`.
#                                                  This is the `uv tool
#                                                  install` equivalent.
#
# All three layers share one canonical Nix representation: the `shellpkg.lock.nix`
# attrset emitted by `estante export --format nix`. The attrset is pure data,
# so Nix consumers `import ./shellpkg.lock.nix` to read it — no estante
# binary needed at evaluation time.
#
# Canonical author-side flake.nix:
#
#   outputs = (import "${substrate}/lib/build/estante/flake.nix" {
#     inherit nixpkgs flake-utils;
#   }) {
#     name = "you-should-use";
#     version = "1.7.4";
#     src = self;
#     description = "Reminds you to use the aliases you've defined.";
#     exports = [ "alias" "hook" ];
#   };
#
# Canonical consumer-side flake.nix:
#
#   outputs = { self, nixpkgs, substrate, ... }:
#     let
#       system = "aarch64-darwin";
#       pkgs = import nixpkgs { inherit system; };
#       estante = import "${substrate}/lib/build/estante" { inherit pkgs; };
#     in {
#       packages.${system}.shell-env = estante.mkShellEnv {
#         lockfile = ./shellpkg.lock.nix;
#       };
#     };
#
# See [docs/estante-nix.md](../../../../estante/docs/estante-nix.md) for the
# end-to-end story.
{ pkgs }:
let
  lib = pkgs.lib;
in
{
  inherit (import ./lockfile-loader.nix { inherit lib; }) loadLockfile;
  inherit (import ./receipt-loader.nix { inherit lib; }) loadReceipt loadDigests;
  inherit (import ./mk-shell-package.nix { inherit pkgs; }) mkShellPackage;
  inherit (import ./mk-shell-env.nix { inherit pkgs; }) mkShellEnv mkPackageDerivation;
  inherit (import ./mk-script-binary.nix { inherit pkgs; }) mkScriptBinary;
}
