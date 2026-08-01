# doca-env.nix — the ONE place that turns an `ociPush` argument into the
# `DOCA_BIN` export every forge push/image-release path needs.
#
# ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
# Seven substrate providers exec a forge push and must hand it DOCA_BIN. Each
# had hand-rolled the same line:
#
#   ${pkgs.lib.optionalString (ociPush != null) ''export DOCA_BIN="…"''}
#
# That shape has a silent failure mode. `ociPush ? null` is the DEFAULT in every
# one of those files, so when it is not threaded the `optionalString` renders to
# the empty string, the app builds perfectly, and forge falls back to a bare
# `oci-push` on PATH — a pleme-io binary that is ambient NOWHERE. The result is
# a green build that dies at push time on `oci-push: not found`, which is the
# exact defect `forge-tool-env-tests.nix` was written for after it had been
# hand-fixed SEVEN times across two days.
#
# ── WHY A CONDITIONAL EXPORT DEFEATS THE GATE THAT WATCHES IT ───────────────
# `forge-tool-env-tests.nix` asserts that a provider's text contains a real
# `DOCA_BIN=` assignment. The `optionalString` line CONTAINS one — as source
# text — whether or not it ever renders. So the gate passes on a provider whose
# export can never fire. Tightening that predicate against COMMENTS (done
# 2026-08-01) closed the prose hole and did NOT close this one: the difference
# between "mentions the variable" and "assigns the variable" is visible in the
# text, but the difference between "assigns it" and "assigns it under a
# condition that is always false" is NOT. It lives in the argument, not the
# file.
#
# The fix is therefore structural rather than a smarter regex: remove the
# representable state. `mkDocaExport` has no silent branch. Either it emits a
# real export, or it throws at EVAL with the construction that repairs it.
#
# TIER: eval-rejected. Stronger than a CI gate (which can be skipped, and is
# vacuous wherever Actions are disabled — 554 of 716 workflow-bearing pleme-io
# repos); weaker than truly-unrepresentable, because a Nix `throw` is not a
# compile error. Do not round it up.
{ lib }:

{
  # ociPush : the substrate oci-push (doca) derivation, or null
  # context : a human label naming the caller, quoted back in the throw
  mkDocaExport = { ociPush, context }:
    if ociPush == null
    then throw ("${context}: ociPush is null, so DOCA_BIN cannot be exported. "
              + "forge's push/image-release paths resolve DOCA_BIN, else a bare "
              + "`oci-push` on PATH — and oci-push is a pleme-io binary that is "
              + "ambient NOWHERE, so this app would have built cleanly and failed "
              + "at push time with `oci-push: not found`. Thread ociPush from "
              + "lib/default.nix (see `ociPushPkg`) into this module's arguments.")
    else ''export DOCA_BIN="${ociPush}/bin/oci-push"'';

  # For a module that legitimately has no push path under some configuration:
  # be explicit that the absence is intended, rather than defaulting to null and
  # letting the export silently vanish.
  mkDocaExportOptional = { ociPush, context, reason }:
    if ociPush == null
    then "# DOCA_BIN deliberately unset for ${context}: ${reason}"
    else ''export DOCA_BIN="${ociPush}/bin/oci-push"'';
}
