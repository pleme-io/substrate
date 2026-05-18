# Complete multi-system flake outputs for a Rust library workspace
# (no binary). Wraps library-workspace.nix + eachSystem + overlays for
# zero-boilerplate consumer flakes. Mirrors library-flake.nix on the
# multi-crate side.
#
# Usage in a library-workspace flake:
#   {
#     inputs = {
#       nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-25.11";
#       crate2nix.url = "github:nix-community/crate2nix";
#       fenix.url = "github:nix-community/fenix";
#       substrate = {
#         url = "github:pleme-io/substrate";
#         inputs.nixpkgs.follows = "nixpkgs";
#       };
#     };
#     outputs = { self, nixpkgs, crate2nix, fenix, substrate, ... }:
#       (import "${substrate}/lib/rust-library-workspace-flake.nix" {
#         inherit nixpkgs crate2nix fenix;
#       }) {
#         workspaceName = "shigoto";
#         members = [
#           "shigoto"           # umbrella (default)
#           "shigoto-types"
#           "shigoto-dag"
#           "shigoto-scheduler"
#           ...
#         ];
#         defaultMember = "shigoto";
#         src = self;
#       };
#   }
#
# Returns standard flake outputs: packages, devShells, apps, overlays.default.
# `packages.${member}` for each workspace member; `packages.default` aliases
# `packages.${defaultMember}`. `apps.check-all` + `apps.regenerate` run
# workspace-wide.
{
  nixpkgs,
  crate2nix,
  fenix,
  devenv ? null,
}:
{
  workspaceName,
  members,
  defaultMember ? workspaceName,
  systems ? ["aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux"],
  src,
  cargoNix ? null,
  buildInputs ? [],
  nativeBuildInputs ? [],
  crateOverrides ? {},
  extraDevInputs ? [],
  devEnvVars ? {},
  ...
} @ args:
let
  flakeWrapper = import ../../util/flake-wrapper.nix { inherit nixpkgs; };
  hygiene = import ../../util/flake-hygiene.nix {
    lib = (import nixpkgs { system = "x86_64-linux"; }).lib;
  };
  rustOverlayBuilder = import ./overlay.nix;
  # Enforce flake hygiene at evaluation time — fails fast on misconfiguration.
  _hygieneCheck =
    if args ? src && args.src ? inputs then hygiene.enforceAll args.src.inputs
    else true;

  baseArgs = {
    inherit workspaceName members defaultMember src
            buildInputs nativeBuildInputs crateOverrides
            extraDevInputs devEnvVars;
  };
  workspaceArgs =
    if cargoNix != null
    then baseArgs // { inherit cargoNix; }
    else baseArgs;

  # Lightweight nixLib stub — library-workspace.nix only consumes
  # `nixLib.rustOverlays.${system}.rust`, same shape as library.nix.
  mkNixLibStub = system: {
    rustOverlays.${system} = {
      rust = rustOverlayBuilder.mkRustOverlay { inherit fenix system; };
    };
  };

  mkPerSystem = system: let
    rustLibraryWorkspace = import ./library-workspace.nix {
      inherit system nixpkgs devenv crate2nix;
      nixLib = mkNixLibStub system;
    };
  in rustLibraryWorkspace workspaceArgs;
in
  flakeWrapper.mkFlakeOutputs {
    inherit systems mkPerSystem;
    extraOutputs = {
      overlays.default = final: prev: {
        ${workspaceName} = (mkPerSystem final.stdenv.hostPlatform.system).packages.default;
      };
    };
  }
