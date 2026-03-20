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
  # Includes: libiconv + apple-sdk (or Security + SystemConfiguration on older nixpkgs)
  mkDarwinBuildInputs = pkgs:
    pkgs.lib.optionals pkgs.stdenv.isDarwin (
      [ pkgs.libiconv ]
      ++ (if pkgs ? apple-sdk
          then [ pkgs.apple-sdk ]
          else pkgs.lib.optionals (pkgs ? darwin) (
            with pkgs.darwin.apple_sdk.frameworks; [
              Security
              SystemConfiguration
            ]
          ))
    );
}
