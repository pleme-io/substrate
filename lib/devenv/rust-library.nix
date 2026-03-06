# Devenv module for Rust library development.
#
# Same as rust-tool but semantically distinct.
# Use for crates.io library projects.
#
# Usage (in a devenv shell definition):
#   imports = [ "${substrate}/lib/devenv/rust-library.nix" ];
{ pkgs, lib, ... }: {
  imports = [ ./rust.nix ];
}
