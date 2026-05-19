# lockfile-loader-test.nix — eval-time tests for lockfile-loader.nix.
#
# Mirrors receipt-loader-test.nix at the same layer. Each `assert`
# predicate must hold; the file evaluates to a summary attrset
# `{ total = N; passed = N; }` if every assertion passes, and `throw`s
# on the first failure. Run:
#
#   nix-instantiate --eval --strict lib/build/estante/tests/lockfile-loader-test.nix
#
# Fixture `fixture-lockfile.nix` is a synthetic two-package
# shellpkg.lock.nix shape — portable across hosts because it omits
# real user-specific cache paths.
let
  pkgs = import <nixpkgs> {};
  lib = pkgs.lib;
  loader = import ../lockfile-loader.nix { inherit lib; };

  loaded = loader.loadLockfile (import ./fixture-lockfile.nix);
  packagesOnly = loader.loadPackages (import ./fixture-lockfile.nix);

  isHex = s: builtins.match "[0-9a-f]+" s != null;

  # ─── Fixture-shape assertions ────────────────────────────────────
  shapeAssertions = [
    { label = "schemaVersion is 1";
      pred = loaded.schemaVersion == 1; }
    { label = "packages count is 2";
      pred = builtins.length loaded.packages == 2; }
    { label = "first package name is alpha";
      pred = (builtins.elemAt loaded.packages 0).name == "alpha"; }
    { label = "first package source is github:org/alpha";
      pred = (builtins.elemAt loaded.packages 0).source == "github:org/alpha"; }
    { label = "first package rev is 40-char hex";
      pred = isHex (builtins.elemAt loaded.packages 0).rev
             && builtins.stringLength (builtins.elemAt loaded.packages 0).rev == 40; }
    { label = "first package blake3 is 64-char hex";
      pred = isHex (builtins.elemAt loaded.packages 0).blake3
             && builtins.stringLength (builtins.elemAt loaded.packages 0).blake3 == 64; }
    { label = "first package entrypoint defaults are filled";
      pred = (builtins.elemAt loaded.packages 0).entrypoint != ""; }
    { label = "first package exports defaults to []";
      pred = builtins.isList (builtins.elemAt loaded.packages 0).exports; }
    { label = "first package lazy defaults to bool";
      pred = builtins.typeOf (builtins.elemAt loaded.packages 0).lazy == "bool"; }
    { label = "second package name is beta";
      pred = (builtins.elemAt loaded.packages 1).name == "beta"; }
    { label = "second package narHash defaults to empty when omitted";
      pred = (builtins.elemAt loaded.packages 1).narHash == ""; }
  ];

  # ─── loadPackages convenience ────────────────────────────────────
  convenienceAssertions = [
    { label = "loadPackages returns the packages list";
      pred = builtins.length packagesOnly == builtins.length loaded.packages; }
    { label = "loadPackages first element matches loadLockfile";
      pred = (builtins.elemAt packagesOnly 0).name
             == (builtins.elemAt loaded.packages 0).name; }
  ];

  # ─── Validation-error assertions (negative paths) ────────────────
  errorAssertions = [
    { label = "bad schemaVersion is rejected";
      pred = !(builtins.tryEval (loader.loadLockfile {
        schemaVersion = 99;
        packages = [];
      })).success; }
    { label = "missing schemaVersion is rejected (default 0)";
      pred = !(builtins.tryEval (loader.loadLockfile {
        packages = [];
      })).success; }
    { label = "integer argument is rejected";
      pred = !(builtins.tryEval (loader.loadLockfile 42)).success; }
    { label = "entry missing required field is rejected";
      pred = !(builtins.tryEval (loader.loadLockfile {
        schemaVersion = 1;
        packages = [ { name = "x"; } ];
      })).success; }
  ];

  allAssertions = shapeAssertions ++ convenienceAssertions ++ errorAssertions;

  runAssert = a:
    if a.pred then true
    else throw "lockfile-loader-test: assertion failed — ${a.label}";

  results = map runAssert allAssertions;
in
  builtins.seq (builtins.deepSeq results results) {
    total = builtins.length allAssertions;
    passed = builtins.length (builtins.filter (x: x) results);
  }
