# Monorepo Parts Module
#
# Returns a flake-parts module that sets up perSystem with:
# - pkgs with Rust overlay applied (via fenix)
# - substrateLib pre-instantiated with all builders
# - Common _module.args for all parts files to consume
#
# Usage in a consumer flake:
#   imports = [
#     (import inputs.substrate.monorepoPartsModule {
#       nixpkgs = inputs.nixpkgs;
#       fenix = inputs.fenix;
#       crate2nix = inputs.crate2nix;
#       forge = inputs.forge;
#     })
#   ];
#
# Then in any parts file:
#   perSystem = { pkgs, substrateLib, ... }: { ... };
{ nixpkgs, fenix, crate2nix, forge ? null, devenv ? null }:
{
  perSystem = { system, ... }: let
    rustOverlay = import ./rust-overlay.nix;
    pkgs = import nixpkgs {
      inherit system;
      overlays = [ (rustOverlay.mkRustOverlay { inherit fenix system; }) ];
    };
    substrateLib = import ./default.nix {
      inherit pkgs system crate2nix forge;
      fenix = fenix.packages.${system};
    };
  in {
    _module.args.pkgs = pkgs;
    _module.args.substrateLib = substrateLib;
    _module.args.devenvInputs = if devenv != null then {
      inherit nixpkgs devenv;
    } else null;
  };
}
