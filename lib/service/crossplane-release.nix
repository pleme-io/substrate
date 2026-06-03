# Generic Crossplane-package release helpers — the reuse layer over the typed
# `forge crossplane` verbs (function-release / configuration-release).
#
# Mirrors `mkImageReleaseApp` / `mkHelmAllApps`: the consumer flake gets a
# `nix run .#function-release -- <tag>` app in one line; the embedded runtime
# image is a Nix `dockerTools` derivation (Pillar 8 — no Dockerfile), handed to
# `crossplane xpkg build --embed-runtime-image-tarball` via forge.
#
# Usage in a consumer flake.nix:
#   apps.function-release = substrateLib.mkCrossplaneFunctionReleaseApp {
#     name         = "pitr-drill";
#     package      = "ghcr.io/pleme-io/function-pitr-drill";
#     runtimeImage = functionImage;       # a dockerTools.buildLayeredImage drv
#   };
#
#   apps.configuration-release = substrateLib.mkCrossplaneConfigurationReleaseApp {
#     name    = "pitr-drill";
#     package = "ghcr.io/pleme-io/configuration-pitr-drill";
#   };
#
# Both apps are linux-CI operations (the runtime image is a linux dockerTools
# build) — the same property mkImageReleaseApp has. Release happens in CI, not
# on a developer mac.
{ pkgs, forgeCmd ? "forge" }:

let
  check = import ../types/assertions.nix;
in rec {
  # A Function package (composition function): embed a Nix-built runtime image
  # into a Function xpkg + push to the registry.
  #
  #   name         - app/script name suffix (e.g. "pitr-drill")
  #   package      - full registry ref (e.g. "ghcr.io/pleme-io/function-pitr-drill")
  #   runtimeImage - the dockerTools image derivation whose entrypoint serves the
  #                  function-sdk-go gRPC server (/function)
  #   packageRoot  - dir holding package/crossplane.yaml (default "package")
  #   tag          - resolved at run time from $1 (the release tag)
  mkCrossplaneFunctionReleaseApp = {
    name,
    package,
    runtimeImage,
    packageRoot ? "package",
  }: let
    _ = check.all [
      (check.nonEmptyStr "name" name)
      (check.nonEmptyStr "package" package)
      (check.nonEmptyStr "packageRoot" packageRoot)
    ];
  in {
    type = "app";
    program = toString (pkgs.writeShellScript "crossplane-function-release-${name}" ''
      set -euo pipefail
      export PATH="${pkgs.crossplane-cli}/bin:${pkgs.gzip}/bin:$PATH"
      tag="''${1:?usage: function-release -- <tag>}"
      work="$(mktemp -d)"
      trap 'rm -rf "$work"' EXIT
      # dockerTools.buildLayeredImage emits a gzipped image tarball; crossplane's
      # --embed-runtime-image-tarball wants a plain docker-archive tar.
      gunzip -c "${runtimeImage}" > "$work/runtime.tar"
      exec ${forgeCmd} crossplane function-release \
        --package-root "${packageRoot}" \
        --runtime-image "$work/runtime.tar" \
        --package "${package}" \
        --tag "$tag"
    '');
  };

  # A Configuration package (XRD + Composition, pure YAML — no runtime image).
  mkCrossplaneConfigurationReleaseApp = {
    name,
    package,
    packageRoot ? "package",
  }: let
    _ = check.all [
      (check.nonEmptyStr "name" name)
      (check.nonEmptyStr "package" package)
      (check.nonEmptyStr "packageRoot" packageRoot)
    ];
  in {
    type = "app";
    program = toString (pkgs.writeShellScript "crossplane-configuration-release-${name}" ''
      set -euo pipefail
      export PATH="${pkgs.crossplane-cli}/bin:$PATH"
      tag="''${1:?usage: configuration-release -- <tag>}"
      exec ${forgeCmd} crossplane configuration-release \
        --package-root "${packageRoot}" \
        --package "${package}" \
        --tag "$tag"
    '');
  };
}
