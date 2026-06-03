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
  #   src        — source derivation
  #
  # Optional attrs (with sensible defaults — mirrors mkGoTool):
  #   version    — version string (default "0.0.0")
  #   vendorHash — Go module deps hash. OMIT ⇒ spec-sourced from gen's Go
  #                build-spec for `src` via lockfile-builder (sentinel
  #                "__from-spec__", delta > build-spec > IFD). Pass null for
  #                in-tree / zero-dep; pass an explicit hash to pin.
  #   proxyVendor     — use proxy vendor mode (default: false)
  #   packages        — Go packages to check (default: "./...")
  #   tags            — Go build tags
  #   extraAttrs      — additional attrs passed to buildGoModule
  #   description     — package description
  #   homepage        — package homepage URL
  #   license         — license (default: lib.licenses.asl20)
  mkGoLibraryCheck = pkgs: {
    pname,
    version ? "0.0.0",
    src,
    vendorHash ? "__from-spec__",
    proxyVendor ? false,
    packages ? [ "./..." ],
    tags ? [],
    extraAttrs ? {},
    description ? "${pname} - Go library build check",
    homepage ? null,
    license ? pkgs.lib.licenses.asl20,
  }: let
    lib = pkgs.lib;
    check = import ../../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "pname" pname)
      (check.nonEmptyStr "version" version)
      (check.bool "proxyVendor" proxyVendor)
      (check.list "packages" packages)
      (check.list "tags" tags)
      (check.attrs "extraAttrs" extraAttrs)
    ];
    pkgArgs = lib.concatStringsSep " " packages;
    # Spec-sourced vendorHash (backward-compatible; mirrors mkGoTool). Sentinel
    # "__from-spec__" ⇒ consumer OMITTED it ⇒ consult gen's Go build-spec for
    # `src` via the Go lockfile-builder (delta > build-spec > IFD). An
    # explicitly-passed value (incl. null for in-tree / zero-dep) wins verbatim.
    goLockfileBuilder = import ./lockfile-builder.nix { inherit pkgs lib; };
    effectiveVendorHash =
      if vendorHash == "__from-spec__"
      then goLockfileBuilder.resolveVendorHash { inherit src; }
      else vendorHash;
  in pkgs.buildGoModule ({
    inherit pname version src proxyVendor tags;
    vendorHash = effectiveVendorHash;
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
    mkGoLibraryCheck' = (import ./library-check.nix).mkGoLibraryCheck;
  in builtins.mapAttrs
    (name: def: mkGoLibraryCheck' final def)
    checkDefs;
}
