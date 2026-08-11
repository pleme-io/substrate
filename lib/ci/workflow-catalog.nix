# ci.workflowCatalog — CATALOG REFLECTION for substrate's reusable workflows.
#
# WHY THIS EXISTS. substrate ships the fleet's reusable-workflow library, and
# it was the one large surface here with no catalog. `lib/iroha` has
# `catalog.nix` plus a bijection test; `lib/util/eval-suites.nix` has a catalog
# plus a coverage forcing-function; the 89 `workflow_call` workflows under
# `.github/workflows/` had neither. The consequences were all measured on
# 2026-08-11 rather than argued:
#
#   - Answering "does a reusable already do this?" required a `grep -rl
#     workflow_call`. That is a fine command and a terrible interface, and it
#     is what the `tatara-lisp-flows` skill had to tell readers to run.
#   - CLAUDE.md names 37 of the 89. The other 52 are documented only inside
#     their own files, so a table that reads as the catalog covers 42% of it.
#   - An org-level doctrine entry was written that day asserting the delivery
#     chain "must be ONE reusable workflow, not per-repo YAML" — implying none
#     existed — while `image-push.yml` had been doing exactly that for months
#     and the repo in question was already calling it. One catalog read would
#     have prevented the claim.
#
# ── WHY IT IS DERIVED RATHER THAN DECLARED, WHICH IS THE DESIGN ───────────
#
# The obvious shape is iroha's: one hand-written entry per workflow, and a
# bijection test that fails when a workflow lands without one. That shape is
# right for iroha, where a letter's `subsumes` and `dependsOn` are genuine
# human knowledge no reader can recover from the source.
#
# It is wrong here, for a reason worth stating so nobody "improves" this file
# by hand-writing 89 entries:
#
#   Every fact this catalog carries is ALREADY IN THE FILE. Whether a workflow
#   is `workflow_call`, whether it still contains a `run:`, whether it invokes
#   tatara-script, and what it is for (its header comment — a convention
#   substrate's CLAUDE.md already states) are all readable. A hand-written
#   mirror of readable facts is a second source that may disagree with the
#   first, and the disagreement is silent. That is precisely the defect
#   `repo-tags.nix` was written to kill one layer down: a hand-listed roster
#   drifts the moment a new member lands, and still reads as authoritative.
#
# So: nothing is declared. A new workflow appears in this catalog by existing,
# which means the catalog CANNOT drift from the directory — the failure mode
# iroha needs a bijection test to catch is unrepresentable here.
#
# What replaces the forcing-function is the ratchet below.
#
# ── THE RATCHET, AND WHY A FLOOR RATHER THAN A TARGET ─────────────────────
#
# Two migrations are in flight and both were hand-counted on 2026-08-11:
# 44 of 89 workflows are shell-free, and 10 invoke tatara-script. Written into
# prose, those numbers rot the moment anyone edits a workflow, and they rot
# DOWNWARD invisibly — a count that drops reads as a modest claim, never as a
# regression. (The org CLAUDE.md's standing rule about dated coverage claims,
# applied to a number rather than a sentence.)
#
# `tests/workflow-catalog.nix` asserts each count against a FLOOR, so the
# migration may progress freely and may never reverse. A floor is the right
# shape rather than an exact target because an exact target makes every
# improvement a two-file change, and a gate that taxes the improvement it
# exists to encourage gets a reputation for friction and is then deleted.
#
# Raising a floor after a batch of conversions is the deliberate act; letting
# one slip backwards is not possible.
{ lib }:
let
  workflowDir = ../../.github/workflows;

  dir = builtins.readDir workflowDir;

  ymlFiles = builtins.filter (n: (lib.hasSuffix ".yml" n || lib.hasSuffix ".yaml" n) && dir.${n} == "regular") (
    builtins.attrNames dir
  );

  contentsOf = name: builtins.readFile (workflowDir + "/${name}");

  # A reusable workflow is one a CONSUMER can call. `on.workflow_call` is the
  # whole test; substrate's own CI workflows (auto-bump, nix-tests, the
  # selftests) are deliberately out of scope because nobody calls them.
  isReusable = text: lib.hasInfix "workflow_call" text;

  # ── the two derived migration facts ──────────────────────────────────
  #
  # `run:` is matched per LINE with leading whitespace allowed, not with a
  # bare `hasInfix "run:"`. The infix form is wrong in both directions: it
  # matches the word inside a comment or a `runs-on:` value (false positive),
  # and it says nothing about indentation. Matching the line shape is what
  # makes "shell-free" mean the thing the no-shell rule actually asks for.
  linesOf = text: lib.splitString "\n" text;
  isRunStep = line: builtins.match "[[:space:]]*run:.*" line != null;
  hasRunStep = text: builtins.any isRunStep (linesOf text);

  usesTataraScript = text: lib.hasInfix "actions/tatara-script" text;

  # ── the summary, which enforces a convention that was never gated ────
  #
  # substrate's CLAUDE.md states the convention ("Header comment with one-line
  # consumer usage") and nothing checked it. Measured 2026-08-11: 88 of 89
  # already comply, so this gate lands with one fix rather than a migration —
  # which is the moment to add a gate, before the 89th becomes the 20th.
  #
  # The comment need not be the first line. Several workflows open with
  # `name:` and comment underneath, which is fine and common; scanning the
  # head of the file rather than line 1 is what makes this measure the
  # convention instead of a stricter one nobody agreed to.
  #
  # THE COMMENT MUST START AT COLUMN 0, and that is the anti-vacuity fix, not
  # a style preference. A first draft accepted `[[:space:]]*#`, which reported
  # 89 of 89 documented — a false green, because `crates-publish.yml` has no
  # header at all and matched on an INDENTED comment sitting inside its
  # `secrets:` block ("required:false, deliberately — …"). An explanatory note
  # about one field is not a summary of the workflow, so a gate that accepts
  # it passes every file that will ever have a comment anywhere near its top,
  # which is every file. Requiring column 0 is what distinguishes a header
  # from an aside; it reports 88 of 89, and the 89th is a real gap.
  headScanLines = 12;

  summaryOf =
    text:
    let
      head = lib.take headScanLines (linesOf text);
      comments = builtins.filter (l: builtins.match "#.+" l != null) head;
      strip =
        l:
        let
          m = builtins.match "#[[:space:]]*(.*)" l;
        in
        if m == null then "" else lib.head m;
    in
    if comments == [ ] then "" else strip (lib.head comments);

  entryFor =
    name:
    let
      text = contentsOf name;
    in
    {
      file = name;
      summary = summaryOf text;
      shellFree = !(hasRunStep text);
      tataraScript = usesTataraScript text;
    };

  reusableNames = builtins.sort builtins.lessThan (
    builtins.filter (n: isReusable (contentsOf n)) ymlFiles
  );

  entries = lib.listToAttrs (
    map (n: {
      name = lib.removeSuffix ".yml" (lib.removeSuffix ".yaml" n);
      value = entryFor n;
    }) reusableNames
  );

  entryList = builtins.attrValues entries;
  countWhere = pred: builtins.length (builtins.filter pred entryList);
in
{
  inherit entries;

  files = reusableNames;

  # The queryable index the skill's "search before you author" move wants.
  # `nix eval .#workflowCatalog.summaries --json` answers "does a reusable
  # already do this?" without reading 89 files.
  summaries = lib.mapAttrs (_: e: e.summary) entries;

  # Every count carries its DENOMINATOR in the same attrset, which is the
  # anti-vacuity half: if discovery ever breaks, `total` goes to 0 and the
  # floors below fail, rather than every ratio passing against nothing.
  stats = {
    total = builtins.length entryList;
    shellFree = countWhere (e: e.shellFree);
    withRunStep = countWhere (e: !e.shellFree);
    tataraScript = countWhere (e: e.tataraScript);
    documented = countWhere (e: e.summary != "");
    undocumented = countWhere (e: e.summary == "");
  };
}
