# Swift SDK Helpers
#
# Provides helpers for discovering and using Apple SDKs in Nix builds.
# Two-tier approach:
#   1. Pure builds: use nixpkgs apple-sdk (Foundation, AppKit)
#   2. Impure builds: use system Xcode SDK (SwiftUI, full frameworks)
{ lib }:

{
  # Standard paths where Xcode installs its SDKs
  xcodeSDKPaths = [
    "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
  ];

  # Host dependencies needed for impure Darwin builds (sandbox escape)
  impureHostDeps = [
    "/usr/lib"
    "/usr/bin"
    "/System/Library/Frameworks"
    "/Library/Developer"
    "/Applications/Xcode.app"
  ];

  # Shell snippet that discovers SDKROOT from system Xcode
  # Sets SDKROOT env var if found, errors otherwise
  sdkrootDiscoveryScript = ''
    if [ -z "''${SDKROOT:-}" ]; then
      if command -v xcrun &>/dev/null; then
        SDKROOT="$(xcrun --show-sdk-path 2>/dev/null)" || true
      fi
      if [ -z "''${SDKROOT:-}" ]; then
        for sdk_path in \
          /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
          /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk; do
          if [ -d "$sdk_path" ]; then
            SDKROOT="$sdk_path"
            break
          fi
        done
      fi
      if [ -z "''${SDKROOT:-}" ]; then
        echo "ERROR: Could not find macOS SDK. Install Xcode or Command Line Tools." >&2
        exit 1
      fi
      export SDKROOT
    fi
  '';

  # Check if SwiftUI is available in the resolved SDK
  swiftUIAvailabilityCheck = ''
    if [ ! -d "$SDKROOT/System/Library/Frameworks/SwiftUI.framework" ]; then
      echo "ERROR: SwiftUI not found in SDK at $SDKROOT" >&2
      echo "SwiftUI requires Xcode (not just Command Line Tools)." >&2
      exit 1
    fi
  '';
}
