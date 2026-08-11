# iroha.overlayPolicy — SCOPED overlay governance: which overlays a repo gets,
# and how tightly each dependency may be pinned, declared once per scope and
# resolved org < tag < repo.
#
# WHY THIS EXISTS. `iroha.overlay` already gives the fleet a complete overlay
# ALGEBRA — typed input re-exports, provenance-mandatory fix catalogs, layer and
# composite composition with a queryable registry. What it has no concept of is
# WHO GETS WHAT. Every consumer hand-wires its own layer list, so "all pleme-io
# repos get the rust toolchain overlay, the GPU repos also get the wgpu quirk
# fix, and mado additionally gets a local patch" is expressible only as three
# hand-maintained lists that are free to disagree — the exact duplication the
# PRIME DIRECTIVE forbids, one level up from the overlays themselves.
#
# This is the missing letter, and it sits ON TOP of `composeLayers` rather than
# replacing it: a policy resolves to a LIST OF LAYER NAMES, which is precisely
# what composeLayers already consumes. Nothing about the existing algebra
# changes.
#
# ── THE TWO AXES, AND WHY THEY COMPOSE DIFFERENTLY ────────────────────────
#
# A policy carries two different kinds of statement, and treating them the same
# way is the trap:
#
#   overlays  — SELECTION. Composes by UNION as scopes narrow. An org grant is
#               a floor: a tag adds to it, a repo adds to that. Additive.
#
#   pins      — CONSTRAINT. Composes by NARROWING. An org constraint is a
#               CEILING: a tag or repo may tighten it, and may NEVER widen it.
#
# Getting this backwards is how a governance system becomes decorative: if a
# repo could widen `allow = "patch"` to `allow = "major"`, the org policy would
# document an intention rather than enforce a bound, and nothing would tell you
# the difference — the config would still evaluate, still build, and quietly
# permit the upgrade the org forbade.
#
# So widening is a TYPED THROW naming both scopes and both values. TIER: this is
# eval-rejected (a Nix evaluation error), not truly-unrepresentable — the Nix
# module system cannot express "this value must be ordinally ≤ that value in a
# parent attrset". Stating that honestly rather than calling it unrepresentable.
#
# ── THE ALLOW VOCABULARY IS CLOSED AND ORDERED ────────────────────────────
#
#   none < patch < minor < major
#
# Closed so an unknown value is a throw rather than a silent pass, and ordered
# so "narrower" is decidable without a semver engine. A free-form string would
# make narrowing undecidable, which is the same defect as no policy at all.
#
# ── TAGS ARE DERIVED, WITH EXPLICIT OVERRIDES ─────────────────────────────
#
# `tagsOf` is supplied by the caller — this letter does not decide what a "gpu
# repo" is, because that is fleet DATA, not build ALGEBRA. The intended shape is
# derivation-first (a repo is `gpu` because its deps mention wgpu) with typed
# add/remove for what derivation cannot see. Membership that is hand-listed
# drifts; membership that is purely derived cannot express an exception. Both,
# with a stated precedence, is the honest answer.
#
# ── PROVENANCE IS MANDATORY, MATCHING THE REST OF THIS MODULE ─────────────
#
# Every scope carries a `reason`. `iroha.overlay` already refuses a fix without
# one; a policy without one is worse, because it governs many repos at once.
# The resolved value carries a `provenance` list naming every scope that
# contributed, so "why does mado get this overlay?" is a data query.
#
# EXPORTS (pure { lib }, zero pkgs):
#
#   mkOverlayPolicy :: {
#     org   ? { overlays ? [], pins ? {}, reason },
#     tags  ? attrsOf { overlays ? [], pins ? {}, reason },
#     repos ? attrsOf { overlays ? [], pins ? {}, reason },
#     tagsOf ? (repoName -> [ tagName ]),
#     knownOverlays ? null,   — when a list, an unknown overlay name throws
#   } -> {
#     for :: repoName -> {
#       overlays   :: [ str ];      — union, org-first, de-duplicated
#       pins       :: attrsOf pin;  — narrowed
#       provenance :: [ { scope, name, reason } ];
#       scopes     :: { org, tags :: [str], repo };   — the DENOMINATOR
#     };
#     registry = { org, tags, repos };   — queryable, ungated
#   }
{ lib }:
let
  inherit (lib) concatStringsSep;

  allowOrder = {
    none = 0;
    patch = 1;
    minor = 2;
    major = 3;
  };

  allowNames = concatStringsSep ", " (builtins.attrNames allowOrder);

  ordinalOf =
    ctx: value:
    allowOrder.${value} or (throw (
      "iroha.overlayPolicy: ${ctx} has allow = \"${value}\", which is not one of: ${allowNames}. "
      + "The vocabulary is CLOSED so an unknown value is a hard error rather than a silent pass."
    ));

  # A pin is `{ allow, ... }`; every other field is carried through untouched so
  # this letter does not need to know what a consumer stores alongside it.
  narrowPin =
    depName: parentCtx: parent: childCtx: child:
    let
      parentAllow = parent.allow or "major";
      childAllow = child.allow or parentAllow;
      p = ordinalOf parentCtx parentAllow;
      c = ordinalOf childCtx childAllow;
    in
    if c > p then
      throw (
        "iroha.overlayPolicy: ${childCtx} tries to WIDEN the pin on '${depName}' from "
        + "\"${parentAllow}\" (set by ${parentCtx}) to \"${childAllow}\". "
        + "Constraints narrow as scope narrows: a repo may tighten what the org allows, never "
        + "loosen it. If the wider range is genuinely correct, change it at ${parentCtx} — where "
        + "everyone governed by it can see the decision."
      )
    else
      parent // child // { allow = childAllow; };

  mergePins =
    parentCtx: parentPins: childCtx: childPins:
    let
      names = lib.unique ((builtins.attrNames parentPins) ++ (builtins.attrNames childPins));
    in
    lib.listToAttrs (
      map (
        depName:
        lib.nameValuePair depName (
          if (parentPins ? ${depName}) && (childPins ? ${depName}) then
            narrowPin depName parentCtx parentPins.${depName} childCtx childPins.${depName}
          else if parentPins ? ${depName} then
            parentPins.${depName}
          else
            childPins.${depName}
        )
      ) names
    );

  requireReason =
    ctx: spec:
    if (spec.reason or "") == "" then
      throw (
        "iroha.overlayPolicy: ${ctx} has no `reason`. Provenance is mandatory here for the same "
        + "reason iroha.overlay refuses a fix without one, only more so: a policy governs many "
        + "repos at once, so an unexplained one is unexplained everywhere."
      )
    else
      spec;

  checkOverlays =
    ctx: knownOverlays: names:
    if knownOverlays == null then
      names
    else
      let
        unknown = builtins.filter (n: !(builtins.elem n knownOverlays)) names;
      in
      if unknown == [ ] then
        names
      else
        throw (
          "iroha.overlayPolicy: ${ctx} names overlay(s) that do not exist: "
          + "${concatStringsSep ", " unknown}. Known: ${concatStringsSep ", " knownOverlays}. "
          + "A policy that silently grants a nonexistent overlay reads as coverage it does not have."
        );

  emptyScope = {
    overlays = [ ];
    pins = { };
    reason = null;
  };
in
{
  mkOverlayPolicy =
    {
      org ? null,
      tags ? { },
      repos ? { },
      tagsOf ? (_: [ ]),
      knownOverlays ? null,
    }:
    let
      orgSpec = if org == null then emptyScope else requireReason "the org scope" org;
      tagSpecs = lib.mapAttrs (n: requireReason "tag '${n}'") tags;
      repoSpecs = lib.mapAttrs (n: requireReason "repo '${n}'") repos;

      forRepo =
        repoName:
        let
          repoTags = builtins.filter (t: tagSpecs ? ${t}) (tagsOf repoName);
          repoSpec = repoSpecs.${repoName} or emptyScope;

          # SELECTION: union, org first so the reading order matches precedence.
          selected =
            (checkOverlays "the org scope" knownOverlays (orgSpec.overlays or [ ]))
            ++ builtins.concatMap (
              t: checkOverlays "tag '${t}'" knownOverlays (tagSpecs.${t}.overlays or [ ])
            ) repoTags
            ++ checkOverlays "repo '${repoName}'" knownOverlays (repoSpec.overlays or [ ]);

          # CONSTRAINT: fold narrowing through the same precedence order, so the
          # error names the nearest widening scope rather than a merged blob.
          # The accumulator carries BOTH the merged pins and the context that
          # produced them, because the error message must name the nearest
          # widening scope — "tag 'gpu' tries to widen", not "something above
          # you". `mergePins` returns pins alone, so the fold rebuilds the pair
          # each step; reducing straight over its return value silently changes
          # the accumulator's TYPE after the first tag, which is exactly the bug
          # the tests caught here.
          afterTags =
            builtins.foldl'
              (acc: t: {
                ctx = "tag '${t}'";
                pins = mergePins acc.ctx acc.pins "tag '${t}'" (tagSpecs.${t}.pins or { });
              })
              {
                ctx = "the org scope";
                pins = orgSpec.pins or { };
              }
              repoTags;

          finalPins = mergePins afterTags.ctx afterTags.pins "repo '${repoName}'" (repoSpec.pins or { });

          provenance =
            (lib.optional (orgSpec.reason != null) {
              scope = "org";
              name = "org";
              reason = orgSpec.reason;
            })
            ++ map (t: {
              scope = "tag";
              name = t;
              reason = tagSpecs.${t}.reason;
            }) repoTags
            ++ lib.optional (repoSpecs ? ${repoName}) {
              scope = "repo";
              name = repoName;
              reason = repoSpecs.${repoName}.reason;
            };
        in
        {
          overlays = lib.unique selected;
          pins = finalPins;
          inherit provenance;
          # The DENOMINATOR, carried inside the result: a caller can tell
          # "governed by org+2 tags" from "governed by nothing", which a bare
          # overlay list cannot express. Without this, a repo that matched no
          # policy at all looks identical to one deliberately granted nothing.
          scopes = {
            org = orgSpec.reason != null;
            tags = repoTags;
            repo = repoSpecs ? ${repoName};
          };
        };
    in
    {
      for = forRepo;
      registry = {
        org = orgSpec;
        tags = tagSpecs;
        repos = repoSpecs;
      };
    };
}
