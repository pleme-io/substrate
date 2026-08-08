# gsds-gen-coverage-test.nix — the Go delivery standard must document the gen
# Go path, and its registry row must exist.
#
# ── WHY ─────────────────────────────────────────────────────────────────
#
# Measured 2026-08-08: docs/go/go-software-delivery-standard.md ran to 7,701
# lines mentioning `gen-gomod`, `Go.gen.lock` and `gen build` ZERO times. The
# silence was the defect. An agent reading only the standard would find no
# reason the Go lockfile-delta path is absent, and the shortest correction
# available to them was to wire it — into a consumer that, at the time,
# reconstructed a zero-package spec behind a green freshness verdict.
#
# A prose fix with no gate decays. This pins the tokens.
#
# TIER: eval-rejected (a Nix throw). It asserts the words are PRESENT, not that
# they are correct — a doc gate cannot check truth. Do not round it up.
let
  lib = import <nixpkgs/lib>;
  gsds = builtins.readFile ../../../../docs/go/go-software-delivery-standard.md;
  registry = builtins.readFile ../../../../docs/go/rules-registry.yaml;

  has = hay: needle: builtins.length (builtins.split (lib.escapeRegex needle) hay) > 1;

  cases = [
    { name = "GSDS names the rule id"; expr = has gsds "BUILD-GEN-01"; }
    { name = "GSDS names gen-gomod"; expr = has gsds "gen-gomod"; }
    { name = "GSDS names Go.gen.lock"; expr = has gsds "Go.gen.lock"; }
    { name = "GSDS names gen build"; expr = has gsds "gen build"; }
    { name = "GSDS states the path is deliberately off"; expr = has gsds "deliberately off"; }
    { name = "GSDS records the zero-call-site fact"; expr = has gsds "zero call sites"; }
    { name = "GSDS records retirement by declaration"; expr = has gsds "by declaration"; }
    { name = "registry carries the BUILD-GEN-01 row"; expr = has registry "BUILD-GEN-01"; }
    { name = "registry row is in build-and-packaging"; expr = has registry "id: BUILD-GEN-01"; }
    { name = "registry names the retired mode"; expr = has registry "retired"; }
  ];

  failures = builtins.filter (c: !c.expr) cases;
  total = builtins.length cases;
in
if failures != [ ] then
  throw ''
    gsds-gen-coverage: ${toString (builtins.length failures)} of ${toString total} FAILED
    ${builtins.concatStringsSep "\n" (map (f: "  - ${f.name}") failures)}

    The Go delivery standard has lost its statement that the gen Go path exists
    and is deliberately off. Restoring the words is the fix; deleting this gate
    is not.
  ''
else { inherit total; passed = total; }
