# hardened-image.nix — the COMPILE-SIDE half of the minimal-production-image
# standard for Go.
#
# WHY THIS EXISTS. substrate already has a mature RUNTIME-side story:
#   • lib/build/oci/hardened-base.nix  — distroless bases, nonroot uid 65532,
#     /etc/passwd + /etc/group stubs, mkPackageImage with an SBOM passthru.
#   • lib/build/go/distroless.nix      — the scratch/minimal base-contents ladder.
#   • lib/build/go/minimal-image-check.nix — layer-level conformance (no shell,
#     no libc, store-path ceiling, static INTERP check, exec smoke).
# What NONE of them do is constrain how the BINARY was compiled. Every one of
# them takes an already-built package on faith. So an image could pass the
# whole minimal-image gate while carrying a binary built with build IDs, full
# debug symbols, absolute source paths, and a libc dependency waiting to
# happen. This file closes that half, and then asserts it.
#
# THE MUSL QUESTION, ANSWERED HONESTLY. For Go the usual "use musl to escape
# glibc" reflex is a step BACKWARD. CGO_ENABLED=0 emits a binary with no libc
# at all — not musl, not glibc, nothing. That is strictly smaller and strictly
# less CVE surface than any musl-linked artifact, because the libc is simply
# absent from the closure rather than statically embedded in it. musl only
# earns its place when CGO is genuinely unavoidable (sqlite, a FIPS/BoringCrypto
# module, a vendored C dependency). So:
#
#   libc = "none"  (DEFAULT) — CGO_ENABLED=0, netgo + osusergo. Zero libc.
#   libc = "musl"           — CGO_ENABLED=1 under pkgsMusl, statically linked.
#                             The escape hatch, not the goal.
#   libc = "glibc"          — REJECTED at eval time. A dynamically-linked glibc
#                             binary cannot run on a scratch base, and the
#                             whole point of this builder is that it cannot
#                             silently produce one.
#
# netgo/osusergo are not cosmetic: without them Go's net and os/user packages
# prefer cgo resolvers, which is exactly how a "static" build acquires a libc
# dependency by accident.
#
# PIE AND STATIC ARE MUTUALLY EXCLUSIVE FOR GO, and this cost real CI runs to
# establish rather than assume. `-buildmode=pie` with CGO_ENABLED=0 uses
# INTERNAL linking and emits a binary with a dynamic INTERP segment — a PIE
# that wants ld.so. On a scratch base there is no ld.so, so the container does
# not start. The Linux conformance check caught exactly this: "binary has a
# dynamic INTERP segment — NOT static".
#
# Getting BOTH means static-PIE, which needs EXTERNAL linking, which needs a C
# toolchain. That is the musl lane. So the honest matrix is:
#
#   libc = "none"  pie = false   static, no libc, no ASLR of the text segment
#   libc = "musl"  pie = true    static-PIE, ASLR, musl statically embedded
#
# This qualifies the "CGO off is strictly better" claim above: CGO off wins on
# closure and CVE surface, and gives up PIE to do it. Which trade is right is a
# per-service call, which is why both lanes exist rather than one blessed path.
#
# TIER HONESTY. The image build and the conformance check need Linux (they
# unpack a real tarball and exec the real binary). On darwin these derivations
# EVALUATE but are built by the Linux CI runner. The musl static-PIE lane is
# implemented and NOT yet proven on a Linux builder.
#
# Usage:
#   hardened = import "${substrate}/lib/build/go/hardened-image.nix" { };
#   img = hardened.mkHardenedGoImage pkgs {
#     name = "uam";
#     src = ./.;
#     vendorHash = "sha256-...";
#     version = "1.2.3";
#     ports = { http = 8080; };
#   };
#   # img            — the OCI tarball
#   # img.binary     — the hardened binary derivation
#   # img.checks     — { conformance, vuln }
{ }:
let
  # ── compile-time hardening ────────────────────────────────────────────
  #
  # Every flag here has a reason and a cost:
  #   -trimpath      strips absolute build paths. Reproducibility + it stops
  #                  the binary leaking the builder's filesystem layout.
  #   -s -w          drop the symbol table and DWARF. Smaller, and a stripped
  #                  binary is meaningfully harder to work with in-place.
  #   -buildid=      empty build id, for bit-reproducibility. NOT passed here:
  #                  buildGoModule appends it by default and warns on a
  #                  duplicate. The check still asserts the property.
  #   -buildmode=pie ASLR for the text segment. Costs a little startup time
  #                  and a little size; worth it for a network-facing service.
  mkHardenedGoBinary = pkgs: {
    name,
    src,
    version ? "0.0.0",
    vendorHash ? null,
    subPackages ? null,
    # "none" (pure Go, no libc — default), "musl" (static musl, CGO on).
    # "glibc" is rejected; see the header.
    libc ? "none",
    # PIE is available on the MUSL lane, not the pure-Go one. See the header:
    # -buildmode=pie with CGO off yields a dynamically-linked PIE that needs
    # ld.so, which a scratch base does not have. Proven on Linux, not guessed.
    pie ? (libc == "musl"),
    tags ? [],
    ldflagsExtra ? [],
    # Inject a version string into a package variable, e.g.
    #   versionPath = "main.version";
    versionPath ? null,
    doCheck ? true,
    extraAttrs ? {},
  }:
  let
    lib = pkgs.lib;

    _libcOk =
      if libc == "glibc"
      then throw ''
        mkHardenedGoBinary: libc = "glibc" is not supported by design.

        A dynamically-linked glibc binary cannot run on the scratch base this
        builder targets, and silently producing one would defeat the gate.
        Use libc = "none" (CGO_ENABLED=0, no libc at all) or, when CGO is
        genuinely required, libc = "musl" (statically linked).
      ''
      else if libc != "none" && libc != "musl"
      then throw "mkHardenedGoBinary: libc must be \"none\" or \"musl\", got \"${libc}\""
      else true;

    # pkgsMusl only when we actually need a C toolchain. For libc = "none"
    # the ordinary package set is correct — CGO is off, so the stdenv's libc
    # never enters the picture.
    buildPkgs = if libc == "musl" then pkgs.pkgsMusl else pkgs;

    cgoEnabled = if libc == "musl" then "1" else "0";

    # netgo/osusergo force the pure-Go resolvers. Without them a CGO_ENABLED=0
    # build still compiles, but any consumer that flips CGO on inherits libc
    # lookups; pinning the tags makes the property stick.
    hardenedTags = [ "netgo" "osusergo" ] ++ tags;

    versionLdflags =
      if versionPath != null then [ "-X" "${versionPath}=${version}" ] else [];

    # Static linking. For libc = "none" Go is already static; the explicit
    # extldflags matter only on the musl path, where the external linker runs.
    staticLdflags =
      if libc == "musl"
      then [ "-linkmode=external" ]
           ++ (if pie then [ ''-extldflags "-static-pie"'' ] else [ ''-extldflags "-static"'' ])
      else [];

    # -buildid= is NOT listed here: buildGoModule already appends it unless an
    # explicit -buildid= is present, and warns when you pass it yourself
    # (nixpkgs build-support/go/module.nix). -s -w it does NOT set, so those
    # stay ours. The conformance check asserts the resulting properties on the
    # artifact rather than trusting either layer.
    hardenedLdflags =
      [ "-s" "-w" ] ++ versionLdflags ++ staticLdflags ++ ldflagsExtra;

    # -buildmode=pie goes in GOFLAGS, NOT in a `buildFlags` attribute.
    # buildGoModule has no buildFlags: it assembles its go-build flags from
    # `tags` and `ldflags` only, so a buildFlags list is silently swallowed by
    # mkDerivation and the binary comes out EXEC instead of DYN. The first Linux
    # run of the conformance check is what caught that, which is the entire
    # argument for asserting properties on the artifact rather than trusting the
    # flags we think we passed.
    hardenedGoflags = lib.optionals pie [ "-buildmode=pie" ];
  in
  assert _libcOk;
  buildPkgs.buildGoModule ({
    pname = name;
    inherit version src vendorHash;

    # CGO_ENABLED is a top-level attr, NOT an `env` key — the exact mirror of
    # the GOFLAGS rule documented below. buildGoModule declares
    # `CGO_ENABLED ? go.CGO_ENABLED` as an argument and then `inherit`s it
    # straight onto mkDerivation (nixpkgs build-support/go/module.nix:40,170),
    # so setting it in `env` too makes both sides define it and eval dies with
    # "the env attribute set cannot contain any attributes passed to
    # derivation ... overlapping: CGO_ENABLED".
    #
    # The two knobs therefore go opposite ways, which is the whole trap:
    # GOFLAGS is written into `env` BY buildGoModule (so we must never pass it
    # top-level), CGO_ENABLED is written top-level BY buildGoModule (so we must
    # never pass it in `env`). Read the nixpkgs source for the direction rather
    # than guessing from symmetry.
    CGO_ENABLED = cgoEnabled;

    tags = hardenedTags;
    ldflags = hardenedLdflags;
    inherit doCheck;

    # -buildmode=pie has no home in buildGoModule's own vocabulary: there is no
    # buildFlags attribute, and passing GOFLAGS as a top level attr collides
    # with the GOFLAGS buildGoModule itself writes into `env` ("the env
    # attribute set cannot contain any attributes passed to derivation").
    # Appending in preBuild is what actually reaches go build without fighting
    # either mechanism. Unlike the -trimpath append that was removed from this
    # file, this flag is NOT something buildGoModule manages, so there is
    # nothing to duplicate.
    preBuild = lib.optionalString pie ''
      export GOFLAGS="''${GOFLAGS:-} -buildmode=pie"
    '';

    # -trimpath is NOT set here. buildGoModule already injects it into GOFLAGS
    # whenever allowGoReference is false (nixpkgs build-support/go/module.nix),
    # and warns on a duplicate. It also deliberately strips -trimpath for the
    # check phase, because tests may reference assets by path; re-adding it
    # ourselves would fight that. Stating allowGoReference explicitly is what
    # actually pins the property.
    allowGoReference = false;

    passthru = {
      hardened = {
        inherit libc pie;
        cgo = cgoEnabled;
        tags = hardenedTags;
        ldflags = hardenedLdflags;
        goflags = hardenedGoflags;
      };
    };
  } // (lib.optionalAttrs (subPackages != null) { inherit subPackages; })
    // extraAttrs);

  # ── govulncheck gate ──────────────────────────────────────────────────
  #
  # govulncheck is Go-specific and reachability-aware: it reports a
  # vulnerability only when the vulnerable SYMBOL is actually reachable from
  # this module's call graph. That makes it far less noisy than a generic
  # CVE scanner over the dependency list, and it is the right gate for a Go
  # artifact. grype/trivy over the image remain useful for the OS layer —
  # which, on a scratch base, is nearly empty by construction.
  mkGoVulnCheck = pkgs: {
    name,
    src,
    # Fail the build on a reachable vulnerability. Set false to report only.
    strict ? true,
  }:
  pkgs.runCommand "govulncheck-${name}"
    {
      nativeBuildInputs = [ pkgs.govulncheck pkgs.go pkgs.cacert ];
      inherit src;
      strictMode = if strict then "1" else "0";
    }
    ''
      set -uo pipefail
      export HOME=$TMPDIR
      export GOFLAGS=-mod=mod
      export GOPATH=$TMPDIR/go
      cp -r "$src" ./source
      chmod -R u+w ./source
      cd ./source

      echo "== govulncheck: ${name} =="
      # govulncheck needs the module graph. In a sandbox with no network the
      # honest outcome is "could not analyse", which must not masquerade as a
      # clean result; it is reported and, under strict, fails.
      if govulncheck ./... > "$TMPDIR/vuln.txt" 2>&1; then
        echo "  no reachable vulnerabilities"
        mkdir -p "$out"
        cp "$TMPDIR/vuln.txt" "$out/govulncheck.txt"
        echo "${name}: govulncheck PASS" > "$out/result"
        exit 0
      fi

      echo "  govulncheck reported findings or could not complete:"
      sed 's/^/    /' "$TMPDIR/vuln.txt" | head -n 60
      if [ "$strictMode" = "1" ]; then
        echo "== ${name}: govulncheck FAILED =="
        exit 1
      fi
      mkdir -p "$out"
      cp "$TMPDIR/vuln.txt" "$out/govulncheck.txt"
      echo "${name}: govulncheck NON-STRICT (findings present)" > "$out/result"
    '';
  # ── the image ─────────────────────────────────────────────────────────
  #
  # Deliberately NOT a new base-image implementation. The base contents come
  # from hardened-base.nix (nonroot passwd/group, uid 65532) and the ladder
  # from distroless.nix, exactly as mkGoDockerImage uses them. What this adds
  # over mkGoDockerImage is that the binary is built by mkHardenedGoBinary
  # rather than accepted on faith, and the resulting image is wired to its own
  # conformance + vulnerability checks.
  mkHardenedGoImage = pkgs: args @ {
    name,
    src,
    version ? "0.0.0",
    vendorHash ? null,
    subPackages ? null,
    libc ? "none",
    pie ? (libc == "musl"),
    tags ? [],
    ldflagsExtra ? [],
    versionPath ? null,
    # A musl build is a cross-build; its test binaries cannot run on the
    # builder, so checks are off on that lane unless asked for.
    doCheck ? (libc != "musl"),
    tag ? "latest",
    architecture ? "amd64",
    ports ? {},
    env ? [],
    # Outbound TLS needs the CA bundle. A service that makes no outbound TLS
    # call can set this false and ship a binary-only image.
    withCacert ? true,
    labels ? {},
    entrypoint ? null,
    workDir ? "/",
    vulnGate ? true,
    # NOT strict by default: govulncheck needs the vulnerability database, and
    # a nix build sandbox has no network. Strict-by-default would fail every
    # build for a reason that has nothing to do with the code. Turn it on where
    # the gate runs with network, which is CI.
    vulnStrict ? false,
    maxStorePaths ? 5,
    execSmoke ? null,
    created ? "1970-01-01T00:00:01Z",
    # Threaded to the conformance check, whose body is tlisp. Required there,
    # so a consumer that wants the check must supply it.
    tataraScript ? null,
  }:
  let
    lib = pkgs.lib;
    hardenedBase = import ../oci/hardened-base.nix { inherit pkgs; };

    binary = mkHardenedGoBinary pkgs {
      inherit name src version vendorHash subPackages libc pie tags
              ldflagsExtra versionPath doCheck;
    };

    # cacert plus the passwd/group stubs. The stubs are what let a runtime
    # enforce runAsNonRoot against a NAMED user and what stop NSS lookups
    # failing inside the container; they cost two tiny text files.
    baseContents =
      (lib.optionals withCacert [ pkgs.cacert ])
      ++ [ hardenedBase.nonrootPasswd hardenedBase.nonrootGroup ];

    exposedPorts = lib.mapAttrs' (_: port:
      lib.nameValuePair "${toString port}/tcp" {}
    ) ports;

    sslEnv = lib.optionals withCacert
      [ "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];

    hardenedLabels = {
      # The existing minimal-image-check asserts this exact label, so setting
      # it here keeps this builder inside that gate rather than beside it.
      "com.pleme.image.minimal" = "true";
      "com.pleme.image.hardened" = "true";
      "com.pleme.go.libc" = libc;
      "com.pleme.go.pie" = if pie then "true" else "false";
      "org.opencontainers.image.version" = version;
      "org.opencontainers.image.title" = name;
    } // labels;

    image = pkgs.dockerTools.buildLayeredImage {
      inherit name tag created architecture;
      contents = baseContents;
      config = {
        Entrypoint = if entrypoint != null then entrypoint else [ "/bin/${name}" ];
        # Numeric, not the name. A Kubernetes runAsNonRoot admission check
        # cannot resolve a username against the image, so a named user makes
        # the pod fail to start with a confusing error.
        User = "${toString hardenedBase.nonrootUid}:${toString hardenedBase.nonrootGid}";
        WorkingDir = workDir;
        Env = sslEnv ++ env;
        ExposedPorts = exposedPorts;
        Labels = hardenedLabels;
      };
      # The binary lands at /bin/<name> so the entrypoint is a stable path
      # rather than a store path that changes on every rebuild.
      extraCommands = ''
        mkdir -p bin
        ln -s ${binary}/bin/${name} bin/${name}
      '';
    };

    conformance = mkHardenedGoImageCheck pkgs {
      inherit name image binary maxStorePaths execSmoke pie tataraScript;
      binName = name;
      expectUser = "${toString hardenedBase.nonrootUid}:${toString hardenedBase.nonrootGid}";
    };

    vuln = lib.optionalAttrs vulnGate {
      vuln = mkGoVulnCheck pkgs { inherit name src; strict = vulnStrict; };
    };
  in
  image // {
    inherit binary;
    checks = { inherit conformance; } // vuln;
    hardened = binary.passthru.hardened;
  };

  # ── conformance ───────────────────────────────────────────────────────
  #
  # Composes rather than replaces: the existing mkMinimalImageCheck already
  # proves no-shell / no-libc / store-path-ceiling / static / exec-smoke, so
  # this runs it and then adds the properties it does not cover — the ones
  # that separate "minimal" from "hardened":
  #   • the image runs as a NUMERIC non-root user
  #   • no setuid/setgid bits anywhere in the layers
  #   • the binary is PIE when PIE was requested
  #   • the binary carries no build id and no symbol table
  mkHardenedGoImageCheck = pkgs: {
    name,
    image,
    binary ? null,
    binName ? name,
    expectUser,
    pie ? true,
    maxStorePaths ? 4,
    execSmoke ? null,
    # Forwarded to mkMinimalImageCheck. A Rust image passes [ ".dep-v0" ] so
    # the cargo-auditable dependency document -- the only thing that makes its
    # crate tree visible to trivy at all -- cannot be stripped away silently.
    requireSections ? [ ],
    # tatara-script derivation, supplied by the consumer exactly as
    # lib/build/scripting/tatara-script.nix takes `tataraLisp`. substrate does
    # not own the tatara-lisp input; a repo that wants this check passes it in.
    # Without it the check cannot run, and that is a hard error rather than a
    # silent fallback to shell.
    tataraScript ? null,
  }:
  let
    minimalCheck = (import ./minimal-image-check.nix { }).mkMinimalImageCheck pkgs {
      inherit name image binary binName maxStorePaths execSmoke requireSections;
      expectStatic = true;
    };
    binPath = if binary != null then "${binary}/bin/${binName}" else "";
    _ = if tataraScript == null
        then throw ''
          mkHardenedGoImageCheck: `tataraScript` is required.

          The conformance body is hardened-image-check.tlisp, not shell. Pass
          the tatara-lisp package the same way mkTataraScript takes it:

            tataraScript = inputs.tatara-lisp.packages.''${system}.tatara-script;
        ''
        else true;
  in
  assert _;
  pkgs.runCommand "hardened-image-check-${name}"
    {
      nativeBuildInputs = [ pkgs.gnutar pkgs.gzip pkgs.binutils pkgs.coreutils tataraScript ];
      inherit image minimalCheck;
      IMAGE_DIR = "image-unpacked";
      BIN_PATH = binPath;
      EXPECT_USER = expectUser;
      EXPECT_PIE = if pie then "1" else "0";
      checkScript = ./hardened-image-check.tlisp;
    }
    ''
      mkdir -p "$IMAGE_DIR" "$out"
      tar xf "$image" -C "$IMAGE_DIR" 2>/dev/null || tar xzf "$image" -C "$IMAGE_DIR"
      export IMAGE_DIR="$PWD/$IMAGE_DIR"
      echo "minimal conformance: $(cat "$minimalCheck/result")"
      # NOT piped into tee: a pipeline's status is the LAST command's, so
      # `tatara-script | tee` would report tee's success and let a failing gate
      # pass silently. Write the report, then replay it, then let the real exit
      # code stand.
      set -o pipefail
      if ! tatara-script "$checkScript" > "$out/report.txt" 2>&1; then
        cat "$out/report.txt"
        exit 1
      fi
      cat "$out/report.txt"
      echo "${name} hardened-image conformance: PASS" > "$out/result"
    '';

in
{
  inherit mkHardenedGoBinary mkGoVulnCheck mkHardenedGoImage mkHardenedGoImageCheck;
}
