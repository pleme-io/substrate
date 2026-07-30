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
# THIS BUILDER COMPILES GO, WHICH IS NOT OBVIOUS FROM ITS NAME, and that is how
# a "hardened distroless SPA image" came to carry 48 CVEs. The image ships a
# compat-sh — a shaped /bin/sh built through mkHardenedGoBinary — and until
# 2026-07-30 that compiled with the CONSUMER's `pkgs.go`. On the consumer that
# hit it (nixos-24.05, go 1.22.8) the Rust server binary, the SPA assets, the
# config and the CA roots ALL scanned clean and the shim's Go stdlib was the
# entire finding list, CRITICAL included. So `goToolchain` is threaded here for
# the same reason lib/build/oci-push.nix threads `fenix`: a builder must not
# inherit its compiler from whatever the caller happened to pin. See
# lib/build/go/toolchain.nix's header for the incident in full.
#
# Usage:
#   spa = import "${substrate}/lib/build/web/static-spa-image.nix" {
#     goToolchain = substrate.goToolchains.${system}.stable; # for compat-sh
#   };
#   img = spa.mkStaticSpaImage pkgs {
#     name = "web-ui";
#     version = "2.41.132";
#     server = hanabi.packages.${system}."hanabi-${target}-unknown-linux-musl";
#     serverBin = "hanabi";
#     staticDir = ./build;          # the yarn build output
#     serverConfig = ./hanabi.yaml; # the scoped profile
#     listenPort = 8000;
#   };
{
  # The fleet Go toolchain, ALREADY BUILT — `substrate.goToolchains.${system}
  # .stable`. Reaches compat-sh's mkHardenedGoBinary call below. When null,
  # mkHardenedGoBinary's CVE floor rejects the build at eval on any consumer
  # whose own `go` is below the floor, which is the intended behaviour: an
  # unnoticed stale compiler is what this whole seam exists to stop.
  goToolchain ? null,
}:
let
  # Privileged ports are the one thing a non-root process cannot simply be
  # configured into. The old infra passes 80 because that is what nginx-as-root
  # used, so rather than fail on it, normalize: a privileged port maps to its
  # unprivileged echo and anything already unprivileged passes through untouched.
  #
  #   80   -> 8000
  #   443  -> 8443
  #   8000 -> 8000   (idempotent, so declaring the real port is also correct)
  #
  # Idempotence is the property that matters: a caller may pass either the
  # interface port or the actual port and get the same image, so this can be
  # applied without knowing which one it was handed.
  normalizeListenPort = port:
    if port == 80 then 8000
    else if port == 443 then 8443
    else port;

  mkStaticSpaImage = pkgs: {
    # Logical service name: labels, the config derivation, the conformance
    # check's own name.
    name,
    # Published repository name, separate from `name` the way mkPackageImage
    # keeps service and publishName separate. The fleet convention for a
    # rebuilt-and-hardened artifact is `hardened-<name>`, which also avoids
    # colliding with the un-hardened image of the same version already sitting in
    # a registry.
    publishName ? name,
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
    # hanabi's own default, so no CONFIG_PATH env is needed to find it.
    serverConfigPath ? "/etc/hanabi/config.yaml",
    # See the interface note in the header before changing this.
    staticRoot ? "/usr/share/nginx/html",
    # Accepts the interface port (80) or the real one (8000); both resolve to
    # 8000 because the server runs non-root. See normalizeListenPort.
    listenPort ? 80,
    healthPath ? "/health",
    # Ship a /bin/sh so a lifecycle hook that names one does not fail on every
    # pod termination. NOT substrate's shDashShim: dash is glibc-only, and
    # pulling glibc onto a static base to satisfy `sleep 10` costs the whole
    # closure argument, the same trap distroless.nix documents for tini. compatSh
    # is a static Go binary that answers to /bin/sh and cannot execute anything.
    compatShell ? true,
    tag ? version,
    extraEnv ? [],
    labels ? {},
    tataraScript ? null,
  }:
  let
    lib = pkgs.lib;
    hardenedBase = import ../oci/hardened-base.nix { inherit pkgs; };
    # goToolchain threaded, not defaulted away: compat-sh below is compiled
    # through this, and it is the binary that carried the whole 2026-07-30
    # finding list. See this file's header.
    hardenedGo = import ../go/hardened-image.nix { inherit goToolchain; };

    actualPort = normalizeListenPort listenPort;

    # Copy the binary out of its own package rather than referencing it.
    #
    # mkPackageImage derives image contents from the package's closure. A
    # pkgsStatic package's closure is not just the binary: it can carry
    # propagated -dev outputs and the C toolchain, which for a STATIC binary is
    # pure dead weight and, worse, can put a libc back in the image the
    # conformance check then correctly rejects for containing "libc.so".
    #
    # cp, deliberately. `ln -s` and `lib.getBin` both retain the store reference
    # and so retain the closure, which is the whole thing being avoided. A static
    # binary needs nothing from its build closure at runtime, so severing it is
    # sound rather than a trick.
    #
    # Side benefit: the entrypoint becomes /bin/<name>, a stable path, instead of
    # a store path that changes on every rebuild.
    # STRIPPED here, not trusted to arrive stripped. hanabi's Cargo.toml does
    # set `strip = true` under [profile.release], and it is inert: the crate2nix
    # / gen build path composes its own rustc invocations and never reads
    # [profile.release], which is visible in its own build log emitting
    # `-C opt-level=3 -C codegen-units=1` while the manifest asks for
    # opt-level "z". So the manifest says stripped, the artifact is not, and
    # the conformance check caught the difference ("binary retains a symbol
    # table") on the first image that reached it.
    #
    # An image builder should not take a hardening property on trust from its
    # input anyway. Doing it here makes the property hold for every server
    # handed to this function regardless of how upstream was built, and it
    # costs one command on a binary that is already being copied.
    serverBinary = pkgs.runCommand "${name}-server-bin"
      { nativeBuildInputs = [ pkgs.binutils ]; } ''
      mkdir -p "$out/bin"
      cp ${server}/bin/${serverBin} "$out/bin/${serverBin}"
      chmod +w "$out/bin/${serverBin}"
      strip --strip-all "$out/bin/${serverBin}"
      chmod a-w,a+x "$out/bin/${serverBin}"
    '';

    # A shaped /bin/sh: implements the lifecycle-hook vocabulary and nothing
    # else. Built through mkHardenedGoBinary so the shim itself is held to the
    # same compile-time hardening as anything else in the image.
    compatSh =
      let
        bin = hardenedGo.mkHardenedGoBinary pkgs {
          name = "compat-sh";
          src = ../oci/compat-sh;
          vendorHash = null;
          doCheck = true;
        };
      in
      pkgs.runCommand "compat-sh-bin-sh" { } ''
        mkdir -p "$out/bin"
        cp ${bin}/bin/compat-sh "$out/bin/sh"
      '';

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
      package = serverBinary;
      publishName = publishName;
      publishTag = tag;
      entrypoint = [ "/bin/${serverBin}" ];
      inherit user;
      workdir = "/";
      exposedPorts = { "${toString actualPort}/tcp" = { }; };
      extraContents = [ assets configFile ] ++ lib.optional compatShell compatSh;
      # NO server-specific env. Verified against hanabi's own loader: the only
      # env var it reads for this is CONFIG_PATH, which already defaults to
      # /etc/hanabi/config.yaml, and static_dir/http_port come from the config
      # FILE (server.static_dir, server.http_port) rather than from env at all.
      #
      # That is also the right interface. The chart deploying this image was
      # written for nginx and knows nothing about the server inside; if it had to
      # set server-specific env, swapping the server would not be a drop-in. So
      # everything the server needs is baked into the image and the config file,
      # and the chart passes exactly what it always passed.
      # The base ships cacert but nothing points at it, and a Rust server using
      # rustls with native roots will not find the bundle on its own. This is the
      # same line mkGoDockerImage sets for the same reason.
      env = [
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ] ++ extraEnv;
      labels = {
        "com.pleme.image.minimal" = "true";
        "com.pleme.image.hardened" = "true";
        "com.pleme.spa.staticRoot" = staticRoot;
        "com.pleme.spa.healthPath" = healthPath;
        "com.pleme.spa.listenPort" = toString actualPort;
        # Recorded so a reader can see the mapping happened rather than
        # wondering why the declared port and the exposed port differ.
        "com.pleme.spa.requestedPort" = toString listenPort;
        "org.opencontainers.image.title" = name;
        "org.opencontainers.image.version" = version;
      } // labels;
    };

    # Language-agnostic: it wants a tarball, a binary and an expected user.
    # pie = false because a static Rust musl binary is not built PIE here, and
    # the check asserts the DECLARED value rather than a fixed one.
    conformance = hardenedGo.mkHardenedGoImageCheck pkgs {
      inherit name image tataraScript;
      # The copied binary, not the package, so the check inspects exactly what
      # ships.
      binary = serverBinary;
      binName = serverBin;
      expectUser = user;
      pie = false;
      # serverBinary + cacert + passwd + group + tmp stub + assets + config = 7,
      # with one slot of headroom. This ceiling is only meetable because the
      # binary's build closure was severed above.
      maxStorePaths = 8;
    };
  in
  image // {
    inherit assets configFile conformance;
    inherit normalizeListenPort;
    # Exposed so a test can exec the shim directly. Following the image's
    # /bin/sh symlink does not work from outside: it points at a store path the
    # consumer's sandbox has no reason to have.
    compatSh = if compatShell then compatSh else null;
    interface = {
      inherit staticRoot healthPath publishName;
      requestedPort = listenPort;
      listenPort = actualPort;
    };
    checks = { inherit conformance; };
  };
in
{
  inherit mkStaticSpaImage;
}
