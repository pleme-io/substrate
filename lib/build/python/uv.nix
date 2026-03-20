# Python UV Package Builder
#
# Reusable pattern for building Python packages using UV and pyproject.toml.
# Wraps buildPythonPackage with pyproject.toml format and UV as the build
# backend. Provides a UV-powered dev shell for local development.
#
# UV is the modern standard for Python packaging — fast, reliable, and
# supports pyproject.toml natively. In Nix builds, UV serves as the build
# backend (via hatchling/setuptools/flit) while pip installs the wheel
# into the Nix store. For local development, mkUvDevShell provides a
# full UV + Python environment.
#
# Usage (standalone):
#   uvPythonBuilder = import "${substrate}/lib/python-uv.nix";
#   my-pkg = uvPythonBuilder.mkUvPythonPackage pkgs {
#     pname = "my-pkg";
#     version = "1.0.0";
#     src = fetchFromGitHub { ... };
#     propagatedBuildInputs = with pkgs.python3Packages; [ requests ];
#   };
#
# Usage (via substrate lib):
#   substrateLib = substrate.libFor { inherit pkgs system; };
#   my-pkg = substrateLib.mkUvPythonPackage { ... };
#
# The builder provides:
#   - mkUvPythonPackage — build a Python package using pyproject.toml + UV build backend
#   - mkUvPythonPackageOverlay — create an overlay providing multiple packages
#   - mkUvDevShell — dev shell with Python + UV + common tools
{
  # Build a Python package from pyproject.toml source using UV as build backend.
  #
  # Required attrs:
  #   pname       — package name
  #   version     — version string
  #   src         — source derivation
  #
  # Optional attrs:
  #   python              — Python interpreter package (default: pkgs.python3)
  #   format              — build format (default: "pyproject")
  #   buildSystem         — build backend packages (default: [setuptools wheel])
  #                         Use hatchling, flit-core, pdm-backend, etc. as needed
  #   propagatedBuildInputs — runtime Python dependencies
  #   nativeBuildInputs    — additional build-time dependencies
  #   pythonImportsCheck   — modules to test-import (default: [pname])
  #   doCheck             — run tests (default: false for external packages)
  #   extraAttrs          — additional attrs passed to buildPythonPackage
  #   description         — package description
  #   homepage            — package homepage URL
  #   license             — license (default: lib.licenses.asl20)
  #   platforms           — supported platforms (default: lib.platforms.all)
  mkUvPythonPackage = pkgs: {
    pname,
    version,
    src,
    python ? pkgs.python3,
    format ? "pyproject",
    buildSystem ? (with python.pkgs; [ setuptools wheel ]),
    propagatedBuildInputs ? [],
    nativeBuildInputs ? [],
    pythonImportsCheck ? [ pname ],
    doCheck ? false,
    extraAttrs ? {},
    description ? "${pname} - Python package",
    homepage ? null,
    license ? pkgs.lib.licenses.asl20,
    platforms ? pkgs.lib.platforms.all,
  }: let
    lib = pkgs.lib;
  in python.pkgs.buildPythonPackage ({
    inherit pname version src format propagatedBuildInputs
      pythonImportsCheck doCheck;

    nativeBuildInputs = buildSystem ++ nativeBuildInputs;

    meta = {
      inherit description license platforms;
    } // lib.optionalAttrs (homepage != null) { inherit homepage; };
  } // extraAttrs);

  # Create an overlay of UV Python packages from a definitions attrset.
  #
  # Usage:
  #   uvPythonOverlay = uvPythonBuilder.mkUvPythonPackageOverlay {
  #     my-sdk = { pname = "my-sdk"; version = "1.0"; src = ...; };
  #     other-pkg = { pname = "other-pkg"; version = "2.0"; src = ...; };
  #   };
  #   pkgs = import nixpkgs { overlays = [ uvPythonOverlay ]; };
  mkUvPythonPackageOverlay = pkgDefs: final: prev: let
    mkUvPythonPackage' = (import ./uv.nix).mkUvPythonPackage;
  in builtins.mapAttrs
    (name: def: mkUvPythonPackage' final def)
    pkgDefs;

  # Create a development shell with Python + UV + common tools.
  #
  # This is the recommended dev environment for Python projects.
  # UV handles venv creation, dependency resolution, and package
  # installation outside of Nix — ideal for iterative development.
  #
  # Usage:
  #   devShells.default = uvPythonBuilder.mkUvDevShell pkgs {};
  #   devShells.default = uvPythonBuilder.mkUvDevShell pkgs {
  #     python = pkgs.python311;
  #     extraPackages = [ pkgs.postgresql ];
  #   };
  #
  # Required attrs: none (all have defaults)
  #
  # Optional attrs:
  #   python          — Python interpreter (default: pkgs.python3)
  #   extraPackages   — additional packages to include in the shell
  #   shellHook       — extra shell hook commands
  mkUvDevShell = pkgs: {
    python ? pkgs.python3,
    extraPackages ? [],
    shellHook ? "",
  }: pkgs.mkShellNoCC {
    packages = [
      python
      pkgs.uv
    ] ++ extraPackages;

    shellHook = ''
      export UV_PYTHON=${python}/bin/python3
    '' + shellHook;
  };
}
