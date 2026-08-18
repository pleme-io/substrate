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
# `total` is the exception: it is floored a little below the live count so that
# legitimately RETIRING a reusable is not a gate failure, while a collapse in
# discovery still is. A floor that forbids deletion would make this file an
# obstacle to the modularize-don't-delete flow rather than a check on it.
{ lib, workflowCatalog }:
let
  s = workflowCatalog.stats;

  # Measured 2026-08-11, RE-MEASURED 2026-08-18: total 91, shellFree 45,
  # tataraScript 5, documented 91.
  #
  # ── WHY shellFree MOVED 44 -> 45, and why it had to move UP ──────────────
  #
  # Between the two dates the count went 44 -> 42: the three withheld-publish
  # jobs (cargo-publish-each-member / npm / python auto-release) each gained a
  # one-line `run: echo "::notice …"`, and this row was RED for a week. The
  # regression was deliberate at the time and honestly commented — the notice is
  # a workflow ANNOTATION, `step-summary-publish` writes only
  # $GITHUB_STEP_SUMMARY, and converting to it would have deleted the annotation
  # silently. That comment described a MISSING PRIMITIVE, not an exception.
  #
  # The primitive now exists (`pleme-io/actions/annotation-publish`, typed
  # level/title/message + the percent-encoding GitHub's workflow-command grammar
  # requires) and the three echoes are `uses:` calls, so the count is 45: the
  # three recovered, on top of the +1 from `hardened-image-pipeline.yml` landing
  # shell-free (the other arrival, `helm-unittest.yml`, carries two run steps —
  # which is why total moved 89 -> 91 while shellFree only moved 44 -> 42). The
  # floor is raised to 45 in the SAME change, because a floor left at 44 would
  # let exactly this regression happen again unnoticed, which is the whole job of
  # a ratchet. Byte-identity of the three annotations across the conversion is
  # pinned by rows in annotation-publish/run.test.tlisp.
  #
  # `documented` is deliberately NOT raised to 91. Every reusable has a header
  # (`undocumented == [ ]` below proves it, and that row is retirement-proof),
  # whereas a floor of 91 would fail the moment a reusable is legitimately
  # retired — the "floor that forbids deletion" defect the note above warns
  # about. The count row is the anti-vacuity backstop; the list row is the real
  # check.
  floors = {
    total = 80; # 91 today; slack for deliberate retirement, not for a broken scan
    shellFree = 45; # 45 today — the no-`run:` migration, ratcheted 2026-08-18
    tataraScript = 4; # 5 today — reusables INVOKING actions/tatara-script
    documented = 89; # 91 today — see the note above on why this stays at 89
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
