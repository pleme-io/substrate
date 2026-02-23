# Complete multi-system flake outputs for a Ruby gem library.
# Wraps ruby-gem.nix + eachSystem for zero-boilerplate consumer flakes.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, ruby-nix, flake-utils, substrate, forge, ... }:
#     (import "${substrate}/lib/ruby-gem-flake.nix" {
#       inherit nixpkgs ruby-nix flake-utils substrate forge;
#     }) {
#       inherit self;
#       name = "pangea-core";
#     };
{
  nixpkgs,
  ruby-nix,
  flake-utils,
  substrate,
  forge,
}:
{
  name,
  self,
  systems ? ["x86_64-linux" "aarch64-linux" "aarch64-darwin"],
  shellHookExtra ? "",
  devShellExtras ? [],
}:
  flake-utils.lib.eachSystem systems (system:
    (import ./ruby-gem.nix {
      inherit nixpkgs system ruby-nix substrate forge;
    }) {
      inherit self name shellHookExtra devShellExtras;
    }
  )
