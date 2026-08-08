# cgo-contract-test.nix — the probe answers correctly, or refuses.
#
# Runs against STUB builders, not real nixpkgs: the point is the DISCRIMINATION
# LOGIC, and a stub lets both contracts and the unrecognised shape be exercised
# on any host without a fetch. The real-nixpkgs answer is asserted separately by
# `probe_matches_live_nixpkgs`.
let
  lib = import <nixpkgs/lib>;
  cgo = import ../cgo-contract.nix { inherit lib; };

  # A stub whose value reaches drvAttrs only via `env` — the modern contract.
  envStub = attrs: { drvAttrs = { CGO_ENABLED = attrs.env.CGO_ENABLED or null; }; };
  # A stub honouring the old top-level contract.
  topStub = attrs: { drvAttrs = { CGO_ENABLED = attrs.CGO_ENABLED or null; }; };
  # A stub honouring NEITHER — the shape that must throw.
  deafStub = _: { drvAttrs = { }; };
  # A stub honouring BOTH — ambiguous, must also throw.
  bothStub = attrs: { drvAttrs = { CGO_ENABLED = attrs.env.CGO_ENABLED or attrs.CGO_ENABLED or null; }; };

  throws = f: !(builtins.tryEval (f null)).success;

  cases = [
    { name = "env-only stub -> \"env\""; expr = cgo.probe envStub == "env"; }
    { name = "top-level-only stub -> \"top-level\""; expr = cgo.probe topStub == "top-level"; }

    # THE ARM THAT MATTERS: an unrecognised shape must REFUSE, not default.
    # Without this the probe would silently pick a side, and a Go build with
    # CGO_ENABLED never set links cgo — a libc dependency in a "static" image.
    { name = "neither-form stub THROWS (never defaults)"; expr = throws (_: cgo.probe deafStub); }
    { name = "both-forms stub THROWS (ambiguous is not a contract)"; expr = throws (_: cgo.probe bothStub); }

    # placeCgo spends the contract in exactly one place.
    { name = "placeCgo env produces env.CGO_ENABLED"; expr = (cgo.placeCgo "env" 0).env.CGO_ENABLED == 0; }
    { name = "placeCgo top-level produces CGO_ENABLED"; expr = (cgo.placeCgo "top-level" 0).CGO_ENABLED == 0; }
    { name = "placeCgo rejects an unknown contract"; expr = throws (_: cgo.placeCgo "wat" 0); }

    # Anti-vacuity: prove the stubs actually differ, so the two positive cases
    # above are not both trivially true.
    { name = "the stubs are genuinely distinguishable"; expr = cgo.probe envStub != cgo.probe topStub; }
  ];

  failures = builtins.filter (c: !c.expr) cases;
  total = builtins.length cases;
in
if failures != [ ] then
  throw ''
    cgo-contract-test: ${toString (builtins.length failures)} of ${toString total} FAILED
    ${builtins.concatStringsSep "\n" (map (f: "  - ${f.name}") failures)}
  ''
else { inherit total; passed = total; }
