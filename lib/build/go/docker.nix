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
  # FedRAMP-High knobs (Phase 2 hardening, 2026-05):
  #   distroless    — drop busybox; use cacert (+ tini) only. Smaller
  #                   attack surface, no shell, no coreutils.
  #   labels        — operator-supplied labels merged with the
  #                   default OCI annotation set from mkStandardLabels.
  #   created       — ISO timestamp for OCI `created` annotation.
  #                   Default 1970-01-01T00:00:01Z (reproducibility).
  #   tini          — when distroless=true, include tini as PID 1
  #                   (Go programs typically handle signals themselves,
  #                    but tini is cheap insurance against zombie procs).
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
    ];

    mainPort = ports.http or ports.api or (lib.head (lib.attrValues ports));
    healthPort = ports.health or mainPort;

    sslEnv = "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt";

    exposedPorts = lib.mapAttrs' (_: port:
      lib.nameValuePair "${toString port}/tcp" {}
    ) ports;

    defaultEntrypoint = [ "${binary}/bin/${name}" ];

    # Base contents — distroless drops busybox.
    baseContents =
      if distroless
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
  }: let
    binary = pkgs.buildGoModule {
      pname = name;
      inherit version src vendorHash subPackages ldflags;
      inherit buildInputs;
      CGO_ENABLED = 0;
      meta.mainProgram = name;
    };
  in
  (pkgs.callPackage ./go-docker.nix {}).mkGoDockerImage pkgs {
    inherit name binary tag architecture ports env;
  };
}
