# Complete multi-system flake outputs for a Constellation Platform.
#
# Zero-boilerplate wrapper around constellation-platform-infra.nix.
# Reads constellation.json and produces nix run apps for all flows.
#
# Usage:
#   outputs = (import "${substrate}/lib/constellation-platform-infra-flake.nix" {
#     inherit nixpkgs ruby-nix flake-utils substrate forge fleet;
#   }) {
#     inherit self;
#     name = "quero-platform";
#     constellation = builtins.fromJSON (builtins.readFile (self + "/constellation.json"));
#   };
{
  nixpkgs,
  ruby-nix,
  flake-utils,
  substrate,
  forge,
  fleet ? null,
  pangea ? null,
}:
{
  name,
  self,
  constellation,
  systems ? ["x86_64-linux" "aarch64-linux" "aarch64-darwin"],
  shellHookExtra ? "",
  devShellExtras ? [],
}:
  flake-utils.lib.eachSystem systems (system:
    (import ./constellation-platform-infra.nix {
      inherit nixpkgs system ruby-nix substrate forge fleet pangea;
    }) {
      inherit self name constellation shellHookExtra devShellExtras;
    }
  )
