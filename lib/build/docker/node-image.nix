# mkNodeDockerImage (L2) — JS-service OCI wrapper, mirror of mkGoDockerImage.
#
# THE GAP (borealis-pattern-registry §4f):
#   The substrate has language-coverage OCI wrappers for Rust
#   (`mkCrate2nixDockerImage`) and Go (`mkGoDockerImage`). The only existing
#   Node image builder (`lib/build/web/docker.nix`) targets a STATIC SPA served
#   by the Rust/Axum `hanabi` BFF — a *web app*, not a JS *service*. A Node.js
#   long-running service (an Express/Fastify/NestJS API, a worker, a daemon) had
#   no builder, so it was produced ad-hoc. This is that wrapper: a JS-service OCI
#   image whose param shape is byte-for-byte the same as `mkGoDockerImage` so a
#   consumer crossing Go↔Node never re-learns the surface.
#
# DELIBERATE PARITY WITH mkGoDockerImage:
#   - same params: name, binary→builtApp, tag, architecture, ports, env, user,
#     workDir, entrypoint, extraContents, distroless, tini, labels, description,
#     fleetSourceUrl, created
#   - same hardening: non-root uid (65534:65534), SSL cert bundle, distroless
#     drops busybox, tini as PID 1, OCI v1.1 reserved annotations via the shared
#     `mkStandardLabels`, reproducible `created` epoch.
#   - difference: a Node service runs `node <entry.js>`, so the image carries
#     the `nodejs` interpreter + the built app dir (the result of
#     `buildNpmPackage` / `pnpm2nix` / similar), instead of a single static
#     Go binary. `entry` names the JS entrypoint inside `builtApp`.
#
# Usage:
#   mkNodeDockerImage = (import "${substrate}/lib/build/docker/node-image.nix").mkNodeDockerImage;
#   image = mkNodeDockerImage pkgs {
#     name = "my-svc";
#     builtApp = myNpmPackage;          # result of buildNpmPackage
#     entry = "dist/server.js";         # JS entrypoint within builtApp/lib/node_modules/<name>
#     ports = { http = 8080; health = 8081; };
#     env = [ "NODE_ENV=production" ];
#     distroless = true;                # FedRAMP-High: no shell/coreutils
#   };
#
# NOTE: This wrapper is intentionally NOT named identically to the web
# `mkNodeDockerImage` consumer-surface (a static-SPA builder). They serve
# different concerns (runtime service vs. served static assets) and live in
# different module paths; the web one stays put for backward compatibility.
{
  # Build a layered OCI image from a built Node.js service.
  #
  # FedRAMP-High knobs mirror mkGoDockerImage (Phase 2 hardening):
  #   distroless — drop busybox; cacert (+ tini) + the node interpreter only.
  #   tini       — PID 1 when distroless (Node does NOT reap zombies by default,
  #                so tini is genuinely load-bearing for a Node service, more so
  #                than for Go).
  #   labels     — operator labels merged over the default OCI annotation set.
  #   created    — ISO timestamp for the OCI `created` annotation (default the
  #                reproducible 1970 epoch).
  mkNodeDockerImage = pkgs: {
    name,
    builtApp,
    entry,
    tag ? "latest",
    architecture ? "amd64",
    ports ? { http = 8080; health = 8081; },
    env ? [],
    user ? "65534:65534",
    workDir ? "/app",
    entrypoint ? null,
    extraContents ? [],
    nodejs ? pkgs.nodejs,
    # ─── Phase 2 hardening knobs (mirror mkGoDockerImage) ───────────
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
    distrolessHelper = import ../go/distroless.nix;
    _ = check.all [
      (check.nonEmptyStr "name" name)
      (check.nonEmptyStr "entry" entry)
      (check.str "tag" tag)
      (check.architecture "architecture" architecture)
      (check.namedPorts "ports" ports)
      (check.list "env" env)
      (check.str "user" user)
      (check.str "workDir" workDir)
      (check.list "extraContents" extraContents)
    ];

    sslEnv = "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt";

    exposedPorts = lib.mapAttrs' (_: port:
      lib.nameValuePair "${toString port}/tcp" {}
    ) ports;

    # A Node service is launched as `node <builtApp>/<entry>`. Consumers may
    # override with an explicit `entrypoint` (e.g. a wrapped launcher).
    defaultEntrypoint = [ "${nodejs}/bin/node" "${builtApp}/${entry}" ];

    # Base contents — distroless drops busybox; the node interpreter + cacert
    # (+ optional tini) are always present.
    baseContents =
      (if distroless
       then distrolessHelper.mkDistrolessBase pkgs { withTini = tini; withCacert = true; }
       else [ cacert busybox ])
      ++ [ nodejs ];

    standardLabels = helpers.mkStandardLabels {
      serviceName = name;
      inherit tag;
      description = if description != null then description
                    else "${name} — pleme-io substrate-built Node.js service";
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
    contents = [ builtApp ] ++ baseContents ++ extraContents;
    config = {
      Entrypoint = if entrypoint != null then entrypoint else defaultEntrypoint;
      ExposedPorts = exposedPorts;
      Env = [
        sslEnv
        "NODE_ENV=production"
        "GIT_SHA=nix-build"
        # USER/HOME defaults for distroless+numeric-uid images — same rationale
        # as mkGoDockerImage: libraries that chain through os.userInfo() need a
        # $USER/$HOME when /etc/passwd has no entry for the running uid.
        "USER=app"
        "HOME=${workDir}"
      ] ++ env;
      WorkingDir = workDir;
      User = user;
      Labels = standardLabels;
    };
  };

  # Build a Node service from npm sources + image in one call (mirror of
  # mkGoServiceImage). `builtApp` is produced by buildNpmPackage; the consumer
  # supplies the same args buildNpmPackage needs plus the OCI knobs.
  mkNodeServiceImage = pkgs: {
    name,
    src,
    entry,
    version ? "0.1.0",
    npmDepsHash,
    tag ? "latest",
    architecture ? "amd64",
    ports ? { http = 8080; health = 8081; },
    env ? [],
    nodejs ? pkgs.nodejs,
    extraNpmArgs ? {},
  }: let
    builtApp = pkgs.buildNpmPackage ({
      pname = name;
      inherit version src npmDepsHash nodejs;
    } // extraNpmArgs);
  in
  (import ./node-image.nix).mkNodeDockerImage pkgs {
    inherit name builtApp entry tag architecture ports env nodejs;
  };
}
