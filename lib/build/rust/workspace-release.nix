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
  # gen powers substrate's IFD spec-regen path. workspace-release-flake
  # auto-fetches via `builtins.getFlake "github:pleme-io/gen"` when
  # the consumer didn't pass one; this forwarding makes the gen
  # binding visible to tool-release → lockfile-builder.
  gen ? null,
}: let
  rustTool = import ./tool-release.nix {
    inherit nixpkgs system crate2nix fenix devenv forge gen;
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
  # Dev-shell-only tooling, by nixpkgs attribute name. Forwarded verbatim —
  # see the parameter's docs in tool-release.nix for why it is separate from
  # nativeBuildInputs. Defaults to [], so no existing consumer changes.
  devShellPackages ? [],
  ...
}:
  rustTool {
    inherit toolName packageName src repo cargoNix buildInputs nativeBuildInputs crateOverrides devShellPackages;
  }
