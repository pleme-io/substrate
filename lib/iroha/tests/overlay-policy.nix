# iroha.overlayPolicy — eval tests.
#
# The load-bearing case is NEGATIVE: a repo widening an org constraint must
# THROW. A suite that only proves composition works would pass just as happily
# against a policy engine that silently let every repo do as it liked, which is
# the failure mode this letter exists to prevent.
{ lib }:
let
  iroha = import ../default.nix { inherit lib; };
  inherit (iroha) mkOverlayPolicy;

  # ★ deepSeq is load-bearing, and this was measured rather than reasoned.
  #
  # `builtins.tryEval` forces only to WHNF. Written as
  # `tryEval expr`, `(policy.for "bad").pins` evaluates to an ATTRSET and
  # succeeds — the throw lives in a VALUE inside it and is never forced. The
  # first version of this file did exactly that and the widening test reported
  # `false`: the negative case silently checked nothing, which is precisely the
  # failure mode a negative test exists to prevent.
  #
  # `deepSeq` forces the whole structure, so a throw anywhere inside it is
  # caught. Any Nix negative test over a lazily-built value needs this.
  throws = expr: !(builtins.tryEval (builtins.deepSeq expr expr)).success;

  policy = mkOverlayPolicy {
    org = {
      overlays = [ "rust-toolchain" ];
      pins.nixpkgs = {
        channel = "25.11";
        allow = "patch";
      };
      reason = "fleet-wide toolchain and a patch-only nixpkgs ceiling";
    };
    tags.gpu = {
      overlays = [ "wgpu-quirk-fix" ];
      reason = "GPU repos need the portable_atomic quirk fix";
    };
    repos.mado = {
      overlays = [ "local-metal-patch" ];
      reason = "mado carries a Metal-specific patch nothing else needs";
    };
    repos.sui = {
      # NARROWING is allowed: patch -> none is tighter.
      pins.nixpkgs.allow = "none";
      reason = "sui pins hard: byte-parity work cannot tolerate drift";
    };
    tagsOf = repo: if repo == "mado" then [ "gpu" ] else [ ];
    knownOverlays = [
      "rust-toolchain"
      "wgpu-quirk-fix"
      "local-metal-patch"
    ];
  };

  mado = policy.for "mado";
  sui = policy.for "sui";
  ungoverned = policy.for "some-random-repo";

  # A repo that WIDENS: org says patch, this says major.
  widening = mkOverlayPolicy {
    org = {
      pins.nixpkgs.allow = "patch";
      reason = "org ceiling";
    };
    repos.bad = {
      pins.nixpkgs.allow = "major";
      reason = "tries to widen";
    };
  };

  # A tag that widens is equally illegal — the rule is about SCOPE ORDER, not
  # about repos specifically.
  wideningTag = mkOverlayPolicy {
    org = {
      pins.nixpkgs.allow = "none";
      reason = "org ceiling";
    };
    tags.loose = {
      pins.nixpkgs.allow = "minor";
      reason = "tries to widen";
    };
    tagsOf = _: [ "loose" ];
  };

  unknownOverlay = mkOverlayPolicy {
    org = {
      overlays = [ "does-not-exist" ];
      reason = "typo";
    };
    knownOverlays = [ "rust-toolchain" ];
  };

  noReason = mkOverlayPolicy {
    org = {
      overlays = [ ];
    };
  };

  badAllow = mkOverlayPolicy {
    org = {
      pins.nixpkgs.allow = "whenever";
      reason = "not in the closed vocabulary";
    };
    repos.x = {
      pins.nixpkgs.allow = "none";
      reason = "forces the parent to be read";
    };
  };
in
{
  # ── SELECTION composes by union, in precedence order ────────────────────
  "selection unions org + tag + repo" =
    mado.overlays == [
      "rust-toolchain"
      "wgpu-quirk-fix"
      "local-metal-patch"
    ];

  "a repo with no tags gets only the org grant" = sui.overlays == [ "rust-toolchain" ];

  "an ungoverned repo still gets the org floor" = ungoverned.overlays == [ "rust-toolchain" ];

  # ── The DENOMINATOR: governed-by-nothing is distinguishable ─────────────
  "scopes report which policies applied" =
    mado.scopes.tags == [ "gpu" ] && mado.scopes.repo && mado.scopes.org;

  "an ungoverned repo reports no tag/repo scope" =
    ungoverned.scopes.tags == [ ] && !ungoverned.scopes.repo;

  # ── CONSTRAINT narrows, and carries the parent's other fields ──────────
  "a repo may TIGHTEN an org pin" = sui.pins.nixpkgs.allow == "none";

  "narrowing preserves fields the child did not mention" = sui.pins.nixpkgs.channel == "25.11";

  "an untouched pin passes through" = mado.pins.nixpkgs.allow == "patch";

  # ── THE LOAD-BEARING NEGATIVES ─────────────────────────────────────────
  "a repo may NOT widen an org pin" = throws (widening.for "bad").pins;

  "a TAG may not widen either" = throws (wideningTag.for "anything").pins;

  "an unknown overlay name is rejected" = throws (unknownOverlay.for "anything").overlays;

  "a scope without a reason is rejected" = throws noReason.registry;

  "an allow outside the closed vocabulary is rejected" = throws (badAllow.for "x").pins;

  # ── Provenance is queryable ────────────────────────────────────────────
  "provenance names every contributing scope" =
    (builtins.length mado.provenance == 3) && (builtins.elem "gpu" (map (p: p.name) mado.provenance));
}
