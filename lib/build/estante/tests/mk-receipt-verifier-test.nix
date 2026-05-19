# mk-receipt-verifier-test.nix — eval-time shape tests for
# mk-receipt-verifier.nix.
#
# Doesn't run the derivation (that would require an actual estante
# binary + a writable Nix store) — only validates that the function
# is callable with the canonical argument set and produces a
# derivation with the right name, output, and meta. Run via:
#
#   nix-instantiate --eval --strict lib/build/estante/tests/mk-receipt-verifier-test.nix
let
  pkgs = import <nixpkgs> {};
  factory = import ../mk-receipt-verifier.nix { inherit pkgs; };

  # Use coreutils as a placeholder for the estante derivation; the
  # smoke test only checks the wrapper's wiring, not the build.
  drv = factory.mkReceiptVerifier {
    name = "fixture";
    src = ./.;
    estante = pkgs.coreutils;
  };

  shapeAssertions = [
    { label = "name suffix is -receipt-verified";
      pred = drv.name == "fixture-receipt-verified"; }
    { label = "drv is a derivation (attrset)";
      pred = builtins.typeOf drv == "set"; }
    { label = "drv has an out output";
      pred = drv ? out; }
    { label = "drv carries a meta.description";
      pred = drv.meta.description != ""; }
    { label = "description references the consumer-supplied name";
      pred = builtins.match ".*fixture.*" drv.meta.description != null; }
  ];

  customPathsDrv = factory.mkReceiptVerifier {
    name = "custom";
    src = ./.;
    estante = pkgs.coreutils;
    manifestPath = "alt.lisp";
    lockfilePath = "alt.lock.lisp";
    receiptPath = "alt.receipt.json";
  };

  argAssertions = [
    { label = "manifestPath default is shellpkg.lisp";
      # Indirect via stringification of buildCommand — confirm the
      # default value flows into the command body.
      pred = builtins.match ".*shellpkg\\.lisp.*" drv.buildCommand != null; }
    { label = "manifestPath override flows into buildCommand";
      pred = builtins.match ".*alt\\.lisp.*" customPathsDrv.buildCommand != null; }
    { label = "lockfilePath override flows into buildCommand";
      pred = builtins.match ".*alt\\.lock\\.lisp.*" customPathsDrv.buildCommand != null; }
    { label = "receiptPath override flows into buildCommand";
      pred = builtins.match ".*alt\\.receipt\\.json.*" customPathsDrv.buildCommand != null; }
  ];

  allAssertions = shapeAssertions ++ argAssertions;

  runAssert = a:
    if a.pred then true
    else throw "mk-receipt-verifier-test: assertion failed — ${a.label}";

  results = map runAssert allAssertions;
in
  builtins.seq (builtins.deepSeq results results) {
    total = builtins.length allAssertions;
    passed = builtins.length (builtins.filter (x: x) results);
  }
