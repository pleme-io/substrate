# Rust Tool Release — Typed Builder Wrapper
#
# Validates user arguments through the module system before delegating
# to tool-release.nix. Drop-in replacement with type checking.
#
# Usage (identical to tool-release.nix):
#   mkRustTool = import ./tool-release-typed.nix {
#     inherit nixpkgs crate2nix flake-utils;
#   };
#   outputs = mkRustTool {
#     toolName = "kindling";
#     src = self;
#     repo = "pleme-io/kindling";
#   };
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
      (import ./tool-release-module.nix)
      { config.substrate.rust.tool = userArgs; }
    ];
  };
  spec = evaluated.config.substrate.rust.tool;

  originalBuilder = import ./tool-release-flake.nix {
    inherit nixpkgs crate2nix flake-utils fenix devenv forge;
  };
in originalBuilder {
  inherit (spec) toolName src repo buildInputs nativeBuildInputs crateOverrides;
  cargoNix = if spec.cargoNix != null then spec.cargoNix else spec.src + "/Cargo.nix";
}
