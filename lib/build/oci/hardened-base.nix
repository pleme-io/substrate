# Hardened OCI base images for pleme-io vendor rewraps (Path 2).
#
# Consumed by `arch-synthesizer::akeyless_image::NixOciImageDecl` — the
# Rust typescape declares which base a service's image uses; this module
# is the concrete Nix substrate that materializes it.
#
# Three base families exposed:
#   - distroless-static  : CA roots + /etc/passwd + /etc/group only. No
#                          shell, no libc. For statically linked Go binaries
#                          (Akeyless ships these). Minimum attack surface.
#   - distroless-glibc   : distroless-static + glibc for dynamically
#                          linked binaries.
#   - wolfi              : Chainguard-style wolfi shim — glibc + apk,
#                          non-root by default, CVE-patched nightly by
#                          the provider.
#
# Plus `mkVendorRewrap` — pull an upstream OCI image by digest, extract a
# named binary from its rootfs, repackage on a hardened base, publish to
# a `ghcr.io/pleme-io/*` reference.
#
# Usage (instantiated via substrate.lib.${system}):
#   bases = substrateLib.hardenedBases;
#   gatewayImage = substrateLib.mkVendorRewrap {
#     service = "akeyless-gateway";
#     base = bases.distroless-glibc;
#     upstream = "docker.io/akeyless/base";
#     upstreamDigest = "sha256:abc…";  # pinned by consumer (sops-nix or
#     publishName = "ghcr.io/pleme-io/akeyless-gateway";
#     publishTag = "4.47.0-nix0";
#     binaryPath = "/usr/local/bin/akeyless-gateway";
#   };
#
# The consumer repo owns the digest pin — substrate provides the shape
# but does NOT embed real upstream hashes (they rotate per upstream
# release and should live where the per-service flake is).
{ pkgs }:

let
  inherit (pkgs) lib dockerTools cacert;

  # Non-root UID matching distroless convention.
  nonrootUid = 65532;
  nonrootGid = 65532;

  # Minimal user/group files so containers don't run with NSS failures
  # when setuid calls lookup /etc/passwd. We ship `nonroot` + `nobody`.
  nonrootPasswd = pkgs.writeTextDir "etc/passwd" ''
    root:x:0:0:root:/root:/sbin/nologin
    nobody:x:65534:65534:nobody:/var/empty:/sbin/nologin
    nonroot:x:${toString nonrootUid}:${toString nonrootGid}:nonroot:/home/nonroot:/sbin/nologin
  '';
  nonrootGroup = pkgs.writeTextDir "etc/group" ''
    root:x:0:
    nobody:x:65534:
    nonroot:x:${toString nonrootGid}:
  '';

  # Minimal /tmp directory so consumers that write temp files don't blow
  # up on read-only root (tmpfs typically mounted at runtime).
  tmpStub = pkgs.runCommand "pleme-io-tmp-stub" {} ''
    mkdir -p $out/tmp
    chmod 1777 $out/tmp
  '';

  commonContents = [
    cacert
    nonrootPasswd
    nonrootGroup
    tmpStub
  ];

  # ═══════════════════════════════════════════════════════════════════
  # Base image builders
  # ═══════════════════════════════════════════════════════════════════

  # distroless-static: TLS roots + nonroot user. No libc. For statically
  # linked binaries.
  mkDistrolessStaticBase = {
    name ? "pleme-io-distroless-static",
    tag ? "latest",
    extra ? [],
  }: dockerTools.buildLayeredImage {
    inherit name tag;
    contents = commonContents ++ extra;
    config = {
      User = "${toString nonrootUid}:${toString nonrootGid}";
      WorkingDir = "/";
    };
  };

  # distroless-glibc: distroless-static + glibc for dynamically linked
  # binaries. Still no shell.
  mkDistrolessGlibcBase = {
    name ? "pleme-io-distroless-glibc",
    tag ? "latest",
    extra ? [],
  }: dockerTools.buildLayeredImage {
    inherit name tag;
    contents = commonContents ++ [
      pkgs.glibc
    ] ++ extra;
    config = {
      User = "${toString nonrootUid}:${toString nonrootGid}";
      WorkingDir = "/";
      Env = [
        "LD_LIBRARY_PATH=${pkgs.glibc}/lib"
      ];
    };
  };

  # wolfi shim: in the pleme-io variant we use nixpkgs' apk-compatible
  # glibc + busybox-nonroot to get a closer analog of Chainguard wolfi
  # semantics (non-root default, readable rootfs, minimal apk surface).
  # Real wolfi-upstream images can slot in via `mkVendorRewrap` instead
  # when the consumer prefers Chainguard's attestations.
  mkWolfiBase = {
    name ? "pleme-io-wolfi-shim",
    tag ? "latest",
    extra ? [],
  }: dockerTools.buildLayeredImage {
    inherit name tag;
    contents = commonContents ++ [
      pkgs.glibc
      pkgs.busybox
    ] ++ extra;
    config = {
      User = "${toString nonrootUid}:${toString nonrootGid}";
      WorkingDir = "/";
      Env = [
        "LD_LIBRARY_PATH=${pkgs.glibc}/lib"
        "PATH=/bin:/usr/bin"
      ];
    };
  };

  # ═══════════════════════════════════════════════════════════════════
  # Vendor rewrap
  # ═══════════════════════════════════════════════════════════════════

  # Pull `upstream@upstreamDigest`, extract `binaryPath` from its rootfs,
  # repackage on `base` at `publishName:publishTag`. The caller is
  # responsible for pinning `upstreamSha256` — the sha256 of the pulled
  # image tarball, which nix-prefetch-docker / dockerTools.pullImage
  # surfaces deterministically.
  mkVendorRewrap = {
    service,                       # logical service name (label-only)
    base,                          # output of mk*Base
    upstream,                      # e.g. "docker.io/akeyless/base"
    upstreamDigest,                # "sha256:…" manifest digest
    upstreamSha256,                # sha256 of the pulled layered image tar
    upstreamOs ? "linux",
    upstreamArch ? "amd64",
    binaryPath,                    # path inside rootfs, e.g. "/usr/local/bin/gateway"
    publishName,                   # e.g. "ghcr.io/pleme-io/akeyless-gateway"
    publishTag,                    # e.g. "4.47.0-nix0"
    extraContents ? [],
    env ? [],
  }: let
    # Pull upstream. `imageDigest` identifies the remote manifest; `sha256`
    # is the local tarball hash. Caller pins both.
    pulled = dockerTools.pullImage {
      imageName = upstream;
      imageDigest = upstreamDigest;
      sha256 = upstreamSha256;
      os = upstreamOs;
      arch = upstreamArch;
      finalImageName = "${service}-upstream";
      finalImageTag = "extracted";
    };

    # Unpack the pulled image and copy the binary out. Uses skopeo+umoci
    # for a deterministic unpack — `tar -xf` over layered images produces
    # whiteouts.
    extractedBinary = pkgs.runCommand "${service}-binary" {
      nativeBuildInputs = [ pkgs.skopeo pkgs.umoci ];
    } ''
      mkdir -p oci rootfs
      skopeo copy \
        --src-tls-verify=false \
        docker-archive:${pulled} \
        "oci:oci:${service}-latest"
      umoci unpack --image "oci:${service}-latest" rootfs
      install -Dm0755 "rootfs/rootfs${binaryPath}" "$out/bin/${baseNameOf binaryPath}"
    '';

    entrypointBin = "/bin/${baseNameOf binaryPath}";
  in dockerTools.buildLayeredImage {
    name = publishName;
    tag = publishTag;
    fromImage = base;
    contents = [ extractedBinary ] ++ extraContents;
    config = {
      Entrypoint = [ entrypointBin ];
      User = "${toString nonrootUid}:${toString nonrootGid}";
      WorkingDir = "/";
      Env = env;
      Labels = {
        "org.opencontainers.image.source" = "https://github.com/pleme-io";
        "org.opencontainers.image.vendor" = "pleme-io";
        "io.pleme.rewrap.upstream" = upstream;
        "io.pleme.rewrap.upstream.digest" = upstreamDigest;
        "io.pleme.rewrap.service" = service;
      };
    };
  };

  # ═══════════════════════════════════════════════════════════════════
  # Package image — the sibling `mkVendorRewrap` doesn't cover
  # ═══════════════════════════════════════════════════════════════════

  # `mkVendorRewrap` extracts ONE binary from an upstream image — the right
  # shape for a statically-linked Go tool, the wrong shape for a full
  # runtime (Erlang/OTP + plugins, a JVM app, anything with more than one
  # file that matters). `mkPackageImage` instead takes an nixpkgs
  # DERIVATION directly — built from source by Nix, never extracted from
  # someone else's binary — and repackages its full closure on a hardened
  # base, preserving whatever entrypoint/port/volume/env CONTRACT the
  # upstream vendor image it replaces exposed (so it drops in as a
  # same-interface substitute). The "exact version" case (pin a version
  # nixpkgs' current default doesn't ship) is the CALLER's job via
  # `package.overrideAttrs`, not this function's — mkPackageImage only
  # cares that it received a buildable derivation.
  mkPackageImage = {
    service,                 # logical name (labels only)
    base,                    # output of mk*Base
    package,                 # the nixpkgs derivation to package
    publishName,
    publishTag,
    entrypoint,               # list, e.g. [ "${package}/sbin/rabbitmq-server" ]
    cmd ? [],
    env ? [],
    exposedPorts ? {},        # e.g. { "5672/tcp" = {}; }
    volumes ? {},             # e.g. { "/var/lib/rabbitmq" = {}; }
    workdir ? "/",
    user ? "${toString nonrootUid}:${toString nonrootGid}",
    extraContents ? [],
    # Writable-at-runtime paths (e.g. a data/log dir under `volumes`)
    # that must be owned by the non-root `user` this image runs as —
    # `extraContents`' own `runCommand` output is root-owned by
    # default, and a non-root container can't chown its own volume at
    # startup with no shell/coreutils on a hardened base. Threaded to
    # `buildLayeredImage`'s `fakeRootCommands` (fakeroot, no real
    # privilege needed in the Nix sandbox) so ownership is baked into
    # the image layer itself. e.g. [ "/var/lib/mysql" "/var/lib/rabbitmq" ].
    writablePaths ? [],
  }: dockerTools.buildLayeredImage {
    name = publishName;
    tag = publishTag;
    fromImage = base;
    contents = [ package ] ++ extraContents;
    fakeRootCommands = lib.concatMapStringsSep "\n"
      (p: "chown -R ${user} ${p}") writablePaths;
    enableFakechroot = writablePaths != [];
    config = {
      Entrypoint = entrypoint;
      Cmd = cmd;
      User = user;
      WorkingDir = workdir;
      Env = env;
      ExposedPorts = exposedPorts;
      Volumes = volumes;
      Labels = {
        "org.opencontainers.image.source" = "https://github.com/pleme-io";
        "org.opencontainers.image.vendor" = "pleme-io";
        "io.pleme.rebuild.package" = package.pname or service;
        "io.pleme.rebuild.version" = package.version or "unknown";
        "io.pleme.rebuild.service" = service;
      };
    };
  };

in {
  # Base image families — consumed via `bases.distroless-glibc` etc.
  bases = {
    distroless-static = mkDistrolessStaticBase {};
    distroless-glibc  = mkDistrolessGlibcBase {};
    wolfi             = mkWolfiBase {};
  };

  # Per-variant builders so consumers can override (e.g. add `extra` pkgs).
  inherit mkDistrolessStaticBase mkDistrolessGlibcBase mkWolfiBase;

  # Vendor rewrap — Path 2 entry point (extract-one-binary shape).
  inherit mkVendorRewrap;

  # Package image — Path 2 sibling (from-source-derivation shape).
  inherit mkPackageImage;

  # Convention: reuse these UIDs across all pleme-io vendor images.
  inherit nonrootUid nonrootGid;
}
