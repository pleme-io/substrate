# static-spa-image.nix — a distroless OCI image serving a prebuilt SPA through
# hanabi, assembled entirely in Nix. No Dockerfile.
#
# WHY THIS AND NOT A DOCKERFILE. The non-fedramp lanes of the consuming repo are
# built from a Dockerfile and keep working; this exists for the lane where the
# artifact has to be auditable end to end. A Dockerfile's `FROM` is an opaque
# blob whose contents you inherit and cannot enumerate; a Nix-assembled image's
# closure IS the enumeration. That is the whole argument, and it is why this
# builder takes a package set and a base rather than a base image reference.
#
# WHAT IT REUSES, and why nothing here is new:
#   • the binary — the consuming service's own musl target from
#     substrate.rust.service. hanabi already publishes
#     `hanabi-x86_64-unknown-linux-musl`, a static Rust binary, so there is no
#     new compile path to write and no glibc to escape.
#   • the base + the numeric nonroot uid + mkPackageImage — lib/build/oci/
#     hardened-base.nix. Its `writablePaths` handling in particular is not
#     reimplemented: that file documents, at length and from three live
#     failures, that a chmod inside a derivation is undone when the store path
#     is registered, and that fakeRootCommands during tar assembly is the only
#     place it can land. Rediscovering that would be expensive.
#   • the conformance check — lib/build/go/hardened-image.nix's
#     mkHardenedGoImageCheck. Its assertions (numeric non-root user, no setuid,
#     stripped, no build id, declared-PIE) are language-agnostic once you have a
#     tarball and a binary, so a Rust twin would be duplication.
#
# THE STATIC ROOT IS AN INTERFACE, NOT A PREFERENCE. `staticRoot` defaults to
# /usr/share/nginx/html despite there being no nginx in this image, because a
# Kubernetes chart mounts a ConfigMap subPath into that exact directory to
# deliver per-tenant runtime config. Serve from elsewhere and the tenant boots
# with no config, which presents as an application bug rather than a packaging
# one. Changing this default breaks a contract the chart owns.
#
# Usage:
#   spa = import "${substrate}/lib/build/web/static-spa-image.nix" { };
#   img = spa.mkStaticSpaImage pkgs {
#     name = "web-ui";
#     version = "2.41.132";
#     server = hanabi.packages.${system}."hanabi-${target}-unknown-linux-musl";
#     serverBin = "hanabi";
#     staticDir = ./build;          # the yarn build output
#     serverConfig = ./hanabi.yaml; # the scoped profile
#     listenPort = 8000;
#   };
{ }:
let
  mkStaticSpaImage = pkgs: {
    name,
    version ? "0.0.0",
    # The server package. Expected to be a STATIC binary: the base has no
    # dynamic loader, so a glibc-linked server would not start. Asserted by the
    # conformance check rather than trusted.
    server,
    serverBin ? "hanabi",
    # The already-built SPA directory. A path or a derivation. Deliberately an
    # input rather than something this builder produces: packaging an npm
    # dependency tree in Nix to serve files it has already built is a large cost
    # for no gain in the artifact.
    staticDir,
    # The server's own config file, copied to serverConfigPath.
    serverConfig,
    serverConfigPath ? "/etc/hanabi/config.yaml",
    # See the interface note in the header before changing this.
    staticRoot ? "/usr/share/nginx/html",
    listenPort ? 8000,
    healthPath ? "/health",
    tag ? version,
    extraEnv ? [],
    labels ? {},
    tataraScript ? null,
  }:
  let
    lib = pkgs.lib;
    hardenedBase = import ../oci/hardened-base.nix { inherit pkgs; };
    hardenedGo = import ../go/hardened-image.nix { };

    uid = hardenedBase.nonrootUid;
    gid = hardenedBase.nonrootGid;
    user = "${toString uid}:${toString gid}";

    # The assets and the config become their own store paths laid out at the
    # exact interface locations, then ride in as extraContents. Nothing is
    # chmodded here on purpose: store paths lose their write bits on
    # registration, so ownership is handled by mkPackageImage's writablePaths
    # during tar assembly instead.
    assets = pkgs.runCommand "${name}-static" { } ''
      mkdir -p "$out${staticRoot}"
      cp -r ${staticDir}/. "$out${staticRoot}/"
    '';

    configFile = pkgs.runCommand "${name}-server-config" { } ''
      mkdir -p "$(dirname "$out${serverConfigPath}")"
      cp ${serverConfig} "$out${serverConfigPath}"
    '';

    image = hardenedBase.mkPackageImage {
      service = name;
      base = hardenedBase.bases.distroless-static;
      package = server;
      publishName = name;
      publishTag = tag;
      entrypoint = [ "${server}/bin/${serverBin}" ];
      inherit user;
      workdir = "/";
      exposedPorts = { "${toString listenPort}/tcp" = { }; };
      extraContents = [ assets configFile ];
      env = [
        "HANABI_CONFIG=${serverConfigPath}"
        "HANABI_STATIC_DIR=${staticRoot}"
        "HANABI_HTTP_PORT=${toString listenPort}"
      ] ++ extraEnv;
      labels = {
        "com.pleme.image.minimal" = "true";
        "com.pleme.image.hardened" = "true";
        "com.pleme.spa.staticRoot" = staticRoot;
        "com.pleme.spa.healthPath" = healthPath;
        "com.pleme.spa.listenPort" = toString listenPort;
        "org.opencontainers.image.title" = name;
        "org.opencontainers.image.version" = version;
      } // labels;
    };

    # Language-agnostic: it wants a tarball, a binary and an expected user.
    # pie = false because a static Rust musl binary is not built PIE here, and
    # the check asserts the DECLARED value rather than a fixed one.
    conformance = hardenedGo.mkHardenedGoImageCheck pkgs {
      inherit name image tataraScript;
      binary = server;
      binName = serverBin;
      expectUser = user;
      pie = false;
      # server + cacert + passwd + group + assets + config, plus headroom.
      maxStorePaths = 8;
    };
  in
  image // {
    inherit assets configFile conformance;
    interface = { inherit staticRoot healthPath listenPort; };
    checks = { inherit conformance; };
  };
in
{
  inherit mkStaticSpaImage;
}
