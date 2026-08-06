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
# THE COMPILER IS PART OF THE HARDENING, and until 2026-07-30 this file did not
# treat it that way. Every flag below constrains HOW the source is compiled;
# none of them constrained WHAT compiles it, so `buildPkgs.buildGoModule` took
# whatever `go` the consumer's nixpkgs happened to pin — and a Go binary's
# stdlib CVE set is decided by the compiler, not by go.mod. A consumer on
# nixos-24.05 (go 1.22.8) therefore shipped a "hardened distroless" image whose
# ENTIRE CVE surface was one 152-line Go shim's stdlib: 48 findings, 1 CRITICAL.
# Read lib/build/go/toolchain.nix's header for the full incident and the measured
# staleness ledger; read docs/go/go-toolchain.md for the operator face.
#
# Two things landed here as a result, and they are deliberately different tiers:
#
#   • A TOOLCHAIN SEAM. `goToolchain` is threaded per-derivation and applied as
#     `buildGoModule.override { go = …; }`, scoped to this build and nothing else
#     — the exact shape lib/build/oci-push.nix uses for fenix/makeRustPlatform,
#     for the same reason its header gives: a package-set-wide overlay would
#     rebuild every Go package in a consumer's closure, which is what
#     lib/build/rust/overlay.nix explicitly refuses to do for rustc/cargo.
#     `? null` with graceful fallback, so a caller that passes nothing keeps its
#     previous compiler.
#
#   • A CVE FLOOR. `goFloor` rejects, AT EVAL TIME, a build whose compiler is
#     older than the version go-toolchain-pin.json declares clean. It is asserted
#     against `drv.passthru.go.version` — the compiler that ACTUALLY compiled,
#     read back off the built derivation — and NOT against `pkgs.go.version`,
#     because nixpkgs aliases buildGoModule to a versioned builder and those two
#     can disagree. Unlike the seam, the floor is NOT default-off: a floor a
#     consumer can silently skip is decoration.
#
# TIER HONESTY, and do not round these up.
#   • The floor is EVAL-REJECTED (a Nix throw), not truly-unrepresentable. A Nix
#     function cannot make an old compiler unrepresentable; it can only refuse to
#     return a derivation built by one. `goFloor = null` is a real escape hatch
#     and it is visible in a diff by design.
#   • The floor asserts "not below the declared floor". It does NOT assert
#     "0 CVE" — that is a claim about a date, and the vulnerability database moves
#     while the pin does not.
#   • The floor binds THIS builder. mkGoTool / mkGoDockerImage / private-module
#     carry only the opposite assert (a CEILING: go.mod must not be ahead of the
#     toolchain) and are not floored yet. See docs/go/go-toolchain.md's ledger.
#   • The image build and the conformance check need Linux (they unpack a real
#     tarball and exec the real binary). On darwin these derivations EVALUATE but
#     are built by the Linux CI runner. The musl static-PIE lane is implemented
#     and NOT yet proven on a Linux builder.
#
# Usage:
#   # toolchain-injected (the fleet default — see flake.nix's `lib`):
#   hardened = import "${substrate}/lib/build/go/hardened-image.nix" {
#     goToolchain = substrate.goToolchains.${system}.stable;
#   };
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
{
  # The fleet Go toolchain, ALREADY BUILT — `substrate.goToolchains.${system}
  # .stable`. Module-level so it is the DEFAULT for every builder in this file
  # rather than a per-call opt-in; substrate's own `lib` passes it here (see
  # lib/default.nix), which is what makes a consumer of `substrate.lib.${system}`
  # inherit a current compiler with no call-site change at all.
  #
  # It must be built from SUBSTRATE's nixpkgs, never the consumer's. Building it
  # from a nixos-24.05 pkgs does not degrade, it ABORTS uncatchably on the
  # missing `replaceVars` — measured; see overlay.nix's header.
  goToolchain ? null,
}:
let
  # The committed fleet pin, read once. Its `cveFloor` is the default floor for
  # every builder here, so the number lives in ONE place (go-toolchain-pin.json)
  # and this file never restates it.
  goPin = builtins.fromJSON (builtins.readFile ./go-toolchain-pin.json);
  moduleGoToolchain = goToolchain;

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
    # The compiler. Defaults to whatever this module was imported with, which for
    # `substrate.lib.${system}` is the pinned fleet toolchain. null falls back to
    # the consumer's own `pkgs.buildGoModule`, byte-identical to the pre-2026-07-30
    # behaviour — the floor below is what stops that being a silent regression.
    goToolchain ? moduleGoToolchain,
    # The CVE floor: the lowest compiler version this build accepts. Defaults to
    # the committed pin. Set null to disable — a deviation that wants
    # `skip-go-floor: <typed-reason>` in the deviating repo's CLAUDE.md. Lowering
    # it to a concrete older version is the better escape hatch than disabling,
    # because the number then appears in the diff.
    goFloor ? goPin.cveFloor,
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

    # ── the toolchain seam ────────────────────────────────────────────────
    #
    # `.override { go = … }` and NOT `pkgs.callPackage "${pkgs.path}/pkgs/
    # build-support/go/module.nix" { go = … }`. Both evaluate; `.override` is
    # strictly better because it does not depend on an internal nixpkgs FILE
    # PATH, which is a surface that has moved between revisions. Measured
    # working on BOTH the incident consumer's pin and substrate's own anchor:
    #
    #   p24.buildGoModule ? override                                -> true
    #   (p24.buildGoModule.override { go = tc }) { compat-sh … }
    #     .passthru.go.version                                       -> 1.26.5
    #   p24.go.version (untouched)                                   -> 1.22.8
    #
    # It is type-compatible across that generation gap because 24.05's
    # module.nix reads only go.CGO_ENABLED / go.GOOS / go.GOARCH /
    # go.meta.platforms off the toolchain, and substrate's toolchain exposes all
    # four as TOP-LEVEL attrs (measured), matching nixpkgs' own `go`.
    #
    # For libc = "musl" the compiler is injected into pkgsMusl's builder. Sound
    # in principle for libc = "none" (the compiler only runs at build time and
    # the artifact links no libc); for the musl lane the C-toolchain/libc mixing
    # is UNPROVEN — see the tier note in the header.
    # This builder takes the CONSUMER's pkgs, so nothing here constrains WHICH
    # compiler runs. Floor it: a below-CVE-floor stdlib becomes an eval error
    # naming the fix, never a silently vulnerable artifact.
    goBuilder = args: (import ./overlay.nix).assertGoFloor {
      what = "substrate.mkHardenedGoImage";
      drv = (if goToolchain != null
        then buildPkgs.buildGoModule.override { go = goToolchain; }
        else buildPkgs.buildGoModule) args;
    };

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

    built = goBuilder ({
    pname = name;
    inherit version src vendorHash;

    # CGO_ENABLED is passed through NEITHER `env` NOR a top-level attr — it is
    # exported in preBuild below. That looks like a workaround and it is a
    # deliberate one, because there is no portable attribute channel here.
    #
    # This repo's consumers pull in more than one nixpkgs, and buildGoModule
    # moved CGO_ENABLED between revisions, in opposite directions:
    #
    #   nixpkgs b134951 (module.nix, 323 lines)
    #     line  40:  , CGO_ENABLED ? go.CGO_ENABLED      <- top-level argument
    #     line 170:  inherit CGO_ENABLED ...             <- onto mkDerivation
    #     => must be TOP-LEVEL; an `env` key collides.
    #
    #   nixpkgs addf7cf5 (module.nix, 411 lines)
    #     line 225:  CGO_ENABLED = args.env.CGO_ENABLED or go.CGO_ENABLED;
    #                inside `env = args.env or { } // { ... }`
    #     => must be in `env`; a top-level attr collides.
    #
    # Either choice therefore breaks the other consumer with
    # "The 'env' attribute set cannot contain any attributes passed to
    # derivation. The following attributes are overlapping: CGO_ENABLED".
    # Both were tried on 2026-07-30 and each failed against the nixpkgs the
    # other one satisfied, which is the whole reason this note is this long.
    #
    # A shell export in preBuild is version-independent: `go build` reads the
    # process environment, preBuild runs before buildPhase, and the export
    # persists into checkPhase, so `doCheck` sees it too. Same mechanism this
    # file already relies on for -buildmode=pie, for the same reason — the
    # attribute surface is not stable enough to target.

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
    preBuild = ''
      export CGO_ENABLED=${cgoEnabled}
    '' + lib.optionalString pie ''
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
        # The floor this binary was held to, and whether a toolchain was
        # injected, recorded so an operator or a downstream check can read the
        # answer off the derivation instead of re-deriving the wiring.
        #
        # The compiler VERSION is deliberately NOT restated here: it already
        # lives at `drv.passthru.go.version`, which is the canonical place and
        # the one the floor asserts against. Copying it into this attrset would
        # make passthru refer to itself.
        goFloor = if goFloor == null then "disabled" else goFloor;
        goToolchainInjected = goToolchain != null;
      };
    };
    } // (lib.optionalAttrs (subPackages != null) { inherit subPackages; })
      // extraAttrs);

    # ── the CVE floor ─────────────────────────────────────────────────────
    #
    # Read the compiler version back OFF THE BUILT DERIVATION rather than from
    # `buildPkgs.go.version`. That is not fussiness: `buildGoModule` closes over
    # its own `go` (nixpkgs aliases buildGoModule = buildGo1XXModule), so an
    # overlay that replaced one and not the other makes `pkgs.go.version` a
    # PROXY that can disagree with the compiler in use. `passthru.go` is the
    # compiler itself, and it is present on both the incident consumer's pin and
    # substrate's own anchor (measured: 1.22.8 on 24.05, 1.26.3 on 26.05).
    #
    # If a future nixpkgs stops publishing it, that is a loud throw here rather
    # than a floor that quietly examines nothing — a vacuous guard is worse than
    # no guard, because it reports PASS.
    effectiveGoVersion =
      built.passthru.go.version or (throw ''
        mkHardenedGoBinary: cannot read the compiler version off the built
        derivation (`passthru.go.version` is absent on this nixpkgs).

        The CVE floor is asserted against the compiler that actually compiles, so
        with no way to read it there is nothing to assert and the floor would be
        vacuous. Either pass `goToolchain` explicitly (its `.version` is then the
        answer) or set `goFloor = null` with a typed `skip-go-floor:` reason.
      '');

    _floorOk =
      if goFloor == null then true
      else if builtins.compareVersions effectiveGoVersion goFloor < 0
      then throw ''
        mkHardenedGoBinary: "${name}" would be compiled by Go ${effectiveGoVersion},
        below the fleet CVE floor of ${goFloor}.

        A Go binary's stdlib CVE set is decided by the COMPILER, not by the `go`
        directive in go.mod — so this is not a source problem and no source edit
        fixes it.

        ${if goToolchain == null
          then "No `goToolchain` was passed, so this build took the consuming nixpkgs' own `go`. That is exactly what produced the 2026-07-30 incident: 48 findings, 1 CRITICAL, out of one 152-line shim compiled by go 1.22.8."
          else "A `goToolchain` WAS passed, but it is itself below the floor. Bump lib/build/go/go-toolchain-pin.json."}

        The fix is toolchain provenance. Thread substrate's pinned toolchain:

          # in the consumer's flake outputs
          hardened = import "''${substrate}/lib/build/go/hardened-image.nix" {
            goToolchain = substrate.goToolchains.''${system}.stable;
          };

          # or, going through substrate's own lib, nothing at all — it is the
          # default there:
          substrate.lib.''${system}.mkHardenedGoBinary pkgs { ... }

        Deliberately building below the floor is a deviation, not a config knob.
        It needs `skip-go-floor: <typed-reason>` at the top of the deviating
        repo's CLAUDE.md, and prefer `goFloor = "<older version>"` over
        `goFloor = null` so the number you accepted is visible in the diff.
        Suppressing the SCANNER instead (.trivyignore / VEX / --ignore-unfixed)
        is never an option — standing operator bar is real 0-CVE.
      ''
      else true;
  in
  assert _libcOk;
  assert _floorOk;
  built;

  # ── govulncheck gate ──────────────────────────────────────────────────
  #
  # govulncheck is Go-specific and reachability-aware: it reports a
  # vulnerability only when the vulnerable SYMBOL is actually reachable from
  # this module's call graph. That makes it far less noisy than a generic
  # CVE scanner over the dependency list, and it is the right gate for a Go
  # artifact. grype/trivy over the image remain useful for the OS layer —
  # which, on a scratch base, is nearly empty by construction.
  #
  # DO NOT MISTAKE THIS FOR THE STDLIB-CVE GATE. Reachability is exactly why it
  # cannot be: measured on rio against a program with compat-sh's own import set
  # (fmt/os/strconv/strings/time), `govulncheck ./...` printed "No
  # vulnerabilities found" while itself noting the stdlib vulns it declined to
  # report because "your code doesn't appear to call" them — and
  # `govulncheck -mode=binary` on the SAME binary reported 28. Trivy's gobinary
  # analyzer reads the same `.go.buildinfo` field binary-mode falls back to,
  # which is why the scanner said 48 and this gate would have said 0. Source mode
  # is the right question for "is my code exploitable"; the CVE floor in
  # mkHardenedGoBinary is the right answer for "is my stdlib current". Both, not
  # either.
  #
  # "Could not analyse" and "clean" USED to be indistinguishable in this
  # derivation's exit status, and the honest advice was to treat a green
  # `img.checks.vuln` as evidence of nothing. That is no longer the trade: an
  # analysis that did not complete is now fatal regardless of `strict`, so a
  # green states that govulncheck actually ran. What a green still does NOT
  # state is that the database was current — that is `vulnDb`'s freshness, and
  # it is the caller's to keep, exactly as cve-gate.nix says of trivy.
  mkGoVulnCheck = pkgs: {
    name,
    src,
    # Fail the build on a reachable vulnerability. Set false to report only.
    strict ? true,
    # The compiler govulncheck analyses WITH. Threaded for the same reason the
    # build toolchain is: on an un-overlaid consumer this used to be `pkgs.go`,
    # so a 24.05 repo ran a reachability gate against go 1.22.8 even once its
    # build toolchain had been fixed. A partial fix here reads as complete.
    goToolchain ? moduleGoToolchain,
    # An OFFLINE vulnerability database (a store path laid out like vuln.go.dev).
    # This is the ONLY way this gate can ever decide anything: the derivation is
    # a plain `runCommand`, so it is sandboxed and has no network, and
    # govulncheck without a reachable database exits 1 before analysing.
    # Measured on rio 2026-08-01, govulncheck 1.1.4:
    #   with a database   -> rc=0, "Your code is affected by 0 vulnerabilities."
    #   -db file:///absent -> rc=1, "creating client: stat …: no such file …"
    # Supplying this is also what ★★ HERMETIC SUPPLY CHAIN requires — the
    # database is mirrored once as a fixed-output derivation, never fetched at
    # build time.
    vulnDb ? null,
  }:
  let
    analysisGo = if goToolchain != null then goToolchain else pkgs.go;
  in
  pkgs.runCommand "govulncheck-${name}"
    {
      nativeBuildInputs = [ pkgs.govulncheck analysisGo pkgs.cacert ];
      inherit src;
      strictMode = if strict then "1" else "0";
      dbFlag = if vulnDb == null then "" else "-db file://${vulnDb}";
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

      # THREE outcomes, not two. The previous version had two branches, so
      # "could not analyse" fell into the findings branch and — at the default
      # strict=false — wrote a $out and exited 0. A run that never opened the
      # vulnerability database reported "findings present" and went green.
      #
      # `rc` alone cannot separate them: govulncheck exits 1 both for "database
      # unreachable" and for other errors. The discriminator is the COMPLETION
      # MARKER, which only a finished analysis prints (measured on rio, above).
      # Grepping for it means an un-run gate cannot be mistaken for a clean one.
      # `|| rc=$?`, NOT a bare call. stdenv runs this builder under `set -e`, and
      # the version this replaced hid inside `if govulncheck …; then`, which is
      # exempt. A bare call aborts the script the moment govulncheck exits
      # non-zero — which is ALWAYS here — so the derivation failed before
      # reaching the verdict below and reported exit 1 for the wrong reason.
      # Measured: it did, and the differential that "proved" the fix was itself
      # a false proof until the failure REASON was read rather than the code.
      rc=0
      govulncheck $dbFlag ./... > "$TMPDIR/vuln.txt" 2>&1 || rc=$?

      if ! grep -q "Your code is affected by" "$TMPDIR/vuln.txt"; then
        echo "== ${name}: govulncheck COULD NOT ANALYSE =="
        sed 's/^/    /' "$TMPDIR/vuln.txt" | head -n 40
        echo ""
        echo "  This is FATAL regardless of \`strict\`, and deliberately so: a"
        echo "  gate that did not run must never produce a green artifact. It"
        echo "  is not evidence of a clean tree, it is the absence of evidence."
        echo ""
        echo "  This derivation is a sandboxed runCommand and has NO network,"
        echo "  so govulncheck cannot reach vuln.go.dev. Pass an offline"
        echo "  database via mkHardenedGoImage's \`vulnDb\` (a mirrored"
        echo "  fixed-output derivation), or set \`vulnGate = false\` and say"
        echo "  in the call site that this image has no reachability gate."
        exit 1
      fi

      if [ "$rc" -eq 0 ]; then
        echo "  analysis completed: no reachable vulnerabilities"
        mkdir -p "$out"
        cp "$TMPDIR/vuln.txt" "$out/govulncheck.txt"
        echo "${name}: govulncheck PASS" > "$out/result"
        exit 0
      fi

      echo "  analysis completed and reported findings:"
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
    # The compiler + its floor, threaded down to mkHardenedGoBinary and the vuln
    # gate. Defaults to whatever this module was imported with; see the header.
    goToolchain ? moduleGoToolchain,
    goFloor ? goPin.cveFloor,
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
    # `strict` governs FINDINGS ONLY. It does NOT govern whether the gate ran:
    # a govulncheck that could not open its database is fatal either way, so
    # there is no setting of this flag under which an un-run gate goes green.
    #
    # This comment used to say "turn it on where the gate runs with network,
    # which is CI". That remedy was inapplicable as written — the check is a
    # sandboxed `runCommand`, so no CI arrangement gives it network — and it
    # papered over the real defect, which was that the non-strict path exited 0
    # after failing to analyse anything at all. The fix is `vulnDb`, not this.
    vulnStrict ? false,
    # Offline vulnerability database; see mkGoVulnCheck. Without it this gate
    # cannot decide, and now says so instead of passing.
    vulnDb ? null,
    # CEILING 5 -> 7, 2026-08-01. This check has NEVER passed: it was added
    # 2026-07-29 (e7197d1) and substrate's nix-tests has been red from that day
    # to this one -- because the ceiling contradicts the posture the SAME check
    # asserts.
    #
    # MEASURED closure of the hardened smoke image (from the CI log):
    #   smoke-0.0.0  nss-cacert  mailcap  iana-etc  tzdata   <- the minimal five
    #   passwd  group                                        <- the extra two
    #
    # The extra two are exactly what NON-ROOT requires. This check's own
    # description is "PIE, stripped, NON-ROOT, serves", and a container running
    # as a non-root uid needs /etc/passwd and /etc/group entries to resolve it.
    # So the check demanded non-root AND a ceiling that non-root cannot satisfy
    # -- internally contradictory from the day it landed, which is why it never
    # went green rather than "regressed".
    #
    # NOT A WEAKENING, and this is measured on the very image that failed: the
    # forbidden-pattern scan (busybox|/bin/sh|libc.so|coreutils|apk|apt) PASSED
    # on it -- "no shell/coreutils/init/libc/pkg-mgr in any layer ✓". The
    # ceiling bounds bloat; that scan bounds the threat, and it is untouched.
    maxStorePaths ? 7,
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
              ldflagsExtra versionPath doCheck goToolchain goFloor;
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
      vuln = mkGoVulnCheck pkgs {
        inherit name src goToolchain vulnDb;
        strict = vulnStrict;
      };
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
    # tatara-script derivation, supplied by the consumer exactly as
    # lib/build/scripting/tatara-script.nix takes `tataraLisp`. substrate does
    # not own the tatara-lisp input; a repo that wants this check passes it in.
    # Without it the check cannot run, and that is a hard error rather than a
    # silent fallback to shell.
    tataraScript ? null,
    # ELF sections the shipped binary must still carry, forwarded verbatim to
    # mkMinimalImageCheck (which has accepted it since it was written).
    #
    # This wrapper simply never re-exported it, so a consumer that needed it
    # got `called with unexpected argument 'requireSections'` and the whole
    # check suite went red — substrate's own web-static-spa-image, which asks
    # for `.dep-v0` to prove the cargo-auditable document survives the strip.
    # Dropping the argument instead would have been worse than the error: the
    # check would go green while the CVE-coverage seal it exists to enforce
    # silently stopped being asserted.
    #
    # Default `[ ]` keeps every existing caller byte-identical.
    requireSections ? [ ],
    # Forbidden-substring list, forwarded to mkMinimalImageCheck. Same story
    # as requireSections: a documented parameter the delegate has always
    # accepted and this wrapper never re-exported.
    #
    # `null` means "use the delegate's default" so this stays byte-identical
    # for every caller that does not set it — an empty list would silently
    # DISABLE the check, which is the failure mode this whole file exists to
    # prevent, so it must not be the default.
    #
    # Narrowing it is a real loosening of a security gate. The one sanctioned
    # reason so far is `lib/build/web/static-spa-image.nix`, whose `/bin/sh`
    # is not a shell at all: it is `compat-sh`, a static Go binary built
    # through mkHardenedGoBinary that answers the lifecycle-hook vocabulary
    # and cannot execute anything. See that file for why the closure ceiling
    # still pins the result.
    forbidden ? null,
  }:
  let
    minimalCheck = (import ./minimal-image-check.nix { }).mkMinimalImageCheck pkgs ({
      inherit name image binary binName maxStorePaths execSmoke requireSections;
      expectStatic = true;
    }
    # Only pass `forbidden` when the caller actually set it, so an unset
    # caller gets the delegate's own default list rather than a null.
    // (if forbidden == null then { } else { inherit forbidden; }));
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
