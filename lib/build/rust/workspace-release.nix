# ============================================================================
# RUST WORKSPACE RELEASE BUILDER — thin wrapper over tool-release.nix
# ============================================================================
# tool-release.nix now accepts an optional `packageName`; workspace support is
# just tool-release with that argument required. This file remains as a named
# entry point so consumer flakes read naturally:
#
#   rustWorkspace {
#     toolName = "mamorigami";        # binary name
#     packageName = "mamorigami-cli"; # workspace member crate
#     src = self;
#     repo = "pleme-io/mamorigami";
#   }
#
# Returns: { packages, devShells, apps } — identical shape to tool-release.
{
  nixpkgs,
  system,
  crate2nix,
  fenix ? null,
  devenv ? null,
  forge ? null,
}: let
  rustTool = import ./tool-release.nix {
    inherit nixpkgs system crate2nix fenix devenv forge;
  };
in {
  toolName,
  packageName,
  src,
  repo,
  cargoNix ? src + "/Cargo.nix",
  buildInputs ? [],
  nativeBuildInputs ? [],
  crateOverrides ? {},
  ...
}:
  rustTool {
    inherit toolName packageName src repo cargoNix buildInputs nativeBuildInputs crateOverrides;
  }
