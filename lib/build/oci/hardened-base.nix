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
{ pkgs, fenix ? null, system ? null }:

let
  inherit (pkgs) lib dockerTools cacert;

  # doca (oci-push)'s `harden-rootfs` subcommand -- see its own doc comment
  # (tools/oci-push/src/main.rs) for the full story. Used below instead of
  # the inline shell this file used to carry directly: a `for`/`if`/
  # `readlink` loop is real logic, not the 3-line glue the fleet's NO-SHELL
  # rule permits inline.
  # `fenix`/`system` passed through (2026-07-22) so doca can build with a
  # modern rustc/cargo independent of whatever primary nixpkgs a consumer
  # has pinned -- see oci-push.nix's own header for the full incident.
  doca = import ../oci-push.nix { inherit pkgs fenix system; };

  # The distroless tool-bundle catalog (./distroless-toolset.nix) — named
  # concern-bundles (`coreutils`, `textproc`, …) so `mkDistrolessImage`'s
  # `entrypointTools` is "pick from a standard set", not "hand-roll a raw
  # package list". `resolveTools` expands a mixed list of bundle names AND
  # raw packages to a flat package list; raw packages pass through, so this
  # is backward-compatible with every existing `entrypointTools = [ pkgs.x ]`.
  toolset = import ./distroless-toolset.nix { inherit pkgs; };

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
  #
  # The in-derivation `chmod 1777 $out/tmp` above is cosmetic only -- Nix
  # strips write bits from every store path once it's registered, so by
  # the time this reaches a base image it's back to whatever `mkdir`'s
  # own default mode was. Confirmed live 2026-07-15 (camelot/hardened-
  # images mysql, nix9): mysqld's InnoDB failed with "Can't create/write
  # to file '/tmp/ibGUvuwd' (OS errno 13 - Permission denied)" -- the
  # SAME store-immutability class of bug as ibdata1's original mode
  # problem, just never exercised by rabbitmq/eventBridge's own
  # boot-checks. Each base builder below re-chmods /tmp via its own
  # fakeRootCommands (fakeroot-assisted tar assembly, the only place a
  # chmod actually lands -- see mkPackageImage's writablePaths comment
  # for the full explanation of why). Mode 1777 (not tied to any one
  # `user`) because /tmp must be writable by whichever uid the consuming
  # image happens to run as.
  tmpStub = pkgs.runCommand "pleme-io-tmp-stub" {} ''
    mkdir -p $out/tmp
    chmod 1777 $out/tmp
  '';

  # /etc/passwd and /etc/group arrive via `contents` (nonrootPasswd/
  # nonrootGroup above), which `dockerTools.buildLayeredImage` merges
  # through `symlinkJoin` -- so in the pre-tar customisation layer they
  # are SYMLINKS into /nix/store, not real files. nixpkgs' own tar step
  # uses `--hard-dereference` (hard LINKS only) with no `-h`/
  # `--dereference` flag, so those symlinks are stored in the final
  # layer tar VERBATIM, pointing at an absolute /nix/store/<hash>/...
  # path. Confirmed 2026-07-18 via direct nixpkgs/pkgs/build-support/
  # docker/default.nix read (the customisationLayer + tar-assembly
  # code), prompted by a real pre-hardened-base.nix comment (attic-
  # server-image's OLD hand-rolled image) stating plainly: "containerd
  # 2.x rejects Nix symlinks that point into /nix/store/ as 'path
  # escapes from parent'" on its target ("ro") platform. Whether THIS
  # specific target platform hits that exact containerd check is not
  # yet empirically deploy-verified (no reachable builder this pass),
  # but the symlink-into-/nix/store SHAPE itself is proven, not
  # speculative -- and every hardened-base.nix consumer inherits it via
  # commonContents, not just attic-server. Realized as REAL files via
  # `doca harden-rootfs` below (same fakeRootCommands mechanism already
  # fixing /tmp's mode -- the only place in this pipeline a mutation
  # actually lands, since Nix strips write bits from every registered
  # store path) so no consumer has to work around this individually.
  mkTmpWritableFakeRootCommands = "${doca}/bin/oci-push harden-rootfs --root .";

  commonContents = [
    cacert
    nonrootPasswd
    nonrootGroup
    tmpStub
  ];

  # ═══════════════════════════════════════════════════════════════════
  # "shell in distroless" — the wolfi replacement's two ingredients
  # ═══════════════════════════════════════════════════════════════════
  #
  # A GLIBC-ONLY `/bin/sh` (nixpkgs `dash` — a tiny POSIX shell, ~200 KiB,
  # a near-nil CVE surface) instead of busybox. dash ships its binary as
  # `dash`, not `sh`, so we contribute an explicit `/bin/sh` symlink; the
  # referenced dash store path is pulled into the image closure by Nix's
  # own symlink-target reference scan — exactly as busybox's `/bin/sh`
  # applet symlink is under `mkWolfiBase`. `harden-rootfs` (above) only
  # materializes `/etc/passwd` + `/etc/group`, so this `/bin/sh` symlink
  # into `/nix/store/…dash` is the SAME shape wolfi already ships and runs
  # in production (cnpg/mysql/clickhouse/redis bases) — proven-safe on the
  # current targets, not novel.
  #
  # Why dash and not busybox: busybox carries a recurring CVE stream (e.g.
  # CRITICAL CVE-2022-48174) that a downstream re-scanner flags on the
  # *shipped* image; a grype-ignore/VEX never clears their scan — only
  # genuine removal does. dash removes it.
  shDashShim = pkgs.runCommand "pleme-io-sh-dash" {} ''
    mkdir -p $out/bin
    ln -s ${pkgs.dash}/bin/dash $out/bin/sh
  '';

  # ═══════════════════════════════════════════════════════════════════
  # Base image builders
  # ═══════════════════════════════════════════════════════════════════

  # Every base builder attaches its own `contents` list as a passthru
  # attribute (`base.contents`) — this is the load-bearing seam that lets
  # `mkPackageImage`/`mkVendorRewrap` below compute a CORRECT closure SBOM.
  # Reason: a `dockerTools.buildLayeredImage` OUTPUT is a gzip-compressed
  # tarball, and Nix's own reference-scanner (which populates what
  # `nix path-info -r` / `nix-store -q --references` can see) works by
  # finding literal store-path hash substrings inside an output's BYTES —
  # substrings that gzip compression destroys. So `nix path-info -r` on
  # the FINAL image tarball sees almost nothing, even though the image is
  # built from a rich closure. Passing the pre-compression `contents`
  # list straight to `pkgs.closureInfo` sidesteps the bug entirely
  # (closureInfo emits its own store-paths as an UNCOMPRESSED text file,
  # so ITS references ARE scanned correctly) — but that only works if
  # each layer of composition (base -> package image) carries its real
  # contents forward, hence this passthru chain. Confirmed live 2026-07-14
  # against camelot/hardened-images' rabbitmq image: a naive
  # `nix path-info -r` on the shipped `rabbitmq.tar.gz` returned exactly
  # ONE component (itself); this fix is what a correct SBOM needs.

  # distroless-static: TLS roots + nonroot user. No libc. For statically
  # linked binaries.
  mkDistrolessStaticBase = {
    name ? "pleme-io-distroless-static",
    tag ? "latest",
    extra ? [],
  }: let
    contents = commonContents ++ extra;
  in (dockerTools.buildLayeredImage {
    inherit name tag contents;
    fakeRootCommands = mkTmpWritableFakeRootCommands;
    enableFakechroot = true;
    config = {
      User = "${toString nonrootUid}:${toString nonrootGid}";
      WorkingDir = "/";
    };
  }) // { inherit contents; };

  # distroless-glibc: distroless-static + glibc for dynamically linked
  # binaries. Still no shell.
  mkDistrolessGlibcBase = {
    name ? "pleme-io-distroless-glibc",
    tag ? "latest",
    extra ? [],
  }: let
    contents = commonContents ++ [ pkgs.glibc ] ++ extra;
  in (dockerTools.buildLayeredImage {
    inherit name tag contents;
    fakeRootCommands = mkTmpWritableFakeRootCommands;
    enableFakechroot = true;
    config = {
      User = "${toString nonrootUid}:${toString nonrootGid}";
      WorkingDir = "/";
      Env = [
        "LD_LIBRARY_PATH=${pkgs.glibc}/lib"
      ];
    };
  }) // { inherit contents; };

  # wolfi shim: in the pleme-io variant we use nixpkgs' apk-compatible
  # glibc + busybox-nonroot to get a closer analog of Chainguard wolfi
  # semantics (non-root default, readable rootfs, minimal apk surface).
  # Real wolfi-upstream images can slot in via `mkVendorRewrap` instead
  # when the consumer prefers Chainguard's attestations.
  mkWolfiBase = {
    name ? "pleme-io-wolfi-shim",
    tag ? "latest",
    extra ? [],
  }: let
    contents = commonContents ++ [ pkgs.glibc pkgs.busybox ] ++ extra;
  in (dockerTools.buildLayeredImage {
    inherit name tag contents;
    fakeRootCommands = mkTmpWritableFakeRootCommands;
    enableFakechroot = true;
    config = {
      User = "${toString nonrootUid}:${toString nonrootGid}";
      WorkingDir = "/";
      Env = [
        "LD_LIBRARY_PATH=${pkgs.glibc}/lib"
        "PATH=/bin:/usr/bin"
      ];
    };
  }) // { inherit contents; };

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
    # Merged OVER the default io.pleme.rewrap.*/org.opencontainers.image.*
    # set below -- see mkPackageImage's own `labels` doc comment.
    labels ? {},
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
    imageContents = [ extractedBinary ] ++ extraContents;
  in (dockerTools.buildLayeredImage {
    name = publishName;
    tag = publishTag;
    fromImage = base;
    contents = imageContents;
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
      } // labels;
    };
  }) // {
    # See the passthru-chain comment above `mkDistrolessStaticBase` — the
    # extracted upstream binary is opaque (pulled bytes, not a Nix
    # derivation with a package closure of its own), so this closure
    # covers the HARDENED BASE's real Nix packages only. That's still a
    # strict improvement over the image tarball's own (near-empty,
    # compression-blinded) references.
    closureInfo = pkgs.closureInfo { rootPaths = (base.contents or []) ++ imageContents; };
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
    #
    # Also chmods u+rwX here, not just chown -- confirmed live 2026-07-15
    # (camelot/hardened-images mysql, 3 straight failed attempts): ANY
    # `chmod` run *inside* a derivation that populates `extraContents`
    # (e.g. a `runCommand` pre-baking a data directory) is undone the
    # moment that derivation's output is registered in the Nix store --
    # Nix strips write bits from every store path as part of its own
    # store-immutability guarantee, REGARDLESS of what the build script
    # itself set on `$out`. A derivation-level `chmod -R u+rwX $out/...`
    # is therefore a no-op by the time this function runs: the file is
    # back to read-only long before `fakeRootCommands` ever sees it. This
    # `fakeRootCommands` step is the correct (and only) place a chmod can
    # land, because it runs as part of fakeroot-assisted TAR ASSEMBLY,
    # not as a real store-path mutation -- the same reason `chown` here
    # already works while an in-derivation chown never would.
    writablePaths ? [],
    # Merged OVER the default io.pleme.rebuild.*/org.opencontainers.image.*
    # set below -- a caller-supplied key of the same name wins. Added
    # 2026-07-18: without this, any consumer with real custom labels
    # (Kenshi's io.kenshi.* markers, a full mkStandardLabels set, an
    # extraLabels passthrough) couldn't call mkPackageImage literally
    # without silently losing them -- confirmed live, several fleet
    # consumers stayed on a direct buildLayeredImage call for exactly
    # this reason during the 2026-07-18 hardening pass.
    labels ? {},
    # Extra fakeroot-stage commands, appended after the writablePaths chown.
    #
    # Exists for the same reason writablePaths does: fakeroot-assisted tar
    # assembly is the ONLY place a mutation survives, because Nix strips write
    # bits and drops metadata when a store path is registered. The concrete need
    # is a file capability, e.g. setcap cap_net_bind_service=+ep so a non-root
    # binary can bind a privileged port without the deployment granting anything.
    # An in-derivation setcap is a no-op by the time this function runs, exactly
    # as an in-derivation chmod is.
    #
    # Anything passed here runs under fakeroot with no real privilege, so it can
    # set metadata and cannot escape the build.
    extraFakeRootCommands ? "",
  }: let
    imageContents = [ package ] ++ extraContents;
  in (dockerTools.buildLayeredImage {
    name = publishName;
    tag = publishTag;
    fromImage = base;
    contents = imageContents;
    fakeRootCommands = lib.concatStringsSep "\n" (
      (map (p: "chown -R ${user} ${p} && chmod -R u+rwX ${p}") writablePaths)
      ++ lib.optional (extraFakeRootCommands != "") extraFakeRootCommands
    );
    enableFakechroot = writablePaths != [] || extraFakeRootCommands != "";
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
      } // labels;
    };
  }) // {
    # See the passthru-chain comment above `mkDistrolessStaticBase` — the
    # compression-blind-spot fix. `base.contents` carries the hardened
    # base's own real Nix packages forward so the closure covers the
    # WHOLE shipped image (base + package + extraContents), not just
    # the package layer.
    closureInfo = pkgs.closureInfo { rootPaths = (base.contents or []) ++ imageContents; };
  };

  # ═══════════════════════════════════════════════════════════════════
  # mkDistrolessImage — "shell in distroless": the wolfi replacement
  # ═══════════════════════════════════════════════════════════════════
  #
  # The Pillar 8 destination for an image that needs a shell and/or a few
  # bare-invoked entrypoint tools but must NOT carry busybox. Where a
  # consumer would previously reach for `base = bases.wolfi`
  # (distroless-glibc + busybox), it instead DECLARES what it actually
  # needs:
  #
  #   mkDistrolessImage {
  #     service = "cnpg-postgresql";
  #     package = postgresqlDrv;
  #     shell = true;                              # glibc-only dash /bin/sh
  #     entrypointTools = [ pkgs.coreutils pkgs.barman-cloud ];
  #     entrypoint = [ "${postgresqlDrv}/bin/postgres" ];
  #     publishName = "ghcr.io/pleme-io/cnpg-postgresql";
  #     publishTag = version;
  #   }
  #
  # Result = distroless-glibc + (optional dash /bin/sh) + (declared tools)
  #        = wolfi's functionality, WITHOUT busybox.
  #
  # `shell = false` + `entrypointTools = []` (the defaults) is exactly
  # `bases.distroless-glibc` wrapped around `package` — plain distroless,
  # zero shell, zero extra closure (it reuses the shared base derivation,
  # so it is byte-identical to and cache-shared with every other plain
  # distroless image).
  #
  # The shell + tools live in the hardened BASE layer (via
  # `mkDistrolessGlibcBase`'s `extra`), so they inherit the same
  # /tmp + passwd/group `harden-rootfs` treatment glibc already gets, and
  # the `closureInfo`/SBOM passthru on `mkPackageImage` covers them for
  # free. A `PATH=/bin:/usr/bin` is set (matching `mkWolfiBase`'s own PATH)
  # so bare-invoked tools + /bin/sh resolve; `LD_LIBRARY_PATH` is inherited
  # from the base config (buildLayeredImage merges `fromImage` Env).
  #
  # This is the modularized form the org doctrine names: the third
  # shell-needing image declares `{ package; shell; entrypointTools }`
  # instead of re-deriving a wolfi rewrap.
  mkDistrolessImage = {
    service,                 # logical name (labels only)
    package,                 # the nixpkgs derivation to package
    publishName,
    publishTag,
    entrypoint,
    cmd ? [],
    # "shell in distroless": add a glibc-only dash as /bin/sh. Off by
    # default — an image that doesn't bare-invoke a shell stays pure
    # distroless.
    shell ? false,
    # Exactly what the entrypoint bare-invokes. Each item is EITHER a
    # catalog BUNDLE NAME (a string — "coreutils", "textproc", "process",
    # "net", "archive", "findutils", "which"; see ./distroless-toolset.nix)
    # OR a RAW package derivation for an image-specific tool with no
    # generic bundle (a DB's `barman-cloud` CLI, a vendor binary). Bundle
    # names expand to their minimal package list; raw packages pass through
    # unchanged. Their bins land on /bin:/usr/bin via the PATH below.
    # Declare the minimum — every tool is closure the scanner sees. SEED
    # this list with the static enumerator (./entrypoint-enumerate.nix)
    # then confirm minimal via the boot-check (theory/NIX-HARDENING.md
    # §III.4).
    entrypointTools ? [],
    env ? [],
    exposedPorts ? {},
    volumes ? {},
    workdir ? "/",
    user ? "${toString nonrootUid}:${toString nonrootGid}",
    extraContents ? [],
    writablePaths ? [],
    labels ? {},
  }: let
    shellContents = lib.optional shell shDashShim;
    # Expand bundle names → packages; raw packages pass through. An unknown
    # bundle name is a `nix eval`-time error (see resolveTools), never a
    # silent "command not found" at container boot.
    resolvedTools = toolset.resolveTools entrypointTools;
    baseExtra = shellContents ++ resolvedTools;
    # Reuse the shared plain base when nothing is added (byte-identical,
    # cache-shared); otherwise a per-image base carrying the declared
    # shell + tools, hardened exactly like glibc.
    base = mkDistrolessGlibcBase (lib.optionalAttrs (baseExtra != []) { extra = baseExtra; });
    needsPath = shell || entrypointTools != [];
    # dedup-friendly: a consumer that also passes PATH wins (last-listed).
    pathEnv = lib.optional needsPath "PATH=/bin:/usr/bin";
  in mkPackageImage {
    inherit service package publishName publishTag entrypoint cmd
      exposedPorts volumes workdir user extraContents writablePaths
      labels base;
    env = pathEnv ++ env;
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

  # "Shell in distroless" — declare `{ package; shell; entrypointTools }`
  # to get distroless-glibc + (optional dash /bin/sh) + declared tools,
  # i.e. wolfi's functionality WITHOUT busybox. The default (shell=false,
  # no tools) is plain distroless-glibc.
  inherit mkDistrolessImage;

  # The tool-bundle catalog itself — `distrolessToolset.bundles.coreutils`
  # etc. — for a consumer that wants the raw package list of a bundle
  # (e.g. to compose it into a non-mkDistrolessImage `contents`).
  distrolessToolset = toolset;

  # Convention: reuse these UIDs across all pleme-io vendor images.
  inherit nonrootUid nonrootGid;

  # The passwd/group stubs, exported so a builder that assembles its own
  # contents list (lib/build/go/hardened-image.nix) reuses these exact files
  # rather than writing a second, drifting copy of the same three lines.
  inherit nonrootPasswd nonrootGroup;
}
