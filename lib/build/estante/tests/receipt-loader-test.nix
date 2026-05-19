# receipt-loader-test.nix — eval-time tests for receipt-loader.nix.
#
# Each `assert` predicate must hold; the file evaluates to `true` if
# every assertion passes and `throw`s on the first failure. Run:
#
#   nix-instantiate --eval lib/build/estante/tests/receipt-loader-test.nix
#
# Fixture `fixture-receipt.json` is a real receipt emitted by
# `estante attest` against a one-package local fixture. The test
# asserts on the typed shape, not the specific BLAKE3 values — so
# regenerating the fixture is safe.
let
  pkgs = import <nixpkgs> {};
  lib = pkgs.lib;
  loader = import ../receipt-loader.nix { inherit lib; };

  fixtureReceipt = loader.loadReceipt (builtins.fromJSON (
    builtins.readFile ./fixture-receipt.json
  ));

  digests = loader.loadDigests (builtins.fromJSON (
    builtins.readFile ./fixture-receipt.json
  ));

  isHex = s: builtins.match "[0-9a-f]+" s != null;

  # ─── Fixture-shape assertions ──────────────────────────────────────
  shapeAssertions = [
    { label = "schemaVersion is 1";
      pred = fixtureReceipt.schemaVersion == 1; }
    { label = "estante.version is non-empty";
      pred = fixtureReceipt.estante.version != ""; }
    { label = "manifest.path is shellpkg.lisp";
      pred = fixtureReceipt.manifest.path == "shellpkg.lisp"; }
    { label = "manifest.blake3 is hex";
      pred = isHex fixtureReceipt.manifest.blake3; }
    { label = "manifest.blake3 is 64 chars";
      pred = builtins.stringLength fixtureReceipt.manifest.blake3 == 64; }
    { label = "lockfile.path is shellpkg.lock.lisp";
      pred = fixtureReceipt.lockfile.path == "shellpkg.lock.lisp"; }
    { label = "lockfile.blake3 is hex";
      pred = isHex fixtureReceipt.lockfile.blake3; }
    { label = "entries has at least one";
      pred = builtins.length fixtureReceipt.entries >= 1; }
    { label = "first entry has a name";
      pred = (builtins.elemAt fixtureReceipt.entries 0).name != ""; }
    { label = "first entry has hex blake3";
      pred = isHex (builtins.elemAt fixtureReceipt.entries 0).blake3; }
    { label = "first entry placement is cache/nix/both";
      pred = builtins.elem
        (builtins.elemAt fixtureReceipt.entries 0).placement
        [ "cache" "nix" "both" ]; }
    { label = "first entry materializedExists is bool";
      pred = builtins.typeOf (builtins.elemAt fixtureReceipt.entries 0).materializedExists == "bool"; }
  ];

  # ─── Digest-shape assertions ──────────────────────────────────────
  digestAssertions = [
    { label = "digests.manifest matches receipt.manifest.blake3";
      pred = digests.manifest == fixtureReceipt.manifest.blake3; }
    { label = "digests.lockfile matches receipt.lockfile.blake3";
      pred = digests.lockfile == fixtureReceipt.lockfile.blake3; }
    { label = "digests.entries count matches";
      pred = builtins.length digests.entries
             == builtins.length fixtureReceipt.entries; }
  ];

  # ─── Validation-error assertions (negative paths) ────────────────
  errorAssertions =
    let
      validEntry = { name = "x"; blake3 = "y"; placement = "cache"; };
      validManifest = { path = "p"; blake3 = "h"; };
      validLockfile = { path = "p"; blake3 = "h"; };
      validEstante = { version = "0"; };
    in [
      { label = "bad schemaVersion is rejected";
        pred = !(builtins.tryEval (loader.loadReceipt {
          schemaVersion = 99;
          manifest = validManifest;
          lockfile = validLockfile;
          entries = [];
          estante = validEstante;
        })).success; }
      { label = "missing top-level field is rejected";
        pred = !(builtins.tryEval (loader.loadReceipt {
          schemaVersion = 1;
          manifest = validManifest;
          # no lockfile
          entries = [];
        })).success; }
      { label = "integer argument is rejected";
        pred = !(builtins.tryEval (loader.loadReceipt 42)).success; }
      { label = "entry missing required field is rejected";
        pred = !(builtins.tryEval (loader.loadReceipt {
          schemaVersion = 1;
          manifest = validManifest;
          lockfile = validLockfile;
          entries = [ { name = "x"; } ];
          estante = validEstante;
        })).success; }
    ];

  allAssertions = shapeAssertions ++ digestAssertions ++ errorAssertions;

  runAssert = a:
    if a.pred then true
    else throw "receipt-loader-test: assertion failed — ${a.label}";

  results = map runAssert allAssertions;
in
  # Force the assertion list to fully evaluate, then return a small
  # summary attrset so a caller can `--strict` eval and see exactly
  # how many checks ran.
  builtins.seq (builtins.deepSeq results results) {
    total = builtins.length allAssertions;
    passed = builtins.length (builtins.filter (x: x) results);
  }
