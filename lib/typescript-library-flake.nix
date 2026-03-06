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
  devenv ? null,
}:
{
  name,
  self,
  systems ? ["x86_64-linux" "aarch64-linux" "aarch64-darwin"],
  ...
} @ args:
let
  libArgs = builtins.removeAttrs args ["self" "systems"];
  flakeWrapper = import ./flake-wrapper.nix { inherit nixpkgs; };

  mkPerSystem = system:
    (import ./typescript-library.nix {
      inherit system nixpkgs dream2nix devenv;
    }) (libArgs // { src = self; });
in
  flakeWrapper.mkFlakeOutputs {
    inherit systems mkPerSystem;
  }
