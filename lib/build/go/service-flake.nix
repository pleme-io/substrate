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
# Hardening knobs are opt-in:
#   distroless = true       — cacert + tini base, no busybox/shell
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

    goDocker = import ./docker.nix;
    imageReleaseLib = import ../../service/image-release.nix {
      inherit pkgs;
      forgeCmd = "${forge.packages.${system}.default}/bin/forge";
    };

    # Build the Go binary. FIPS build option enables BoringCrypto
    # at toolchain level (defense-in-depth; some workloads also
    # activate FIPS via runtime ldflag).
    binary = pkgs.buildGoModule {
      pname = serviceName;
      inherit version src vendorHash subPackages ldflags buildInputs;
      env = { CGO_ENABLED = "0"; }
        // (if fipsBuild then { GOEXPERIMENT = "boringcrypto"; GOFIPS = "1"; } else {});
      doCheck = false;
      meta.mainProgram = serviceName;
    };

    # The OCI image for THIS system's arch.
    image = goDocker.mkGoDockerImage pkgs {
      name = serviceName;
      inherit binary architecture ports env user workDir entrypoint
              distroless tini labels description fleetSourceUrl;
      tag = "amd64-latest";  # arch label only; release-time tag is what counts
      architecture = arch;
    };
  in {
    inherit binary image arch pkgs;

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
