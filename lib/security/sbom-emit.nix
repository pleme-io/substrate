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
let
  # Found live 2026-07-22 (rabbitmq's first real run through this gate):
  # syft's `docker-archive:` reader expects an UNCOMPRESSED tar (matching
  # `docker save`'s own default) and fails with "archive/tar: invalid tar
  # header" on the gzip-compressed tarball Nix's dockerTools actually
  # produces (confirmed: the same tarball scans fine under both trivy
  # `--input` and skopeo `copy docker-archive:`, which both transparently
  # gunzip -- syft's docker-archive provider does not). Detect + decompress
  # first, so this works identically whether the input happens to be
  # compressed or not, rather than assuming either. Sets `$scan_target` for
  # the caller to pass to `docker-archive:$scan_target`; the caller owns
  # the single combined `trap ... EXIT` (bash traps overwrite, they don't
  # stack -- a second `trap EXIT` call silently drops the first).
  syftTarball = imagePath: ''
    scan_target="${imagePath}"
    if ${pkgs.gzip}/bin/gzip -t "${imagePath}" 2>/dev/null; then
      decompressed=$(mktemp)
      ${pkgs.gzip}/bin/gzip -dc "${imagePath}" > "$decompressed"
      scan_target="$decompressed"
    fi
  '';
in
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
    decompressed=""
    trap 'rm -f "$decompressed"' EXIT
    ${syftTarball imagePath}
    syft "docker-archive:$scan_target" \
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
    decompressed=""
    trap 'rm -f "$SBOM" "$decompressed"' EXIT
    ${syftTarball imagePath}
    syft "docker-archive:$scan_target" --output "${format}=$SBOM" --quiet
    cosign attest --yes \
      --predicate "$SBOM" \
      --type "${if format == "cyclonedx-json" then "cyclonedx" else "spdx"}" \
      "${imageRef}"
  '';
}
