# toolchain.nix — THE fleet Go compiler. The Go answer to fenix.
#
# WHY A TOOLCHAIN PROVIDER AT ALL, WHEN NIXPKGS SHIPS `go`. Because a consumer's
# nixpkgs pin decides its Go version, and therefore decides the stdlib CVE set of
# every Go binary it produces — including binaries whose SOURCE it does not own.
# That is not hypothetical; it is a measured incident, and it is the reason this
# file is now WIRED rather than merely present. Recorded once here, in full,
# because the shape recurs:
#
#   2026-07-30. A downstream consumer's monorepo
#   builds a hardened DISTROLESS web-ui image through substrate's
#   mkStaticSpaImage. Its flake pins nixpkgs = nixos-24.05 (b134951, May 2024).
#   Trivy against the built image reported, against exactly ONE target —
#   nix/store/…-compat-sh-bin-sh/bin/sh, type gobinary:
#
#     Total: 48 (UNKNOWN 0, LOW 3, MEDIUM 30, HIGH 14, CRITICAL 1)
#       stdlib CVE-2025-68121 CRITICAL v1.22.8 -> fixed 1.24.13, 1.25.7, 1.26.0-rc.3
#              (crypto/tls: incorrect certificate validation on session resumption)
#       stdlib CVE-2025-61726 HIGH               -> fixed 1.24.12, 1.25.6 (net/url)
#
#   Every OTHER component scanned CLEAN: the static musl Rust server binary, the
#   SPA assets, the config, the CA roots. The ENTIRE CVE surface of a hardened
#   distroless image was one 152-line Go shim's stdlib — compat-sh, a shaped
#   /bin/sh that implements `sleep` and refuses everything else, which exists
#   only because the akeyless saas chart names /bin/sh in a preStop hook and a
#   distroless image has none. It cannot be deleted. Its source imports
#   fmt/os/strconv/strings/time and nothing else. It was vulnerable for exactly
#   one reason: nixos-24.05 ships go 1.22.8.
#
#   The same pin caused two sibling failures the same day: compat-sh's go.mod
#   `go 1.23` directive could not be satisfied (24.05's go is 1.22.8 with
#   GOTOOLCHAIN=local), and oci-push's edition-2024 Rust tree could not be built
#   by 24.05's cargo 1.77 until fenix was threaded to it. Three symptoms, one
#   cause: the consumer's nixpkgs is choosing the fleet's compilers.
#
# THE LOAD-BEARING INSIGHT, and the reason the fix is here and not in the source:
# a Go binary's stdlib CVE set is decided by the COMPILER, not by the `go`
# directive in go.mod. Building 152 unchanged lines with go 1.26.5 links a clean
# stdlib even while go.mod still says `go 1.22`. So this is a toolchain-provenance
# problem with a toolchain-provenance fix. No source edit closes it, and no
# scanner suppression is allowed to (standing operator bar: real 0-CVE only — no
# .trivyignore, no VEX, no --ignore-unfixed).
#
# HOW FENIX SOLVES THIS FOR RUST, PRECISELY, BECAUSE THE MIRROR IS THE DESIGN.
# fenix never compiles a compiler: its rustc/cargo BYTES are rust-lang's own
# prebuilt release tarballs, fetched as per-component fixed-output derivations
# (fenix lib/mk-toolchain.nix: `src = fetchurl { inherit (source) url sha256; }`),
# with version selection read out of a COMMITTED transcription of upstream's
# channel manifest (data/stable.json) — never resolved at eval. Independence from
# the consumer is STRUCTURAL: fenix evaluates against fenix's OWN nixpkgs, so the
# toolchain derivation is a function of (substrate's nixpkgs) × (fenix's committed
# hash tables) and the consumer's pin contributes nothing at all. substrate
# already threads exactly that through — flake.nix's `lib`, and
# lib/build/oci-push.nix's `{ fenix ? null, system ? null }` + a scoped
# `makeRustPlatform`. Read oci-push.nix's header: it documents this same class
# from the Rust side (a consumer on nixos-24.05/cargo 1.77.2 could not build
# edition-2024 AT ALL).
#
# WHAT THIS FILE MIRRORS, AND WHERE IT DELIBERATELY DIVERGES.
#   • Mirrored: version + hash as COMMITTED DATA (go-toolchain-pin.json, the
#     data/stable.json analogue). A bump is a two-field diff. No "latest".
#   • Mirrored: hashes transcribed from UPSTREAM's published manifest
#     (https://go.dev/dl/?mode=json&include=all), not from a local prefetch, so a
#     wrong hash is a re-checkable transcription error rather than a laundered
#     local download.
#   • Mirrored: `mkGoToolchain { version; hash; }` (overlay.nix) is the
#     `fenix.toolchainOf` analogue — and the hash is MANDATORY. fenix's own
#     signature falls back to `builtins.fetchurl` when sha256 is omitted, which
#     is a network fetch at EVAL time. That arm is not reproduced.
#   • DIVERGED, deliberately: we compile from the SOURCE tarball rather than
#     unpacking go.dev's prebuilt binaries — even though bootstrap.nix already
#     fetches those, and doing so would be the closer byte-level mirror of fenix.
#     The prebuilt toolchain lacks the iana-etc / mailcap / tzdata / GO_LDSO
#     patches below, and those patch Go's stdlib SOURCE: they change the runtime
#     lookup paths for /etc/services, MIME types and zoneinfo in EVERY binary the
#     fleet produces. Swapping to prebuilt is a fleet-wide RUNTIME change wearing
#     a build-plumbing label. It needs its own decision, not a ride-along.
#   • ABSENT, and not a gap: fenix's `targets.<triple>.rust-std`. Go's cross
#     story is GOOS/GOARCH on one toolchain at CGO_ENABLED=0 — there is no
#     per-target std to fetch. A genuine simplification, not a missing feature.
#   • MISSING, and honestly a gap: fenix regenerates data/*.json from upstream's
#     manifest via a bot. There is no equivalent here, so this pin is hand-bumped
#     and WILL rot. See the staleness ledger below — substrate becoming the new
#     bottleneck instead of the consumer's nixpkgs is a real risk, not a
#     rhetorical one.
#
# THE STALENESS LEDGER — read this before trusting the number in the pin.
# Measured 2026-07-30 against all 159 stdlib entries in Go's OWN vulnerability
# database (vuln.go.dev/index/modules.json, then each ID's OSV affected ranges):
#
#     go 1.25.9   13 known stdlib vulns   <- substrate's OWN pin until this commit
#     go 1.26.3    5                      <- substrate's own nixpkgs (6b31628)
#     go 1.26.4    2
#     go 1.25.12   0                      <- last clean point on the 1.25 line
#     go 1.26.5    0                      <- THE PIN
#
# Two things to take from that table. First, the previous pin was not merely
# behind: it carried 13 stdlib vulns, so migrating the incident consumer onto it
# would have traded 48 findings for a smaller NON-ZERO set and failed the standing
# bar. "Newer than the consumer" is not the requirement; "clean" is. Second,
# substrate's own nixpkgs is not clean either — so "just use nixpkgs' go" is not a
# fix for this class, only a slower version of the same bug. An explicit pin is
# the only thing that is deterministic by construction.
#
# GOTOOLCHAIN=local IS PINNED HERE, not left to buildGoModule. Upstream's go.env
# ships GOTOOLCHAIN=auto and nixpkgs copies it verbatim; the `local` pin lives
# only in buildGoModule's env. So every path that invokes `go` OUTSIDE
# buildGoModule — a devShell, `nix run`, mkGoTool's completion postInstall, the
# govulncheck gate — inherits `auto` and will DOWNLOAD a compiler from the module
# proxy the moment a go.mod asks for a newer one. Inside a nix sandbox that fails
# closed and looks fine; on a network-enabled runner it silently breaks HERMETIC
# SUPPLY CHAIN. Pinning it in the toolchain makes the property hold on every path
# rather than one. `--replace-fail` is deliberate: if upstream ever stops shipping
# that line, this build breaks loudly instead of quietly pinning nothing.
#
# TIER HONESTY, three separate claims that are easy to collapse into one.
#   1. "A consumer that takes this toolchain builds with the pinned version" —
#      truly-unrepresentable-otherwise. The version is data on the derivation;
#      there is no other value it could have.
#   2. "The fleet never builds below the CVE floor" — EVAL-REJECTED, a Nix throw
#      in mkHardenedGoBinary. Not a type error, and it only binds callers that go
#      through that builder. Other Go builders in this directory are not yet
#      floored (see docs/go/go-toolchain.md's ledger).
#   3. "0 CVE" — a claim about a DATE, not a property. The floor asserts "not
#      below the declared floor", never "clean", because the vulnerability
#      database moves and this file does not.
{
  lib,
  stdenv,
  fetchurl,
  replaceVars,
  buildPackages,
  pkgsBuildTarget,
  targetPackages,
  iana-etc,
  mailcap,
  tzdata,
  # ── the pin ─────────────────────────────────────────────────────────────
  # Defaults to the committed fleet pin. Overridable so `mkGoToolchain
  # { version; hash; }` (the fenix.toolchainOf analogue) is a parameter change
  # rather than a fork of this file — e.g. reproducing an older artifact, or
  # taking a security patch release ahead of a fleet-wide bump.
  pin ? builtins.fromJSON (builtins.readFile ./go-toolchain-pin.json),
  version ? pin.version,
  # SRI hash of go${version}.src.tar.gz, from go.dev's published manifest.
  hash ? pin.srcHash,
}:

let
  goBootstrap = buildPackages.callPackage ./bootstrap.nix { inherit pin; };

  targetCC = pkgsBuildTarget.targetPackages.stdenv.cc;
  isCross = stdenv.buildPlatform != stdenv.targetPlatform;

  # go_no_vendor_checks is the one patch that is version-gated: nixpkgs carries a
  # distinct 1.26 variant and the 1.23 one does not apply cleanly to a 1.26 tree.
  # Selecting it by minor here is what keeps a minor bump a pin edit instead of a
  # manual patch hunt — and an unknown minor is a THROW, not a silent fallback to
  # the older variant, because "the patch applied with fuzz" is exactly the
  # failure that only surfaces on the Linux builder, i.e. the slowest possible
  # place to discover it.
  noVendorChecksPatch =
    let mm = lib.versions.majorMinor version;
    in {
      "1.23" = ./patches/go_no_vendor_checks-1.23.patch;
      "1.24" = ./patches/go_no_vendor_checks-1.23.patch;
      "1.25" = ./patches/go_no_vendor_checks-1.23.patch;
      "1.26" = ./patches/go_no_vendor_checks-1.26.patch;
    }.${mm} or (throw ''
      toolchain.nix: no go_no_vendor_checks patch known for Go ${mm}.

      A Go minor bump is a two-field edit to go-toolchain-pin.json ONLY while the
      patch set still applies. Copy the matching patch from the fleet nixpkgs
      anchor and add it to the table in this file:

        <nixpkgs>/pkgs/development/compilers/go/go_no_vendor_checks-${mm}.patch

      Do not reuse an older variant on a hope.
    '');
in
stdenv.mkDerivation (finalAttrs: {
  pname = "go";
  inherit version;

  src = fetchurl {
    url = "https://go.dev/dl/go${finalAttrs.version}.src.tar.gz";
    inherit hash;
  };

  strictDeps = true;
  buildInputs =
    []
    ++ lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.libc.out ]
    ++ lib.optionals (stdenv.hostPlatform.libc == "glibc") [ stdenv.cc.libc.static ];

  depsBuildTarget = lib.optional isCross targetCC;
  depsTargetTarget = lib.optional stdenv.targetPlatform.isMinGW targetPackages.threads.package;

  postPatch = ''
    patchShebangs .
  '';

  # Byte-identical to the fleet nixpkgs anchor's own go patch set, on purpose.
  # These modify Go's stdlib SOURCE (lookup paths for /etc/services, MIME types,
  # zoneinfo, and the dynamic linker), so diverging from nixpkgs here changes
  # runtime behaviour for every Go binary the fleet ships. They are copied, not
  # re-derived — and iana-etc-1.25.patch was re-copied byte-exact in this commit
  # because the previous local copy had a trailing space stripped from a context
  # line, which is the kind of thing `patch` forgives with fuzz right up until
  # it does not.
  patches = [
    (replaceVars ./patches/iana-etc-1.25.patch { iana = iana-etc; })
    (replaceVars ./patches/mailcap-1.17.patch { inherit mailcap; })
    (replaceVars ./patches/tzdata-1.19.patch { inherit tzdata; })
    ./patches/remove-tools-1.11.patch
    noVendorChecksPatch
    ./patches/go-env-go_ldso.patch
  ];

  env = {
    inherit (stdenv.targetPlatform.go) GOOS GOARCH GOARM;
    GOHOSTOS = stdenv.buildPlatform.go.GOOS;
    GOHOSTARCH = stdenv.buildPlatform.go.GOARCH;
    GO386 = "softfloat";
    CGO_ENABLED =
      if (stdenv.targetPlatform.isWasi
          || (stdenv.targetPlatform.isPower64 && stdenv.targetPlatform.isBigEndian))
      then 0
      else 1;
    GOROOT_BOOTSTRAP = "${goBootstrap}/share/go";
  }
  // lib.optionalAttrs isCross {
    CC_FOR_TARGET = "${targetCC}/bin/${targetCC.targetPrefix}cc";
    CXX_FOR_TARGET = "${targetCC}/bin/${targetCC.targetPrefix}c++";
  };

  buildPhase = ''
    runHook preBuild
    export GOCACHE=$TMPDIR/go-cache
    if [ -f "$NIX_CC/nix-support/dynamic-linker" ]; then
      export GO_LDSO=$(cat $NIX_CC/nix-support/dynamic-linker)
    fi

    export PATH=$(pwd)/bin:$PATH

    ${lib.optionalString isCross ''
      export CC=${buildPackages.stdenv.cc}/bin/cc
      export GO_EXTLINK_ENABLED=${toString finalAttrs.env.CGO_ENABLED}
    ''}
    ulimit -a

    pushd src
    ./make.bash
    popd
    runHook postBuild
  '';

  preInstall = ''
    rm src/regexp/syntax/make_perl_groups.pl
  ''
  + (
    if (stdenv.buildPlatform.system != stdenv.hostPlatform.system) then
      ''
        mv bin/*_*/* bin
        rmdir bin/*_*
        ${lib.optionalString
          (!(finalAttrs.env.GOHOSTARCH == finalAttrs.env.GOARCH
             && finalAttrs.env.GOOS == finalAttrs.env.GOHOSTOS))
          ''
            rm -rf pkg/${finalAttrs.env.GOHOSTOS}_${finalAttrs.env.GOHOSTARCH} pkg/tool/${finalAttrs.env.GOHOSTOS}_${finalAttrs.env.GOHOSTARCH}
          ''
        }
      ''
    else
      lib.optionalString (stdenv.hostPlatform.system != stdenv.targetPlatform.system) ''
        rm -rf bin/*_*
        ${lib.optionalString
          (!(finalAttrs.env.GOHOSTARCH == finalAttrs.env.GOARCH
             && finalAttrs.env.GOOS == finalAttrs.env.GOHOSTOS))
          ''
            rm -rf pkg/${finalAttrs.env.GOOS}_${finalAttrs.env.GOARCH} pkg/tool/${finalAttrs.env.GOOS}_${finalAttrs.env.GOARCH}
          ''
        }
      ''
  );

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/go
    cp -a bin pkg src lib misc api doc go.env VERSION $out/share/go

    # HERMETIC SUPPLY CHAIN, pinned in the toolchain rather than in one builder.
    # See the header: upstream go.env ships GOTOOLCHAIN=auto, so every `go`
    # invocation OUTSIDE buildGoModule would fetch a compiler from the module
    # proxy on demand. --replace-fail so a future upstream that drops the line
    # breaks this build loudly instead of silently pinning nothing.
    substituteInPlace $out/share/go/go.env \
      --replace-fail 'GOTOOLCHAIN=auto' 'GOTOOLCHAIN=local'

    mkdir -p $out/bin
    ln -s $out/share/go/bin/* $out/bin
    runHook postInstall
  '';

  disallowedReferences = [ goBootstrap ];

  passthru = {
    inherit goBootstrap pin;
    # The floor this toolchain was pinned against, carried on the derivation so a
    # consumer can read it without re-parsing the pin file. mkHardenedGoBinary
    # asserts against it.
    cveFloor = pin.cveFloor;
    cveFloorMeasured = pin.cveFloorMeasured;
  };

  __structuredAttrs = true;

  meta = {
    changelog = "https://go.dev/doc/devel/release#go${lib.versions.majorMinor finalAttrs.version}";
    description = "Go programming language (built from source, fleet-pinned)";
    homepage = "https://go.dev/";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
    mainProgram = "go";
  };
})
