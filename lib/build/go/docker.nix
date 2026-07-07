# Go Service Docker Image Builder
#
# Builds minimal, secure Docker images for Go services. Equivalent of
# mkCrate2nixDockerImage for Rust, but for Go binaries.
#
# Features:
# - Alpine-based minimal images
# - Non-root user (65534:65534)
# - Multi-architecture (amd64/arm64)
# - Health check port configuration
# - SSL certificate bundle included
# - Layered for cache efficiency
#
# Usage:
#   mkGoDockerImage = (import "${substrate}/lib/go-docker.nix").mkGoDockerImage;
#   image = mkGoDockerImage pkgs {
#     name = "my-service";
#     binary = myGoBinary;        # result of buildGoModule
#     architecture = "amd64";     # or "arm64"
#     ports = { http = 8080; health = 8081; metrics = 9090; };
#     env = [ "LOG_LEVEL=info" ];
#   };
{
  # Build a layered Docker image from a Go binary.
  #
  # MINIMAL-PRODUCTION-IMAGE knob (default-on for production; see
  # docs/MINIMAL-PRODUCTION-IMAGE.md):
  #   minimal       — the strict production posture. Forces the `scratch`
  #                   base (cacert ONLY): no shell, no coreutils, no
  #                   package-manager, NO init (tini), and hence no glibc
  #                   subtree pulled by tini. A statically-linked
  #                   (CGO_ENABLED=0) Go binary is self-contained; its own
  #                   runtime closure supplies whatever it truly needs, so
  #                   the shipped non-binary closure collapses to the cert
  #                   bundle (~0.65 MB) and the OS-CVE surface to 1 data
  #                   package. When true it OVERRIDES `distroless`/`tini`.
  #                   Self-declares via the `com.pleme.image.minimal` label.
  #
  # FedRAMP-High knobs (Phase 2 hardening, 2026-05):
  #   distroless    — drop busybox; use cacert (+ tini) only. Smaller
  #                   attack surface, no shell, no coreutils.
  #   labels        — operator-supplied labels merged with the
  #                   default OCI annotation set from mkStandardLabels.
  #   created       — ISO timestamp for OCI `created` annotation.
  #                   Default 1970-01-01T00:00:01Z (reproducibility).
  #   tini          — when distroless=true (and NOT minimal), include tini
  #                   as PID 1. Go programs handle their own signals, so
  #                   tini is rarely needed — and it is NOT free: tini is
  #                   dynamically linked and drags the whole glibc subtree
  #                   (~32.6 MB / 4 OS pkgs incl. glibc). `minimal: true`
  #                   drops it. Keep only for genuinely multi-process
  #                   containers that must reap zombies.
  mkGoDockerImage = pkgs: {
    name,
    binary,
    tag ? "latest",
    architecture ? "amd64",
    ports ? { http = 8080; health = 8081; },
    env ? [],
    user ? "65534:65534",
    workDir ? "/app",
    entrypoint ? null,
    extraContents ? [],
    # ─── MINIMAL-PRODUCTION-IMAGE (default-on for production) ───────
    minimal ? false,
    # ─── Phase 2 hardening knobs ───────────────────────────────────
    distroless ? false,
    tini ? true,
    labels ? {},
    description ? null,
    fleetSourceUrl ? null,
    created ? "1970-01-01T00:00:01Z",
  }: let
    inherit (pkgs) lib dockerTools cacert busybox;
    check = import ../../types/assertions.nix;
    helpers = import ../../util/docker-helpers.nix;
    distrolessHelper = import ./distroless.nix;
    _ = check.all [
      (check.nonEmptyStr "name" name)
      (check.str "tag" tag)
      (check.architecture "architecture" architecture)
      (check.namedPorts "ports" ports)
      (check.list "env" env)
      (check.str "user" user)
      (check.str "workDir" workDir)
      (check.list "extraContents" extraContents)
      (check.bool "minimal" minimal)
      (check.bool "distroless" distroless)
      (check.bool "tini" tini)
    ];

    mainPort = ports.http or ports.api or (lib.head (lib.attrValues ports));
    healthPort = ports.health or mainPort;

    sslEnv = "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt";

    exposedPorts = lib.mapAttrs' (_: port:
      lib.nameValuePair "${toString port}/tcp" {}
    ) ports;

    defaultEntrypoint = [ "${binary}/bin/${name}" ];

    # Base contents — the MINIMAL-PRODUCTION-IMAGE base-selection ladder.
    #   minimal    → scratch (cacert only; no tini ⇒ no glibc, no shell).
    #                Overrides distroless/tini — the strict production stack.
    #   distroless → cacert (+ tini iff `tini`); no busybox.
    #   (neither)  → cacert + busybox (the fat/debug base).
    # The binary's OWN runtime closure is added by buildLayeredImage on top
    # of this base, so a dynamic (CGO) binary still gets its libc via its
    # closure while a static one ships nothing but the cert bundle.
    baseContents =
      if minimal
      then distrolessHelper.mkDistrolessBase pkgs { withTini = false; withCacert = true; }
      else if distroless
      then distrolessHelper.mkDistrolessBase pkgs { withTini = tini; withCacert = true; }
      else [ cacert busybox ];

    # OCI annotations auto-injected for every image. Operators can
    # override + extend via `labels`.
    standardLabels = helpers.mkStandardLabels {
      serviceName = name;
      inherit tag;
      description = if description != null then description
                    else "${name} — pleme-io substrate-built service";
    } // (if fleetSourceUrl != null
          then { "org.opencontainers.image.source" = fleetSourceUrl;
                 "org.opencontainers.image.url" = fleetSourceUrl;
                 "org.opencontainers.image.documentation" = "${fleetSourceUrl}#readme"; }
          else {})
      // { "org.opencontainers.image.created" = created; }
      # Self-declare the posture so the shipped artifact answers "is this a
      # MINIMAL-PRODUCTION-IMAGE?" without unpacking it — the CVE-gate /
      # admission surface can key off it.
      // { "com.pleme.image.minimal" = if minimal then "true" else "false"; }
      // labels;
  in
  dockerTools.buildLayeredImage {
    inherit name tag architecture created;
    contents = [ binary ] ++ baseContents ++ extraContents;
    config = {
      Entrypoint = if entrypoint != null then entrypoint else defaultEntrypoint;
      ExposedPorts = exposedPorts;
      Env = [
        sslEnv
        "GIT_SHA=nix-build"
        # USER/HOME defaults for distroless+numeric-uid images. Go's
        # `os/user.Current()` (and several libraries that chain through
        # it) falls back to `$USER` when /etc/passwd has no entry for
        # the running uid. Without these, any binary touching that
        # codepath panics at startup. Consumer-supplied `env` (below)
        # can override.
        "USER=app"
        "HOME=${workDir}"
      ] ++ env;
      WorkingDir = workDir;
      User = user;
      Labels = standardLabels;
    };
  };

  # Build a multi-stage Go binary + Docker image in one call.
  #
  # MINIMAL-PRODUCTION-IMAGE: `minimal` defaults ON. The binary is built
  # CGO_ENABLED=0 (static) with the static-friendly Go build tags, and the
  # image ships the scratch base. Set `minimal = false` for a fat/debug
  # image with a shell.
  mkGoServiceImage = pkgs: {
    name,
    src,
    version ? "0.1.0",
    subPackages ? [ "cmd/${name}" ],
    vendorHash ? null,
    tag ? "latest",
    architecture ? "amd64",
    ports ? { http = 8080; health = 8081; },
    env ? [],
    buildInputs ? [],
    ldflags ? [],
    minimal ? true,
    # Static-friendly Go build tags: embed zoneinfo (timetzdata), use the
    # pure-Go net + os/user resolvers (netgo/osusergo) so the binary drops
    # its /etc/{protocols,services,mime.types,passwd} references. Only
    # applied when `minimal`; set [] to opt out.
    goTags ? [ "timetzdata" "netgo" "osusergo" ],
  }: let
    tags = if minimal then goTags else [];
    binary = pkgs.buildGoModule {
      pname = name;
      inherit version src vendorHash subPackages ldflags tags;
      inherit buildInputs;
      env = { CGO_ENABLED = "0"; };
      meta.mainProgram = name;
    };
  in
  (pkgs.callPackage ./go-docker.nix {}).mkGoDockerImage pkgs {
    inherit name binary tag architecture ports env minimal;
  };
}
