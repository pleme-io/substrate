# Tests — ci.workflowCatalog.
#
# The catalog is fully DERIVED (see its header), so there is no bijection to
# assert: a workflow joins by existing, and cannot be forgotten. What these
# tests hold instead are the three properties derivation alone does not give.
#
#   1. DISCOVERY STILL WORKS. Every count carries its denominator, and the
#      denominator is checked against a floor. This is the anti-vacuity half:
#      if the readDir path breaks or the `workflow_call` predicate stops
#      matching, `total` collapses to 0 — and without this test every ratio
#      below would pass triumphantly against an empty set.
#
#   2. THE HEADER CONVENTION HOLDS. substrate's CLAUDE.md has stated "header
#      comment with one-line consumer usage" for as long as the library has
#      existed, and nothing enforced it. A reusable with no header is one a
#      consumer must reverse-engineer from its `inputs:` block, and the
#      observed consequence of that is not a complaint — it is a second
#      implementation of a workflow that already existed.
#
#   3. THE TWO MIGRATIONS RATCHET. Shell-free and tatara-script counts may
#      rise and may never fall.
#
# ── ON THE FLOORS, AND WHY THEY ARE NOT TODAY'S NUMBERS ──────────────────
#
# Each floor is set AT the measured value for the counts that must not
# regress, because the whole point is that today's state is the new minimum.
# `total` is the exception: it is floored a little below 89 so that
# legitimately RETIRING a reusable is not a gate failure, while a collapse in
# discovery still is. A floor that forbids deletion would make this file an
# obstacle to the modularize-don't-delete flow rather than a check on it.
{ lib, workflowCatalog }:
let
  s = workflowCatalog.stats;

  # Measured 2026-08-11 by evaluating this catalog against the tree.
  floors = {
    total = 80; # 89 today; slack for deliberate retirement, not for a broken scan
    shellFree = 44; # 44 today — the no-`run:` migration, ratcheted
    tataraScript = 4; # 4 today — reusables INVOKING actions/tatara-script
    documented = 89; # 89 today — crates-publish.yml, the lone gap, fixed alongside
  };

  undocumentedFiles = map (e: e.file) (
    builtins.filter (e: e.summary == "") (builtins.attrValues workflowCatalog.entries)
  );
in
{
  # (1) Discovery is alive. Stated as a floor on the DENOMINATOR so that a
  # broken scan fails here rather than silently passing everything else.
  discovery-finds-the-reusable-workflows = {
    expr = s.total >= floors.total;
    expected = true;
  };

  # The partition is complete: every reusable is either shell-free or carries
  # a run step, with nothing falling outside. A drift between the two counts
  # and the total would mean the classifier stopped classifying.
  shell-free-partition-is-complete = {
    expr = s.shellFree + s.withRunStep == s.total;
    expected = true;
  };

  documented-partition-is-complete = {
    expr = s.documented + s.undocumented == s.total;
    expected = true;
  };

  # (2) The header convention, gated for the first time.
  every-reusable-workflow-has-a-header-comment = {
    # Reports the offending FILENAMES rather than a bare count, because a
    # failing gate that says "88 != 89" sends the reader to write the script
    # this test could have run for them.
    expr = {
      atOrAboveFloor = s.documented >= floors.documented;
      undocumented = undocumentedFiles;
    };
    expected = {
      atOrAboveFloor = true;
      undocumented = [ ];
    };
  };

  # (3) The ratchets. These may rise; they may not fall.
  shell-free-count-never-regresses = {
    expr = s.shellFree >= floors.shellFree;
    expected = true;
  };

  tatara-script-count-never-regresses = {
    expr = s.tataraScript >= floors.tataraScript;
    expected = true;
  };

  # A summary that is present but empty would satisfy the count while telling
  # a reader nothing, so hold a minimum length. Ten characters is deliberately
  # low: this rejects `#` and `# TODO`, and does not attempt to referee prose.
  every-summary-is-substantive = {
    expr = builtins.all (e: e.summary == "" || builtins.stringLength e.summary >= 10) (
      builtins.attrValues workflowCatalog.entries
    );
    expected = true;
  };

  # The catalog's own index must be usable: one summary per reusable, keyed
  # the same way. A drift here means `.#workflowCatalog.summaries` — the
  # surface the tatara-lisp-flows skill points readers at — is incomplete.
  summaries-cover-every-entry = {
    expr =
      builtins.length (builtins.attrNames workflowCatalog.summaries)
      == builtins.length (builtins.attrNames workflowCatalog.entries);
    expected = true;
  };
}
