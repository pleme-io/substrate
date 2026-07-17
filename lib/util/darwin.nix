# Darwin (macOS) build input helpers
#
# Provides the standard set of macOS SDK dependencies needed by Rust crates
# that use TLS (Security framework) or network APIs (SystemConfiguration).
# Handles both old nixpkgs (darwin.apple_sdk.frameworks) and new nixpkgs (apple-sdk).
#
# Usage:
#   buildInputs = (import "${substrate}/lib/darwin.nix").mkDarwinBuildInputs pkgs;
{
  # Standard Darwin build inputs for Rust crates using TLS/networking.
  # Returns empty list on non-Darwin systems.
  #
  # Includes: libiconv + apple-sdk (or Security + SystemConfiguration on older
  # nixpkgs). On modern nixpkgs, `apple-sdk` exposes the PUBLIC frameworks
  # (AppKit, Carbon, Foundation, …) but NOT the SDK's PrivateFrameworks dir.
  # macOS GUI/WM crates that `#[link]` a private framework — SkyLight/CGS
  # (window management), etc. — need `apple-sdk.privateFrameworksHook`, which
  # puts `$SDKROOT/System/Library/PrivateFrameworks` on the link search path.
  # It's inert for crates that don't reference a private framework (just an
  # extra `-iframework` path), so adding it here fleet-wide (rather than making
  # every darwin GUI consumer re-wire it in its own flake) is safe and solves
  # the private-framework link once. Without it, a gen-path darwin build of a
  # SkyLight consumer (e.g. ayatsuri) fails final-link with `Undefined symbols
  # … _SLSMainConnectionID …`.
  mkDarwinBuildInputs = pkgs:
    pkgs.lib.optionals pkgs.stdenv.isDarwin (
      [ pkgs.libiconv ]
      ++ (if pkgs ? apple-sdk
          then [ pkgs.apple-sdk ]
            ++ pkgs.lib.optional (pkgs.apple-sdk ? privateFrameworksHook)
                 pkgs.apple-sdk.privateFrameworksHook
          else pkgs.lib.optionals (pkgs ? darwin) (
            with pkgs.darwin.apple_sdk.frameworks; [
              Security
              SystemConfiguration
            ]
          ))
    );
}
