# Rust Workspace Release — Typed Builder Wrapper
#
# Validates user arguments through the module system before delegating
# to workspace-release-flake.nix. Drop-in replacement with type checking.
{
  nixpkgs,
  crate2nix,
  flake-utils,
  fenix ? null,
  devenv ? null,
  forge ? null,
}:

userArgs:

let
  lib = nixpkgs.lib or (import nixpkgs {}).lib;

  evaluated = lib.evalModules {
    modules = [
      (import ./workspace-release-module.nix)
      { config.substrate.rust.workspace = userArgs; }
    ];
  };
  spec = evaluated.config.substrate.rust.workspace;

  # Import the existing flake builder (not the raw workspace-release.nix)
  originalBuilder = import ./tool-release-flake.nix {
    inherit nixpkgs crate2nix flake-utils fenix devenv forge;
  };
in originalBuilder {
  inherit (spec) toolName packageName src repo buildInputs nativeBuildInputs crateOverrides;
  cargoNix = if spec.cargoNix != null then spec.cargoNix else spec.src + "/Cargo.nix";
}
