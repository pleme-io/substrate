# Platform Service Builder - Generic builder for platform infrastructure services
# Reusable abstraction for platform infrastructure services
#
# This module provides parameterized functions that:
# - Build Rust binaries from Cargo.nix using crate2nix
# - Create Docker images with proper OCI labels
# - Generate push/regen apps using forge
#
# Usage:
#   mkPlatformService {
#     name = "my-service";
#     description = "My platform service";
#     src = ./pkgs/platform/my-service;
#     githubOrg = "myorg";
#     ports = { health = 8080; };
#   }
{ pkgs, crate2nix, forgeCmd, defaultGhcrToken }:

let
  # Hardened by default (Pillar 8 / oci/hardened-base.nix). `mkDockerImage`
  # below builds on `hardened.mkPackageImage` directly. Previously this
  # called `dockerTools.buildLayeredImage { fromImage = base; ... }` by
  # hand because `mkPackageImage` had no way to merge caller-supplied OCI
  # labels over its own fixed default set -- that gap is closed (2026-07-18:
  # `mkPackageImage`/`mkVendorRewrap` both grew a `labels ? {}` param, merged
  # OVER the builder's own `io.pleme.rebuild.*`/`org.opencontainers.image.*`
  # defaults, caller key wins), so this file's own `extraLabels` passthrough
  # now threads straight through as that `labels` param.
  hardened = import ../build/oci/hardened-base.nix { inherit pkgs; };
in rec {
  # Build a Rust binary from Cargo.nix using crate2nix
  # Returns null if Cargo.nix doesn't exist
  buildFromCargoNix = { name, cargoNix, crateOverrides ? {} }:
    if builtins.pathExists cargoNix then
      let
        project = import cargoNix {
          inherit pkgs;
          defaultCrateOverrides = pkgs.defaultCrateOverrides // crateOverrides;
        };
      in project.rootCrate.build
    else null;

  # Create a Docker image from a built binary via hardened.mkPackageImage
  # (distroless-glibc base; see the top-of-file comment for why this is no
  # longer a direct dockerTools.buildLayeredImage call).
  mkDockerImage = {
    name,
    binary,
    githubOrg,  # Required: GitHub org (e.g., "myorg")
    registry ? "ghcr.io/${githubOrg}/${name}",
    tag ? "latest",
    ports ? { health = 8080; },
    env ? [],
    description ? "",
    extraLabels ? {},
  }: hardened.mkPackageImage {
    service = name;
    base = hardened.bases.distroless-glibc;
    package = binary;
    publishName = registry;
    publishTag = tag;
    entrypoint = [ "${binary}/bin/${name}" ];
    env = [
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
    ] ++ env;
    exposedPorts = builtins.listToAttrs (
      builtins.map (p: { name = "${toString p}/tcp"; value = {}; })
        (pkgs.lib.unique (builtins.attrValues ports))
    );
    # user defaults to hardened's nonrootUid:nonrootGid (matches the exact
    # value this file used to hardcode by hand); workdir/cmd/volumes/
    # writablePaths all default to the same no-op shape the old bare
    # buildLayeredImage call had (no WorkingDir/Cmd/Volumes keys, no
    # fakeRootCommands/enableFakechroot).
    labels = {
      "org.opencontainers.image.title" = name;
      "org.opencontainers.image.description" = description;
      "org.opencontainers.image.source" = "https://github.com/${githubOrg}";
      "org.opencontainers.image.vendor" = githubOrg;
    } // extraLabels;
  };

  # Create a push app using forge push command
  mkPushApp = { name, image, registry }:
    {
      type = "app";
      program = toString (pkgs.writeShellScript "push-${name}" ''
        set -euo pipefail
        ${if defaultGhcrToken != "" then ''export GITHUB_TOKEN="${defaultGhcrToken}"
        export GHCR_TOKEN="${defaultGhcrToken}"'' else ''export GITHUB_TOKEN="''${GITHUB_TOKEN:-''${GHCR_TOKEN:-$(cat "$HOME/.config/github/token" 2>/dev/null || true)}}"
        export GHCR_TOKEN="$GITHUB_TOKEN"''}
        exec ${forgeCmd} push \
          --image-path "${image}" \
          --registry "${registry}" \
          --auto-tags \
          --retries 3
      '');
    };

  # Create a regen app using forge bootstrap regenerate
  mkRegenApp = { name, serviceDir, cargo, crate2nixBin }:
    {
      type = "app";
      program = toString (pkgs.writeShellScript "regen-${name}" ''
        export SERVICE_DIR="${serviceDir}"
        export CARGO="${cargo}"
        export CRATE2NIX="${crate2nixBin}"
        exec ${forgeCmd} bootstrap regenerate
      '');
    };

  # Main function: Create a complete platform service with binary, image, and apps
  # Returns: { binary, image, packages, apps }
  mkPlatformService = {
    name,
    src,
    description ? "",
    cargoNix ? src + "/Cargo.nix",
    githubOrg,  # Required: GitHub org (e.g., "myorg")
    registry ? "ghcr.io/${githubOrg}/${name}",
    ports ? { health = 8080; },
    env ? [
      "RUST_LOG=info,${name}=debug"
      "LOG_FORMAT=json"
      "HEALTH_ADDR=0.0.0.0:${toString (ports.health or 8080)}"
    ],
    crateOverrides ? {},
    extraLabels ? {},
  }: let
    check = import ../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "name" name)
      (check.nonEmptyStr "githubOrg" githubOrg)
      (check.list "env" env)
      (check.attrs "crateOverrides" crateOverrides)
      (check.attrs "extraLabels" extraLabels)
    ];

    binary = buildFromCargoNix {
      inherit name cargoNix crateOverrides;
    };

    image = if binary != null then mkDockerImage {
      inherit name binary githubOrg registry ports env description extraLabels;
    } else null;

    serviceDir = toString src;

  in {
    inherit binary image;

    # Packages to export
    packages = if binary != null then {
      "${name}" = binary;
      "${name}-image" = image;
    } else {};

    # Apps to export
    apps = {
      "push:platform:${name}" = if image != null then mkPushApp {
        inherit name image registry;
      } else {
        type = "app";
        program = toString (pkgs.writeShellScript "push-${name}-error" ''
          echo "Error: ${name} Cargo.nix not found. Run regen:platform:${name} first."
          exit 1
        '');
      };

      "regen:platform:${name}" = mkRegenApp {
        inherit name serviceDir;
        cargo = "${pkgs.fenixCargo or pkgs.cargo}/bin/cargo";
        crate2nixBin = "${crate2nix}/bin/crate2nix";
      };
    };
  };
}
