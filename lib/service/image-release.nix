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
# `ociPush`: substrate's oci-push (doca) derivation, exported to forge as
# DOCA_BIN. REQUIRED IN PRACTICE since forge's image-release path moved off
# skopeo -- forge resolves DOCA_BIN, else a bare `oci-push` on PATH, and nothing
# put one there. Threading it closes a live break: converting forge's
# image_release.rs to doca without also updating this provider left
# `nix run .#<release-app>` looking for a binary no caller supplied.
#
# Optional (`? null`) so an existing consumer that has no fenix to build it with
# still evaluates. When it IS null the app runs without DOCA_BIN and forge fails
# LOUDLY, naming both the env var and the substrate attr that provides it -- an
# honest miss, not a silent one.
#
# SKOPEO_BIN below is retained per MODULARIZE-DON'T-DELETE: forge's image-release
# no longer reads it, but other forge subcommands still resolve it, and this app
# is not the right place to decide that for them.
{ pkgs, forgeCmd ? "forge", ociPush ? null }:

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
    # Pre-push loader verification (default on). forge gates each image's
    # declared arch against the tag it is pushed under — refusing a wrong-arch
    # binary at the gate instead of shipping it to `exec format error`. Set
    # false (per-app) to bypass; emits `--no-verify-elf` to forge.
    verifyElf ? true,
  }: let
    check = import ../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "name" name)
      (check.str "registry" registry)
      (check.list "systems" systems)
    ];

    # Resolve image derivation paths at Nix eval time for forge to use
    imageArgs = builtins.concatStringsSep " " (map (sys: let
      image = mkImage sys;
      arch = archTag.${sys};
    in "--${arch}-image ${image}") systems);
  in {
    type = "app";
    program = toString (pkgs.writeShellScript "release-${name}" ''
      set -euo pipefail
      ${pkgs.lib.optionalString (ociPush != null) ''export DOCA_BIN="${ociPush}/bin/oci-push"''}
      # SKOPEO_BIN export REMOVED 2026-08-01: dead, and it cost a closure.
      # forge's only SKOPEO_BIN reader is `cli/src/tools.rs::get_tool_path`,
      # which derives `{TOOL}_BIN` from a tool name — and that function has
      # ZERO production callers: `mod tools;` is declared (main.rs:68) but
      # every `tools::` reference in the crate is `commands::developer_tools::`,
      # a DIFFERENT module that merely shares the substring. The live push
      # paths (commands/push.rs, commands/image_release.rs) resolve DOCA_BIN
      # and fall back to `oci-push` on PATH; every remaining `skopeo` in them
      # is a migration comment, not a call. So this line interpolated
      # `pkgs.skopeo` into the closure of EVERY mkImageReleaseApp consumer to
      # set a variable nothing reads. Same measurement, and same conclusion,
      # as lib/util/config.nix's 2026-08-01 removal of skopeo from the default
      # runtime tool set. `runtimeTools.skopeo` stays declared there
      # (★★ MODULARIZE, DON'T DELETE); what is removed here is the unread
      # export, not the ability to opt back in.
      export REGCTL_BIN="${pkgs.regclient}/bin/regctl"
      exec ${forgeCmd} image-release \
        --name "${name}" \
        --registry "${registry}" \
        ${imageArgs} ${pkgs.lib.optionalString (!verifyElf) "--no-verify-elf"}
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
