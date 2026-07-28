# Complete multi-system flake outputs for a Pangea infrastructure project.
# Wraps pangea-infra.nix + eachSystem for zero-boilerplate consumer flakes.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, ruby-nix, flake-utils, substrate, forge, ... }:
#     (import "${substrate}/lib/pangea-infra-flake.nix" {
#       inherit nixpkgs ruby-nix flake-utils substrate forge;
#     }) {
#       inherit self;
#       name = "my-infra";
#     };
#
# ★★ PLATFORM-MEDIATED INFRASTRUCTURE — `mutatingVerbs` is threaded straight
# through to pangea-infra.nix, so a consumer retires a hand-run mutating verb
# from its own flake without dropping to the per-system builder:
#
#   }) {
#     inherit self;
#     name = "my-infra";
#     mutatingVerbs.apply = {
#       enable    = false;
#       retiredOn = "2026-07-27";
#       executes  = "pangea bulk apply -> OpenTofu apply against S3 state";
#     };
#   };
#
# Default is `enable = true` for every verb — omitting the argument is a
# no-op. See lib/infra/mutating-verbs.nix.
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
  mutatingVerbs ? {},
}:
  flake-utils.lib.eachSystem systems (system:
    (import ./pangea-infra.nix {
      inherit nixpkgs system ruby-nix substrate forge;
    }) {
      inherit self name shellHookExtra devShellExtras mutatingVerbs;
    }
  )
