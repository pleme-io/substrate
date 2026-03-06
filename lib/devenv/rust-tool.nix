# Devenv module for Rust CLI tool development.
#
# Lighter than rust-service: no database, no protobuf.
# Just Rust toolchain + dev tools.
#
# Usage (in a devenv shell definition):
#   imports = [ "${substrate}/lib/devenv/rust-tool.nix" ];
{ pkgs, lib, ... }: {
  imports = [ ./rust.nix ];
}
