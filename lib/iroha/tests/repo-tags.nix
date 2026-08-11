# iroha.repoTags — eval tests.
#
# The cases that matter are the ones a naive implementation gets wrong:
# precedence (exclude beats include), a derived repo joining WITHOUT being
# listed, and the stats split that reveals a predicate which is not actually
# deriving anything.
{ lib }:
let
  iroha = import ../default.nix { inherit lib; };
  inherit (iroha) mkRepoTags mkOverlayPolicy;

  # deepSeq, not bare tryEval: a throw inside a lazily-built attrset is never
  # forced by WHNF, so a negative test written without it silently checks
  # nothing. Learned the hard way in tests/overlay-policy.nix.
  throws = expr: !(builtins.tryEval (builtins.deepSeq expr expr)).success;

  repos = [
    "mado"
    "hibikine"
    "codesearch"
    "legacy-gpu-thing"
    "sui"
  ];

  facts = {
    mado.deps = [
      "wgpu"
      "winit"
    ];
    hibikine.deps = [ "wgpu" ];
    codesearch.deps = [ "tantivy" ];
    legacy-gpu-thing.deps = [ "wgpu" ];
    sui.deps = [ "serde" ];
  };

  t = mkRepoTags {
    inherit repos facts;
    tags = {
      gpu = {
        derive = f: builtins.elem "wgpu" (f.deps or [ ]);
        # legacy-gpu-thing DERIVES as gpu but must not receive the overlays:
        # the exception a purely-derived design cannot express.
        exclude = [ "legacy-gpu-thing" ];
        reason = "GPU repos need the wgpu quirk fix";
      };
      pinned = {
        # No derive at all — membership is entirely explicit. `stats` must make
        # that visible rather than letting it pass as a working rule.
        include = [ "sui" ];
        reason = "sui pins hard for byte-parity work";
      };
    };
  };

  noReason = mkRepoTags {
    inherit repos;
    tags.oops.derive = _: true;
  };

  unknownRepo = mkRepoTags {
    inherit repos;
    tags.typo = {
      include = [ "does-not-exist" ];
      reason = "names a repo that is not in the universe";
    };
  };

  # The point of the whole letter: it feeds mkOverlayPolicy directly.
  policy = mkOverlayPolicy {
    org = {
      overlays = [ "rust-toolchain" ];
      reason = "fleet baseline";
    };
    tags.gpu = {
      overlays = [ "wgpu-quirk-fix" ];
      reason = "GPU group";
    };
    tagsOf = t.tagsOf;
  };
in
{
  # ── DERIVATION: membership without being listed ────────────────────────
  "a repo joins a tag by DERIVATION, unlisted" = builtins.elem "hibikine" t.members.gpu;

  "a non-matching repo does not join" = !(builtins.elem "codesearch" t.members.gpu);

  # ── PRECEDENCE: exclude beats derivation ───────────────────────────────
  "exclude removes a repo that DERIVES into the tag" =
    !(builtins.elem "legacy-gpu-thing" t.members.gpu);

  "explain names WHY a repo holds a tag" = (t.explain "mado").gpu == "derived";

  "explain reports an explicit include as such" = (t.explain "sui").pinned == "included";

  # explain REPORTS the exclusion rather than hiding it: "deliberately excluded"
  # and "never matched" are opposite facts, and only the first is a decision
  # somebody has to be able to defend. Membership itself is asserted separately
  # above, so this cannot mask a repo wrongly receiving the tag.
  "an excluded repo is reported AS excluded, not omitted" =
    (t.explain "legacy-gpu-thing").gpu == "excluded";

  "a repo that never matched reports nothing for that tag" = !((t.explain "codesearch") ? gpu);

  # ── THE DENOMINATOR: a tag that derives nothing is visible ─────────────
  "stats split derived vs included" = t.stats.gpu.derived == 2 && t.stats.gpu.excluded == 1;

  "a tag with NO derivation shows derived=0 — a predicate doing nothing" =
    t.stats.pinned.derived == 0 && t.stats.pinned.included == 1;

  "stats carry the universe size" = t.stats.gpu.universe == 5;

  # ── NEGATIVES ──────────────────────────────────────────────────────────
  "a tag without a reason is rejected" = throws noReason.members;

  "an override naming an unknown repo is rejected" = throws unknownRepo.members;

  # ── IT ACTUALLY FEEDS THE POLICY ───────────────────────────────────────
  "derived tags drive overlay selection end-to-end" =
    (policy.for "mado").overlays == [
      "rust-toolchain"
      "wgpu-quirk-fix"
    ];

  "an excluded repo gets only the org floor" =
    (policy.for "legacy-gpu-thing").overlays == [ "rust-toolchain" ];
}
