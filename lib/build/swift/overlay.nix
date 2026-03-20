# Swift Overlay Module
#
# Provides a reusable Swift overlay with prebuilt toolchain from swift.org.
#
# Usage:
#   swiftOverlay = import "${substrate}/lib/swift-overlay.nix";
#   pkgs = import nixpkgs {
#     inherit system;
#     overlays = [ (swiftOverlay.mkSwiftOverlay {}) ];
#   };
#
# The overlay provides:
#   - pkgs.swiftToolchain — prebuilt Swift compiler from swift.org
#   - pkgs.swift6 — alias for the toolchain
{
  # Create a Swift overlay with prebuilt toolchain from swift.org.
  #
  # Returns: An overlay function (final: prev: ...)
  mkSwiftOverlay = {}: final: prev: let
    swiftToolchain = prev.callPackage ./bootstrap.nix {};
  in {
    inherit swiftToolchain;
    swift6 = swiftToolchain;
  };
}
