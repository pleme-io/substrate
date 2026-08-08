# directive-test.nix — the Nix half of the ONE directive predicate.
#
# Reads ../directive-vectors.json, the SAME table gen's directive_vectors.rs
# reads. A single byte edit there must turn BOTH red. If only this one goes
# red, a second copy of the ordering rule exists and that is the defect the
# shared table exists to prevent.
#
# ── ANTI-VACUITY ────────────────────────────────────────────────────────
#
# substrate's own mkEvalChecks computes `passed = results == [ ]`, so an EMPTY
# suite builds GREEN. A vector table is exactly the shape that quietly empties
# out. `everyArmHasAVector` is the guard: delete the only
# `above-fleet-toolchain` row and this suite fails naming the arm, rather than
# passing with one fewer case.
let
  lib = import <nixpkgs/lib>;
  d = import ../directive.nix { inherit lib; };
  table = builtins.fromJSON (builtins.readFile ../directive-vectors.json);

  vectorCases = map
    (v: {
      name = "directive '${v.directive}' vs fleet ${v.fleetGo} -> ${v.verdict}";
      expr = (d.classify { inherit (v) directive fleetGo; }).verdict == v.verdict;
    })
    table.vectors;

  armsCovered = lib.unique (map (v: v.verdict) table.vectors);
  missingArms = builtins.filter (a: !(builtins.elem a armsCovered)) d.verdictArms;

  structural = [
    { name = "every verdict arm has >= 1 vector (anti-vacuity)"; expr = missingArms == [ ]; }
    { name = "the table is non-empty"; expr = builtins.length table.vectors > 0; }
    { name = "parse: bare minor detected"; expr = (d.parse "1.25").kind == "bare-minor"; }
    { name = "parse: patch detected"; expr = (d.parse "1.25.0").kind == "patch"; }
    { name = "classify carries the fleetGo it was given"; expr =
        (d.classify { directive = "1.25.0"; fleetGo = "1.26.5"; }).fleetGo == "1.26.5"; }
    { name = "every verdict carries a non-empty why"; expr =
        builtins.all (v: builtins.stringLength (d.classify { inherit (v) directive fleetGo; }).why > 0) table.vectors; }
  ];

  cases = vectorCases ++ structural;
  failures = builtins.filter (c: !c.expr) cases;
  total = builtins.length cases;
in
if failures != [ ] then
  throw ''
    directive-test: ${toString (builtins.length failures)} of ${toString total} FAILED
    ${builtins.concatStringsSep "\n" (map (f: "  - ${f.name}") failures)}
    ${lib.optionalString (missingArms != [ ])
      "\n    verdict arm(s) with NO vector: ${builtins.concatStringsSep ", " missingArms}"}
  ''
else { inherit total; passed = total; }
