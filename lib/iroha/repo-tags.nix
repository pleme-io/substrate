# iroha.repoTags — DERIVED tag membership with typed explicit overrides.
#
# The other half of `mkOverlayPolicy`: that letter takes a `tagsOf` function and
# deliberately does not decide what a "gpu repo" IS, because membership is fleet
# DATA rather than build algebra. This is the letter that computes it.
#
# ── WHY DERIVED-FIRST, AND WHY OVERRIDES ANYWAY ───────────────────────────
#
# Two obvious designs are each wrong on their own:
#
#   hand-listed  — `gpu = [ mado hibikine kagibako ]`. Drifts the moment a new
#                  GPU repo lands, and nothing says so: the new repo silently
#                  misses the overlay its siblings get, and the list still looks
#                  authoritative. This is the same class as a coverage claim
#                  with no denominator.
#
#   purely derived — `a repo is gpu iff its deps mention wgpu`. Cannot express
#                  an exception, so the one repo that legitimately differs
#                  forces the predicate to grow a special case, and the
#                  predicate stops meaning what its name says.
#
# So: derive by default, allow typed `include` / `exclude`, and state the
# precedence rather than leaving it implicit. EXCLUDE WINS over include, because
# the safe failure is "a repo does not get an overlay" rather than "a repo gets
# one somebody explicitly said it must not have".
#
# ── EVERY OVERRIDE CARRIES ITS REASON, AND THE RESULT CARRIES ITS SOURCE ──
#
# An override is a statement that the derivation is wrong for this repo. That is
# exactly the kind of decision that becomes archaeology in six months, so a
# reason is REQUIRED — same discipline as `iroha.overlay`'s fixes and
# `mkOverlayPolicy`'s scopes.
#
# `explain` reports, per repo, WHY it holds each tag: `derived`, `included`, or
# `excluded`. Without that, "why does mado get the wgpu fix?" is a code-reading
# exercise instead of a query — and a tag set that cannot say why it contains
# something is indistinguishable from one that guessed.
#
# ── THE DENOMINATOR ───────────────────────────────────────────────────────
#
# `stats` reports, per tag, how many members came from derivation vs override.
# A tag whose members are ENTIRELY overrides is a predicate that is not working
# — it reads as a working rule while behaving as a hand-list, which is the
# hand-listed failure mode wearing the derived design's clothes. Surfacing the
# split is what makes that visible rather than invisible.
#
# EXPORTS (pure { lib }, zero pkgs, zero IO — facts are supplied by the caller
# so this stays evaluable without reading the filesystem):
#
#   mkRepoTags :: {
#     repos :: [ str ],                     — the universe (the denominator)
#     facts :: attrsOf (attrsOf any),       — repo -> arbitrary typed facts
#     tags  :: attrsOf {
#       derive  ? (facts -> bool),          — membership predicate; null = never
#       include ? [ str ],                  — force-in
#       exclude ? [ str ],                  — force-out (WINS over include)
#       reason,                             — REQUIRED provenance
#     },
#   } -> {
#     tagsOf  :: repoName -> [ tagName ];   — feeds mkOverlayPolicy directly
#     members :: attrsOf [ repoName ];
#     explain :: repoName -> attrsOf str;   — tag -> "derived"|"included"
#     stats   :: attrsOf { derived, included, excluded, total };
#   }
{ lib }:
let
  requireReason =
    tagName: spec:
    if (spec.reason or "") == "" then
      throw (
        "iroha.repoTags: tag '${tagName}' has no `reason`. A tag decides which overlays a whole "
        + "GROUP of repos receives, so an unexplained one is unexplained everywhere it applies."
      )
    else
      spec;

  checkKnown =
    tagName: field: repos: names:
    let
      unknown = builtins.filter (n: !(builtins.elem n repos)) names;
    in
    if unknown == [ ] then
      names
    else
      throw (
        "iroha.repoTags: tag '${tagName}' lists unknown repo(s) in `${field}`: "
        + "${lib.concatStringsSep ", " unknown}. An override naming a repo that does not exist is "
        + "either a typo or a rename nobody propagated; both are silent no-ops if allowed through."
      );
in
{
  mkRepoTags =
    {
      repos,
      facts ? { },
      tags ? { },
    }:
    let
      specs = lib.mapAttrs requireReason tags;

      # Per tag, classify every repo in the universe exactly once.
      classify =
        tagName: spec:
        let
          include = checkKnown tagName "include" repos (spec.include or [ ]);
          exclude = checkKnown tagName "exclude" repos (spec.exclude or [ ]);
          derive = spec.derive or null;
          derivedOf = repo: derive != null && derive (facts.${repo} or { });
        in
        lib.listToAttrs (
          map (
            repo:
            lib.nameValuePair repo (
              # EXCLUDE WINS. Stated as the first branch so the precedence is
              # readable rather than inferred from operator order.
              if builtins.elem repo exclude then
                "excluded"
              else if builtins.elem repo include then
                "included"
              else if derivedOf repo then
                "derived"
              else
                null
            )
          ) repos
        );

      classified = lib.mapAttrs classify specs;

      membersOf =
        tagName:
        builtins.filter (
          repo:
          let
            c = classified.${tagName}.${repo};
          in
          c != null && c != "excluded"
        ) repos;

      members = lib.mapAttrs (tagName: _: membersOf tagName) specs;
    in
    {
      tagsOf =
        repo:
        builtins.filter (
          tagName:
          let
            c = classified.${tagName}.${repo} or null;
          in
          c != null && c != "excluded"
        ) (builtins.attrNames specs);

      inherit members;

      # `explain` deliberately REPORTS "excluded" rather than omitting it.
      #
      # The first version filtered excluded repos out, so an excluded repo looked
      # identical to one that simply never matched — and those are opposite
      # facts: one is a decision somebody made and must be able to defend, the
      # other is the predicate working normally. Hiding the exclusion would make
      # "why doesn't legacy-gpu-thing get the wgpu fix?" unanswerable from the
      # data, which is the archaeology this letter exists to prevent.
      #
      # Only genuine non-membership (`null`) is omitted. Read `members` for
      # "who gets it"; read `explain` for "why, including why not".
      explain =
        repo:
        lib.filterAttrs (_: v: v != null) (
          lib.mapAttrs (tagName: _: classified.${tagName}.${repo} or null) specs
        );

      # The denominator, per tag: a tag that is entirely `included` is a
      # predicate that is not doing its job, wearing the derived design's
      # clothes. Counting the split is what makes that visible.
      stats = lib.mapAttrs (
        tagName: _:
        let
          cs = classified.${tagName};
          countOf = want: builtins.length (builtins.filter (r: cs.${r} == want) repos);
        in
        {
          derived = countOf "derived";
          included = countOf "included";
          excluded = countOf "excluded";
          total = builtins.length (membersOf tagName);
          universe = builtins.length repos;
        }
      ) specs;
    };
}
