# Go Library Check Builder
#
# Verifies that a Go library compiles without producing a binary.
# Used for external SDK repos where you want build verification
# as a Nix derivation (for CI checks, overlay composition, etc.)
# but the library has no main package to install.
#
# Usage (standalone):
#   goLibCheck = import "${substrate}/lib/go-library-check.nix";
#   sdk-check = goLibCheck.mkGoLibraryCheck pkgs {
#     pname = "akeyless-go-sdk";
#     version = "2.0.0";
#     src = fetchFromGitHub { ... };
#     vendorHash = "sha256-...";
#   };
#
# Usage (via substrate lib):
#   sdk-check = substrateLib.mkGoLibraryCheck { ... };
{
  # Verify a Go library compiles.
  #
  # Required attrs:
  #   pname      — package name
  #   version    — version string
  #   src        — source derivation
  #   vendorHash — hash for Go module dependencies (null if no deps)
  #
  # Optional attrs:
  #   proxyVendor     — use proxy vendor mode (default: false)
  #   packages        — Go packages to check (default: "./...")
  #   tags            — Go build tags
  #   extraAttrs      — additional attrs passed to buildGoModule
  #   description     — package description
  #   homepage        — package homepage URL
  #   license         — license (default: lib.licenses.asl20)
  mkGoLibraryCheck = pkgs: {
    pname,
    version,
    src,
    vendorHash,
    proxyVendor ? false,
    packages ? [ "./..." ],
    tags ? [],
    extraAttrs ? {},
    description ? "${pname} - Go library build check",
    homepage ? null,
    license ? pkgs.lib.licenses.asl20,
  }: let
    lib = pkgs.lib;
    pkgArgs = lib.concatStringsSep " " packages;
  in pkgs.buildGoModule ({
    inherit pname version src vendorHash proxyVendor tags;
    doCheck = false;
    # Only compile — don't install binaries
    buildPhase = ''
      runHook preBuild
      go build ${pkgArgs}
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      runHook postInstall
    '';
    meta = {
      inherit description license;
    } // lib.optionalAttrs (homepage != null) { inherit homepage; };
  } // extraAttrs);

  # Create an overlay of Go library checks from a definitions attrset.
  #
  # Usage:
  #   checksOverlay = goLibCheck.mkGoLibraryCheckOverlay {
  #     my-sdk = { pname = "my-sdk"; ... };
  #     my-grpc = { pname = "my-grpc"; ... };
  #   };
  mkGoLibraryCheckOverlay = checkDefs: final: prev: let
    mkGoLibraryCheck' = (import ./go-library-check.nix).mkGoLibraryCheck;
  in builtins.mapAttrs
    (name: def: mkGoLibraryCheck' final def)
    checkDefs;
}
