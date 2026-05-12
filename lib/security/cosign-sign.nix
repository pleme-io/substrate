# Cosign keyless signing wrapper.
#
# Signs OCI images via Sigstore Fulcio (short-lived cert from OIDC
# identity) + Rekor (transparency log). No long-lived signing keys to
# rotate. The signing artifact is uploaded to the same registry as a
# co-located `<image>.sig` reference, plus a Rekor inclusion proof.
#
# FedRAMP-High control mapping:
#   SR-11 (component authenticity)
#   SI-7  (software integrity)
#
# Usage (from a release script):
#   ${(mkCosignSignApp pkgs { imageRef = "ghcr.io/..."; }).program}
#
# Requires at runtime:
#   - COSIGN_EXPERIMENTAL=1 (keyless requires this until cosign 2.x)
#   - OIDC identity token (GitHub Actions ID token, gcloud, etc.)
#   - Network access to fulcio.sigstore.dev + rekor.sigstore.dev
{ pkgs }:
{
  # Sign a single image reference (use after the image is pushed).
  #
  # Args:
  #   imageRef    — full image reference WITH digest preferred
  #                 (e.g. "ghcr.io/akeylesslabs/akeyless-auth@sha256:abc")
  #   keyless     — use Fulcio + Rekor (default: true)
  #   identityToken — optional path to identity token file
  mkCosignSignApp = {
    imageRef,
    keyless ? true,
    identityToken ? null,
  }: pkgs.writeShellScript "cosign-sign" ''
    set -euo pipefail
    export PATH="${pkgs.cosign}/bin:$PATH"
    export COSIGN_EXPERIMENTAL=1
    ${if keyless then ''
      ${if identityToken != null then ''
        cosign sign --yes --identity-token "$(cat ${identityToken})" "${imageRef}"
      '' else ''
        # Falls through to ambient OIDC (GitHub Actions, gcloud, etc.)
        cosign sign --yes "${imageRef}"
      ''}
    '' else ''
      # Keyed mode — operator supplies $COSIGN_KEY + $COSIGN_PASSWORD.
      : "''${COSIGN_KEY:?set COSIGN_KEY to a private key path}"
      cosign sign --yes --key "$COSIGN_KEY" "${imageRef}"
    ''}
  '';

  # Verify a signature exists for an image reference (used in chart
  # admission gating or release post-checks).
  mkCosignVerifyApp = {
    imageRef,
    expectedIdentityRegex ? null,
    expectedIssuer ? null,
  }: pkgs.writeShellScript "cosign-verify" ''
    set -euo pipefail
    export PATH="${pkgs.cosign}/bin:$PATH"
    export COSIGN_EXPERIMENTAL=1
    cosign verify \
      ${if expectedIdentityRegex != null then ''--certificate-identity-regexp="${expectedIdentityRegex}"'' else ""} \
      ${if expectedIssuer != null then ''--certificate-oidc-issuer="${expectedIssuer}"'' else ""} \
      "${imageRef}"
  '';
}
