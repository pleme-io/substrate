# Complete multi-system flake outputs for a TypeScript library.
# Wraps typescript-library.nix + eachSystem for zero-boilerplate consumer flakes.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, dream2nix, substrate, ... }:
#     (import "${substrate}/lib/typescript-library-flake.nix" {
#       inherit nixpkgs dream2nix substrate;
#     }) {
#       inherit self;
#       name = "pleme-ui-components";
#     };
{
  nixpkgs,
  dream2nix,
  substrate,
}:
{
  name,
  self,
  systems ? ["x86_64-linux" "aarch64-linux" "aarch64-darwin"],
  ...
} @ args:
let
  libArgs = builtins.removeAttrs args ["self" "systems"];
  eachSystem = f: nixpkgs.lib.genAttrs systems f;
  mkOutputs = system:
    (import ./typescript-library.nix {
      inherit system nixpkgs dream2nix;
    }) (libArgs // { src = self; });
in
{
  packages = eachSystem (system: (mkOutputs system).packages);
  devShells = eachSystem (system: (mkOutputs system).devShells);
  apps = eachSystem (system: (mkOutputs system).apps);
}
