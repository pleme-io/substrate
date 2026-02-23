# Go Overlay Module
#
# Provides a reusable Go overlay built from upstream source (go.dev).
# This ensures consistent Go versions across all Go service builds,
# fully independent of nixpkgs' Go version.
#
# SINGLE SOURCE OF TRUTH for all Go builds in the pleme-io stack.
#
# Unlike the Rust overlay (which uses fenix as an external provider), this
# builds Go directly from upstream source tarballs with a prebuilt bootstrap
# binary from go.dev.
#
# Usage:
#   goOverlay = import "${substrate}/lib/go-overlay.nix";
#   pkgs = import nixpkgs {
#     inherit system;
#     overlays = [ (goOverlay.mkGoOverlay {}) ];
#   };
#
# The overlay provides:
#   - pkgs.goToolchain — our from-source Go binary
#   - pkgs.go — overridden to use our toolchain
#   - pkgs.buildGoModule — uses our Go toolchain
{
  # Create a Go overlay using our from-source Go toolchain.
  #
  # Returns: An overlay function (final: prev: ...)
  #
  # This overlay:
  # 1. Builds Go from upstream source with NixOS-compatibility patches
  # 2. Overrides `go` to use our toolchain
  # 3. Overrides `buildGoModule` to use our Go
  mkGoOverlay = {}: final: prev: let
    goToolchain = prev.callPackage ./go/toolchain.nix {};
  in {
    # The from-source Go toolchain
    inherit goToolchain;

    # Override system go
    go = goToolchain;
    go_1_25 = goToolchain;

    # Override buildGoModule to use our Go
    # Use prev.callPackage to avoid infinite recursion — nixpkgs aliases
    # buildGoModule = buildGo125Module, so overriding both creates a cycle.
    buildGoModule = prev.callPackage
      "${prev.path}/pkgs/build-support/go/module.nix" { go = goToolchain; };
    buildGo125Module = prev.callPackage
      "${prev.path}/pkgs/build-support/go/module.nix" { go = goToolchain; };
  };

  # Get the Go toolchain without an overlay
  # Useful when you need the toolchain directly
  getGoToolchain = { pkgs }:
    pkgs.callPackage ./go/toolchain.nix {};
}
