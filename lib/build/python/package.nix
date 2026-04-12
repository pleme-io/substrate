# Python Package Builder
#
# Reusable pattern for building Python packages from external source.
# Wraps buildPythonPackage with common conventions for external SDKs
# that use setuptools, flit, or hatchling.
#
# Usage (standalone):
#   pythonPkgBuilder = import "${substrate}/lib/python-package.nix";
#   my-sdk = pythonPkgBuilder.mkPythonPackage pkgs {
#     pname = "my-sdk";
#     version = "1.0.0";
#     src = fetchFromGitHub { ... };
#     propagatedBuildInputs = with pkgs.python3Packages; [ requests ];
#   };
#
# Usage (via substrate lib):
#   my-sdk = substrateLib.mkPythonPackage { ... };
{
  # Build a Python package from external source.
  #
  # Required attrs:
  #   pname       — package name (as on PyPI)
  #   version     — version string
  #   src         — source derivation
  #
  # Optional attrs:
  #   format              — build format: "setuptools", "pyproject", "flit", "hatchling" (default: "setuptools")
  #   propagatedBuildInputs — runtime Python dependencies
  #   nativeBuildInputs    — build-time dependencies
  #   pythonImportsCheck   — modules to test-import (default: [pname])
  #   doCheck             — run tests (default: false for external packages)
  #   extraAttrs          — additional attrs passed to buildPythonPackage
  #   description         — package description
  #   homepage            — package homepage URL
  #   license             — license (default: lib.licenses.asl20)
  mkPythonPackage = pkgs: {
    pname,
    version,
    src,
    format ? "setuptools",
    propagatedBuildInputs ? [],
    nativeBuildInputs ? [],
    pythonImportsCheck ? [ pname ],
    doCheck ? false,
    extraAttrs ? {},
    description ? "${pname} - Python package",
    homepage ? null,
    license ? pkgs.lib.licenses.asl20,
  }: let
    lib = pkgs.lib;
    check = import ../../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "pname" pname)
      (check.nonEmptyStr "version" version)
      (check.enum "format" [ "setuptools" "pyproject" "flit" "hatchling" ] format)
      (check.bool "doCheck" doCheck)
    ];
  in pkgs.python3Packages.buildPythonPackage ({
    inherit pname version src format propagatedBuildInputs
      nativeBuildInputs pythonImportsCheck doCheck;
    meta = {
      inherit description license;
    } // lib.optionalAttrs (homepage != null) { inherit homepage; };
  } // extraAttrs);

  # Create an overlay of Python packages from a definitions attrset.
  mkPythonPackageOverlay = pkgDefs: final: prev: let
    mkPythonPackage' = (import ./package.nix).mkPythonPackage;
  in builtins.mapAttrs
    (name: def: mkPythonPackage' final def)
    pkgDefs;
}
