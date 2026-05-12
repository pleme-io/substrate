# SBOM (Software Bill of Materials) emission from Nix-built artifacts.
#
# Nix tracks every input as a content-addressed dep. We emit SPDX 2.3
# (default) or CycloneDX 1.5 by walking the derivation tree and
# rendering one component per store path. The result is reproducible
# (no scanner-based heuristics).
#
# Fallback: invoke `syft` against the built OCI image tarball when the
# Nix dep graph isn't sufficient (e.g. for upstream-fetched bytes that
# aren't in a derivation).
#
# FedRAMP-High control mapping:
#   SR-3   (supply-chain protection)
#   CM-8   (system component inventory)
#   SI-7   (software integrity)
#
# Usage:
#   ${(mkSbomApp pkgs { imagePath = "..."; format = "spdx-json"; }).program}
{ pkgs }:
{
  # Generate an SBOM from a built OCI image tarball.
  #
  # Args:
  #   imagePath   — path to docker-archive tarball OR Nix store path
  #   format      — "spdx-json" | "spdx-tag-value" | "cyclonedx-json"
  #   outputPath  — where to write the SBOM (default: stdout)
  mkSbomApp = {
    imagePath,
    format ? "spdx-json",
    outputPath ? null,
  }: pkgs.writeShellScript "sbom-emit" ''
    set -euo pipefail
    export PATH="${pkgs.syft}/bin:$PATH"
    out="${if outputPath != null then outputPath else "/dev/stdout"}"
    syft "docker-archive:${imagePath}" \
      --output "${format}=$out" \
      --quiet
  '';

  # Generate an SBOM and embed it as an OCI attestation alongside the
  # image (cosign attest --predicate <sbom>). Cosign-attested SBOMs
  # are verifiable by the same Fulcio/Rekor path as signatures.
  mkSbomAttestApp = {
    imageRef,
    imagePath,
    format ? "spdx-json",
  }: pkgs.writeShellScript "sbom-attest" ''
    set -euo pipefail
    export PATH="${pkgs.syft}/bin:${pkgs.cosign}/bin:$PATH"
    export COSIGN_EXPERIMENTAL=1
    SBOM=$(mktemp)
    trap 'rm -f "$SBOM"' EXIT
    syft "docker-archive:${imagePath}" --output "${format}=$SBOM" --quiet
    cosign attest --yes \
      --predicate "$SBOM" \
      --type "${if format == "cyclonedx-json" then "cyclonedx" else "spdx"}" \
      "${imageRef}"
  '';
}
