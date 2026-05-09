# ============================================================================
# DOCKER HELPERS - Shared Docker image building fragments
# ============================================================================
# Composable fragments for Docker image builders across web-docker.nix,
# ruby-build.nix, wasm-build.nix, and crate2nix-builders.nix.
#
# Internal helper — not exported from lib/default.nix.
{
  # fakeRootCommands for a web user (101:101) — used by web-docker.nix, wasm-build.nix
  mkWebUserSetup = ''
    mkdir -p etc
    echo 'root:x:0:0:System administrator:/root:/bin/sh' > etc/passwd
    echo 'web:x:101:101:web:/app:/sbin/nologin' >> etc/passwd
    echo 'root:x:0:' > etc/group
    echo 'web:x:101:' >> etc/group
  '';

  # extraCommands for an app user (1000:1000) — used by ruby-build.nix
  mkAppUserSetup = ''
    mkdir -p etc
    echo "app:x:1000:1000::/:/bin/false" > etc/passwd
    echo "app:x:1000:" > etc/group
  '';

  # extraCommands for standard temp/log directories
  mkTmpDirs = ''
    mkdir -p var/log run tmp
    chmod -R 777 var/log run tmp
  '';

  # SSL_CERT_FILE env var string — used in Docker image Env lists
  mkSslEnv = pkgs: "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

  # Base container contents for services that need TLS + basic shell
  mkBaseContents = pkgs: with pkgs; [ cacert busybox ];

  # ★ Phase E2 (Pillar 12 — generation over composition).
  # OCI Image Spec v1.1 reserved annotations. The FedRAMP-High image
  # pack (provas v3) requires the org.opencontainers.image.* keys be
  # present + non-empty + parseable on every published image, not
  # just Rust services. Centralized here so every builder
  # (mkCrate2nixDockerImage, mkNodeDockerImage, …) emits the same
  # shape — single source of truth for fleet-wide annotations.
  #
  # Args:
  #   serviceName  — used for `title` + derives `source`/`url`/`documentation`.
  #                  Convention: matches the github.com/pleme-io/${serviceName}
  #                  repo URL. Operators publishing forks override via
  #                  callsite (this helper returns plain attrs).
  #   tag          — image tag → `version` annotation.
  #   description  — optional human description (defaults to a
  #                  substrate-built blurb when omitted).
  #
  # Returns: an attrset suitable for spreading into Docker `config.Labels`.
  # The Nix evaluator's strictness rejects empty strings on these keys
  # at the provas pack site, so all values are pre-validated non-empty.
  mkStandardLabels = {
    serviceName,
    tag,
    description ? null,
    fleetSourceUrl ? "https://github.com/pleme-io/${serviceName}",
  }: {
    "org.opencontainers.image.title" = serviceName;
    "org.opencontainers.image.description" =
      if description != null
      then description
      else "${serviceName} — pleme-io substrate-built service";
    "org.opencontainers.image.vendor" = "Pleme.io";
    "org.opencontainers.image.source" = fleetSourceUrl;
    "org.opencontainers.image.url" = fleetSourceUrl;
    "org.opencontainers.image.documentation" = "${fleetSourceUrl}#readme";
    "org.opencontainers.image.licenses" = "MIT";
    "org.opencontainers.image.version" = tag;
    # `revision` is the git commit; injected at release time via the
    # release pipeline (the substrate doesn't see git state during
    # the Nix build for hermeticity).
  };
}
