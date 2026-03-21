# Complete multi-system flake outputs for a Fleet + Pangea infrastructure project.
# Wraps fleet-pangea-infra.nix + eachSystem for zero-boilerplate consumer flakes.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, ruby-nix, flake-utils, substrate, forge, fleet, ... }:
#     (import "${substrate}/lib/fleet-pangea-infra-flake.nix" {
#       inherit nixpkgs ruby-nix flake-utils substrate forge fleet;
#     }) {
#       inherit self;
#       name = "my-infra";
#       flows = {
#         deploy = { description = "Deploy infra"; steps = [ ... ]; };
#       };
#     };
{
  nixpkgs,
  ruby-nix,
  flake-utils,
  substrate,
  forge,
  fleet ? null,
}:
{
  name,
  self,
  flows ? {},
  systems ? ["x86_64-linux" "aarch64-linux" "aarch64-darwin"],
  shellHookExtra ? "",
  devShellExtras ? [],
}:
  flake-utils.lib.eachSystem systems (system:
    (import ./fleet-pangea-infra.nix {
      inherit nixpkgs system ruby-nix substrate forge fleet;
    }) {
      inherit self name flows shellHookExtra devShellExtras;
    }
  )
