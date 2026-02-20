# Generic multi-arch OCI image release helpers.
#
# Builds images for x86_64-linux and aarch64-linux, pushes to GHCR with
# standard tag convention: <arch>-<sha>, <arch>-latest
#
# Usage in consumer flake.nix:
#   release = substrateLib.mkImageReleaseApp {
#     name = "my-service";
#     registry = "ghcr.io/myorg/my-service";
#     mkImage = system: mkImage system;
#   };
#
# Usage for multiple images:
#   apps = substrateLib.mkImageReleaseApps {
#     debug = { registry = "ghcr.io/myorg/my-debug"; mkImage = system: mkProfile "debug" system; };
#     k8s   = { registry = "ghcr.io/myorg/my-k8s";   mkImage = system: mkProfile "k8s" system; };
#   };
#   # Produces: release:debug, release:k8s, release (all)
{ pkgs }:

let
  linuxSystems = ["x86_64-linux" "aarch64-linux"];

  archTag = {
    "x86_64-linux" = "amd64";
    "aarch64-linux" = "arm64";
  };
in rec {
  # Create a release app that pushes multi-arch images to a registry.
  #
  # Parameters:
  #   name     - release script name (e.g. "my-agent")
  #   registry - full registry URL (e.g. "ghcr.io/myorg/my-agent")
  #   mkImage  - function: system -> image derivation (docker-archive format)
  #   systems  - list of target Linux systems (default: amd64 + arm64)
  #
  # Tags pushed per architecture:
  #   <arch>-<git-short-sha>  (immutable, commit-specific)
  #   <arch>-latest           (floating, most recent release)
  mkImageReleaseApp = {
    name,
    registry,
    mkImage,
    systems ? linuxSystems,
  }: let
    pushArch = targetSystem: let
      image = mkImage targetSystem;
      arch = archTag.${targetSystem};
    in ''
      echo "==> Pushing ${registry}:${arch}-$SHORT_SHA"
      ${pkgs.skopeo}/bin/skopeo copy docker-archive:${image} docker://${registry}:${arch}-$SHORT_SHA
      ${pkgs.skopeo}/bin/skopeo copy docker-archive:${image} docker://${registry}:${arch}-latest
    '';
  in {
    type = "app";
    program = toString (pkgs.writeShellScript "release-${name}" ''
      set -euo pipefail
      SHORT_SHA=$(${pkgs.git}/bin/git rev-parse --short HEAD)
      echo "==> Releasing ${registry}"
      ${builtins.concatStringsSep "\n" (map pushArch systems)}
      echo "==> Done: ${registry}"
    '');
  };

  # Create release apps for multiple images at once.
  #
  # Parameters:
  #   images - attrset of { <name> = { registry, mkImage, systems? }; }
  #
  # Returns attrset:
  #   "release:<name>" - per-image release app
  #   "release"        - release all images sequentially
  mkImageReleaseApps = images: let
    names = builtins.attrNames images;

    perImage = builtins.listToAttrs (map (name: {
      name = "release:${name}";
      value = mkImageReleaseApp ({ inherit name; } // images.${name});
    }) names);

    allScript = pkgs.writeShellScript "release-all" ''
      set -euo pipefail
      ${builtins.concatStringsSep "\n" (map (name: let
        app = mkImageReleaseApp ({ inherit name; } // images.${name});
      in "${app.program}") names)}
    '';
  in perImage // {
    release = {
      type = "app";
      program = toString allScript;
    };
  };
}
