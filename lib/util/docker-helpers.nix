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
  # ── ★ sourceRepo — the label GHCR LINKS A PACKAGE TO ITS REPO BY ──────
  # `org.opencontainers.image.source` is not decorative metadata. GHCR reads
  # it to associate a published package with a repository, and that
  # association is what lets a job's own GITHUB_TOKEN push to the package at
  # all. An unlinked package is also billed against the ORG's storage quota
  # rather than the repo's, which surfaces as "Artifact storage quota has been
  # hit" in repositories that published nothing.
  #
  # The historical default below derives the URL from the SERVICE NAME, which
  # is right only when a repo publishes exactly one artifact named after
  # itself. Measured 2026-08-22 over 14 real fleet package names: **6 correct,
  # 8 pointing at repositories that do not exist** — `hardened-vector`,
  # `hardened-clickhouse`, `sql-apply`, `charts`, `helm`, `cnpg-postgresql`,
  # `sarar-eyes`, `escuta-mysql-tap`. The split is structural, not random: the
  # 6 are repos publishing under their own name and the 8 are repos publishing
  # MANY artifacts (`hardened-images` alone accounts for ~45).
  #
  # So neither one-line move is available: keeping the guess emits dead links,
  # and switching to the org-root value that `oci/hardened-base.nix` defaults
  # to would break the 6 that currently work.
  #
  # ★ AND IT DOES NOT NEED WORKFLOW STATE. A repository knows its own name at
  # AUTHOR time — `hardened-images/lib/mk-hardened-image-set.nix` has always
  # simply written its own, correctly, for all ~45 of its images. So this is a
  # static per-repo declaration, hermetic, with no `--impure` and no
  # `GITHUB_REPOSITORY` plumbed through the build.
  #
  # `sourceRepo` is "<owner>/<name>". Left null the previous behaviour is
  # preserved byte-for-byte, so adopting this is opt-in per consumer and
  # cannot re-digest an image that has not opted in.
  mkStandardLabels = {
    serviceName,
    tag,
    description ? null,
    sourceRepo ? null,
    fleetSourceUrl ?
      (if sourceRepo != null
       then "https://github.com/${sourceRepo}"
       else "https://github.com/pleme-io/${serviceName}"),
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
