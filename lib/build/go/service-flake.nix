# Complete multi-system flake outputs for a Go service.
#
# Mirrors `lib/build/rust/service-flake.nix` (used by hanabi). One
# import in the consumer flake produces:
#   - packages.<system>.{default, dockerImage:<arch>}
#   - apps.<system>.release    (multi-arch push via forge image-release)
#   - apps.<system>.release:<name> (per-service)
#   - devShells.<system>.default
#
# Usage in a consumer flake:
#   outputs = { self, nixpkgs, substrate, forge, ... }:
#     (import "${substrate}/lib/build/go/service-flake.nix" {
#       inherit nixpkgs substrate forge;
#     }) {
#       inherit self;
#       serviceName = "my-go-service";
#       registry    = "ghcr.io/myorg/my-go-service";
#       src         = self;
#       subPackages = [ "cmd/my-go-service" ];
#       ports       = { http = 8080; metrics = 9090; };
#     };
#
# MINIMAL-PRODUCTION-IMAGE (default-on; docs/MINIMAL-PRODUCTION-IMAGE.md):
#   minimal    = true       — DEFAULT. Strict production stack: scratch
#                             base (cacert only, no shell/coreutils/pkg-mgr,
#                             NO tini ⇒ no glibc subtree), CGO_ENABLED=0
#                             static binary built with the static Go tags
#                             (timetzdata,netgo,osusergo). This IS what
#                             ships and what the build tests build+run.
#                             Set false for a fat/debug image with a shell.
#   goTags     = [ ... ]     — static-friendly Go build tags (only applied
#                             when minimal); default embeds zoneinfo + uses
#                             the pure-Go net/os-user resolvers.
#   withCacert = true        — keep the CA-cert bundle (DEFAULT; outbound TLS
#                             needs it, and cacert is a 0-code-CVE data pkg).
#                             false → true-scratch (binary only) for a service
#                             that makes no outbound TLS. The strip target is
#                             tini+glibc, never cacert.
#
# Hardening knobs are opt-in:
#   distroless = true       — cacert + tini base, no busybox/shell
#                             (superseded by `minimal`; kept for the rare
#                              multi-process container that wants tini)
#   sign       = true       — cosign keyless sign after push
#   sbom       = true       — emit SBOM attestation alongside image
#   cveGate    = { ... }    — trivy/grype gate pre-push
#   numericUid = 10001      — uid > 10000, no /etc/passwd needed
{
  nixpkgs,
  substrate,
  forge,
}:
{
  self,
  serviceName,
  registry,
  src ? self,
  subPackages,
  vendorHash ? null,
  version ? "0.1.0",
  ldflags ? [],
  architectures ? [ "amd64" "arm64" ],
  systems ? [ "x86_64-linux" "aarch64-linux" ],
  ports ? { http = 8080; health = 8081; },
  env ? [],
  user ? "65534:65534",
  workDir ? "/app",
  entrypoint ? null,
  buildInputs ? [],
  # ── MINIMAL-PRODUCTION-IMAGE (default-on for production) ────────────
  minimal ? true,
  goTags ? [ "timetzdata" "netgo" "osusergo" ],
  # Keep the CA-cert bundle (default true; needed for outbound TLS). Set
  # false only for a no-outbound-TLS service → true-scratch (binary only).
  withCacert ? true,
  # ── Phase 2 hardening (opt-in) ─────────────────────────────────────
  distroless ? false,
  tini ? true,
  labels ? {},
  description ? null,
  fleetSourceUrl ? "https://github.com/pleme-io/${serviceName}",
  sign ? false,
  signKeyless ? true,
  signIdentityTokenPath ? null,
  sbom ? false,
  sbomFormat ? "spdx-json",
  cveGate ? null,
  fipsBuild ? false,
}:
let
  archForSystem = {
    "x86_64-linux"  = "amd64";
    "aarch64-linux" = "arm64";
  };

  mkPerSystem = system: let
    pkgs = import nixpkgs { inherit system; };
    arch = archForSystem.${system};

    # MINIMAL-PRODUCTION-IMAGE — the static-friendly Go build tags are
    # applied only in the minimal posture. `netgo`/`osusergo` drop the
    # /etc/{protocols,services,passwd} references; `timetzdata` embeds the
    # zoneinfo — so the static binary needs no OS data packages and the
    # scratch base ships nothing but the cert bundle.
    effectiveTags = if minimal then goTags else [];
    goTagsArg = nixpkgs.lib.optionalString (effectiveTags != [])
      ''-tags "${nixpkgs.lib.concatStringsSep "," effectiveTags}"'';

    goDocker = import ./docker.nix;
    imageReleaseLib = import ../../service/image-release.nix {
      inherit pkgs;
      forgeCmd = "${forge.packages.${system}.default}/bin/forge";
    };

    # Build the Go binary. FIPS build option enables BoringCrypto
    # at toolchain level (defense-in-depth; some workloads also
    # activate FIPS via runtime ldflag).
    #
    # The buildPhase is overridden to use raw `go install ./<subPackage>`
    # against the in-tree `vendor/`. The default `buildGoModule`
    # `buildPhase` runs an extra vendor-consistency pre-check that
    # rejects certain valid Akeyless vendoring patterns (e.g. transitive
    # imports of `github.com/microsoft/go-mssqldb` via a single dot-import).
    # The raw `go install` path mirrors plain `go build -mod=vendor`,
    # which we've verified works on the same source. Output is collected
    # from `$GOPATH/bin/<GOOS>_<GOARCH>/` (cross-compile) or `$GOPATH/bin/`
    # (host build).
    binary = pkgs.buildGoModule {
      pname = serviceName;
      inherit version src vendorHash subPackages ldflags buildInputs;
      env = { CGO_ENABLED = "0"; }
        // (if fipsBuild then { GOEXPERIMENT = "boringcrypto"; GOFIPS = "1"; } else {});
      doCheck = false;
      meta.mainProgram = serviceName;
      # Skip buildGoModule's strict pre-check; use raw `go install` with
      # GOFLAGS=-mod=vendor (already exported by buildGoModule).
      #
      # ADAPTIVE CORE-PARTITION (super-cache-ci) — HONOR nix --cores.
      # The raw `go install` MUST pass `-p $NIX_BUILD_CORES` explicitly:
      # buildGoModule's setup hook sets its OWN `GOFLAGS=-mod=vendor`
      # (clobbering any inherited `-p`), and Go otherwise defaults build
      # action-parallelism to GOMAXPROCS = the HOST cpu count — so nix
      # `--cores N` is INERT for this raw invocation. When N images build
      # concurrently (nix `--max-jobs N`) each unbounded `go install` fans
      # out to ALL host cores ⇒ N× over-subscription (MEASURED: 9 concurrent
      # akeyless Go compiles on a 96-vCPU node peaked at load ~310 = 3.1×,
      # unchanged by nix `--cores` alone, because this line ignored it).
      # `-p` bounds parallel build actions; GOMAXPROCS bounds the compiler's
      # own goroutines — both to NIX_BUILD_CORES so the nix-computed partition
      # (max-jobs N × cores V/N ≤ V) is actually realized. 0 = Go's default
      # (nix passes 0 for --cores 0, i.e. "all cores" — the lone-build case).
      buildPhase = ''
        runHook preBuild
        _nbc="''${NIX_BUILD_CORES:-0}"
        _pflag=""
        if [ "$_nbc" -gt 0 ] 2>/dev/null; then
          _pflag="-p $_nbc"
          export GOMAXPROCS="$_nbc"
          echo "go build parallelism bounded to NIX_BUILD_CORES=$_nbc (-p + GOMAXPROCS)"
        fi
        for pkg in $subPackages; do
          echo "Building subPackage ./$pkg"
          go install $_pflag ${goTagsArg} -ldflags="$ldflags" ./$pkg
        done
        runHook postBuild
      '';
      # Cross-compile binaries land in $GOPATH/bin/$GOOS_$GOARCH/.
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        if [ -d "$GOPATH/bin/''${GOOS}_''${GOARCH}" ]; then
          cp -v $GOPATH/bin/''${GOOS}_''${GOARCH}/* $out/bin/
        elif [ -d "$GOPATH/bin" ]; then
          cp -v $GOPATH/bin/* $out/bin/
        fi
        runHook postInstall
      '';
    };

    # The OCI image for THIS system's arch. `minimal` overrides
    # distroless/tini in docker.nix — the scratch base is what ships.
    image = goDocker.mkGoDockerImage pkgs {
      name = serviceName;
      inherit binary ports env user workDir entrypoint
              minimal withCacert distroless tini labels description fleetSourceUrl;
      tag = "${arch}-latest";  # release-time pipeline rewrites
      architecture = arch;
    };
  in {
    inherit binary image arch pkgs minimal;

    # Release app — invokes forge image-release with both arch images.
    releaseApp = imageReleaseLib.mkImageReleaseApp {
      name = serviceName;
      inherit registry;
      mkImage = sys: (mkPerSystem sys).image;
      inherit systems;
    };
  };

  # Build for the current system (used by `nix build .#dockerImage:<arch>`).
  forSystem = system: let r = mkPerSystem system; in {
    packages = {
      default = r.binary;
      "dockerImage:${r.arch}" = r.image;
    };
    apps = {
      "release:${serviceName}" = r.releaseApp;
      release = r.releaseApp;
    };
    devShells.default = r.pkgs.mkShell {
      packages = [ r.pkgs.go r.pkgs.gopls r.pkgs.skopeo r.pkgs.cosign r.pkgs.trivy r.pkgs.syft ];
    };
  };
in
{
  packages = nixpkgs.lib.genAttrs systems (s: (forSystem s).packages);
  apps     = nixpkgs.lib.genAttrs systems (s: (forSystem s).apps);
  devShells = nixpkgs.lib.genAttrs systems (s: (forSystem s).devShells);
}
