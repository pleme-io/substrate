# Complete multi-system flake outputs for a Go CLI tool packaged as an OCI image.
# The Go peer of build/rust/tool-image-flake.nix — for CLI-as-image workloads
# (K8s CronJobs, init containers, one-shot jobs) where the tool runs inside a
# container rather than on a host PATH.
#
# Layering mirrors the Rust model exactly:
#   - the raw per-arch image builder is mkGoTool (build/go/tool.nix) wrapped with
#     mkGoDockerImage / distroless (build/go/docker.nix + distroless.nix);
#   - mkPerSystem runs it over `systems` via ../../util/flake-wrapper.nix
#     mkFlakeOutputs, adding overlays.default;
#   - an optional module trio (NixOS + nix-darwin + home-manager) is emitted from
#     `module = { ... }` via ../../module-trio.nix.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, flake-utils, substrate, forge, ... }:
#     (import "${substrate}/lib/build/go/tool-image-flake.nix" {
#       inherit nixpkgs;
#       forge = forge or null;          # optional — enables the release app
#     }) {
#       toolName = "secret-syncer";
#       src = self;
#       vendorHash = "sha256-...";       # null = in-tree vendoring (go-gen-spec)
#       repo = "pleme-io/secret-syncer"; # optional — registry coordinate + bump/release
#       registry = "ghcr.io";
#       architectures = ["amd64" "arm64"];
#       extraContents = pkgs: [ pkgs.kubectl ];
#     };
#
# Packages:
#   nix build .#"dockerImage:amd64"   — per-arch OCI image
#   nix build .#"dockerImage:arm64"
#   nix build                          — host-arch image (packages.default)
#
# Apps:
#   nix run .#release  — push all arch images to ${registry}/${repo} via
#                        forge image-release (mirrors the Rust tool-image-flake).
#   nix run .#check-all / .#lock-platform — language-generic lifecycle apps.
#   nix run .#bump     — semver bump (when repo is set).
{
  nixpkgs,
  forge ? null,
}:
{
  toolName,
  systems ? ["x86_64-linux" "aarch64-linux"],
  module ? null,
  repo ? null,
  registry ? "ghcr.io",
  architectures ? ["amd64" "arm64"],
  ...
} @ args:
let
  # Args forwarded to the per-arch image builder. Strip the flake-level knobs
  # the wrapper owns; toolName + architectures + registry are threaded explicitly.
  imageArgs = builtins.removeAttrs args [
    "toolName" "systems" "module" "repo" "registry" "architectures"
  ];

  flakeWrapper = import ../../util/flake-wrapper.nix { inherit nixpkgs; };
  pkgsLib = (import nixpkgs { system = "x86_64-linux"; }).lib;
  hygiene = import ../../util/flake-hygiene.nix {
    lib = pkgsLib;
  };
  # Enforce flake hygiene at evaluation time — fails fast on misconfiguration.
  # In tool flakes, src = self, so src.inputs holds the flake inputs.
  _hygieneCheck =
    if args ? src && args.src ? inputs then hygiene.enforceAll args.src.inputs
    else true;

  goToolBuilder = import ./tool.nix;
  goDocker = import ./docker.nix;
  goDevenv = import ./devenv.nix;
  releaseHelpers = import ../../util/release-helpers.nix;

  # Architecture <-> Linux system triple mapping (shared by the per-arch image
  # builder, the host-arch default, and the forge image-release app).
  archToSystem = arch:
    if arch == "arm64" then "aarch64-linux" else "x86_64-linux";
  archForSystem = {
    "x86_64-linux"  = "amd64";
    "aarch64-linux" = "arm64";
  };

  # Argument partition. mkGoTool and mkGoDockerImage have closed (no-`...`)
  # signatures, so `imageArgs` is split into the keys each builder understands
  # via builtins.intersectAttrs (returns attrs of arg-2 whose names are in
  # arg-1). `description` is shared by both — it lands in each partition.
  toolArgKeys = {
    version = null; src = null; vendorHash = null; subPackages = null;
    ldflags = null; versionLdflags = null; tags = null; proxyVendor = null;
    modRoot = null; doCheck = null; completions = null; extraBuildInputs = null;
    extraPostInstall = null; extraAttrs = null; description = null;
    homepage = null; license = null; platforms = null;
  };
  imageArgKeys = {
    ports = null; env = null; user = null; workDir = null; entrypoint = null;
    extraContents = null; distroless = null; tini = null; labels = null;
    description = null; fleetSourceUrl = null; created = null;
  };

  # ── Raw per-arch image builder ─────────────────────────────────────────────
  # Build the Go tool via mkGoTool against the target arch's pkgs, then wrap it
  # with mkGoDockerImage. CLI-as-image: no ExposedPorts beyond the docker.nix
  # default (consumers can pass `env` / `extraContents` / distroless knobs).
  mkImage = arch: let
    targetSystem = archToSystem arch;
    pkgs = import nixpkgs {
      system = targetSystem;
      overlays = [ ((import ./overlay.nix).mkGoOverlay {}) ];
    };
    binary = goToolBuilder.mkGoTool pkgs ({
      pname = toolName;
    } // (builtins.intersectAttrs toolArgKeys imageArgs));
  in goDocker.mkGoDockerImage pkgs ({
    name = toolName;
    inherit binary;
    architecture = arch;
    tag = "${arch}-latest";  # release-time pipeline rewrites the tag
  } // (builtins.intersectAttrs imageArgKeys imageArgs));

  mkPerSystem = system: let
    pkgs = import nixpkgs { inherit system; };
    lib = pkgs.lib;
    hostArch = archForSystem.${system};

    # forge binary resolution: prefer the passed flake input, else PATH lookup.
    forgeCmd =
      if forge != null then "${forge.packages.${system}.default}/bin/forge"
      else "forge";

    imageReleaseLib = import ../../service/image-release.nix {
      inherit pkgs forgeCmd;
    };

    # Per-arch images keyed `dockerImage:<arch>` (matches service-flake.nix).
    images = builtins.listToAttrs (map (arch: {
      name = "dockerImage:${arch}";
      value = mkImage arch;
    }) architectures);

    # Image release app — pushes every arch via forge image-release.
    # Mirrors the Rust tool-image-flake release app (service/image-release.nix).
    releaseApp = imageReleaseLib.mkImageReleaseApp {
      name = toolName;
      registry = "${registry}/${repo}";
      mkImage = targetSystem: mkImage archForSystem.${targetSystem};
      systems = map archToSystem architectures;
    };

    # Release lifecycle apps — language-generic, parameterised with language="go".
    releaseArgs = { hostPkgs = pkgs; inherit toolName forgeCmd; language = "go"; };
  in {
    packages = images // {
      # Host-arch image so `nix build` / `nix run .#default` works on the box.
      default = images."dockerImage:${hostArch}";
    };
    devShells = {
      default = goDevenv.mkGoDevShell pkgs { withDocker = true; };
    };
    apps = {
      check-all = releaseHelpers.mkCheckAllApp releaseArgs;
      lock-platform = releaseHelpers.mkLockPlatformApp releaseArgs;
    } // lib.optionalAttrs (repo != null) {
      # `repo` is the registry coordinate — required to push images + bump.
      release = releaseApp;
      "release:${toolName}" = releaseApp;
      bump = releaseHelpers.mkBumpApp releaseArgs;
    };
  };

  trio =
    if module == null then null
    else (import ../../module-trio.nix { lib = pkgsLib; }).mkModuleTrio (
      {
        name = module.name or toolName;
        description = module.description or "${toolName} CLI image";
        packageAttr = module.packageAttr or toolName;
      } // (builtins.removeAttrs module [ "name" "description" "packageAttr" ])
    );

  moduleOutputs = if trio == null then {} else {
    homeManagerModules.default = trio.homeManagerModule;
    nixosModules.default = trio.nixosModule;
    darwinModules.default = trio.darwinModule;
  };
in
  flakeWrapper.mkFlakeOutputs {
    inherit systems mkPerSystem;
    extraOutputs = {
      overlays.default = final: prev: {
        ${toolName} = (mkPerSystem final.stdenv.hostPlatform.system).packages.default;
      };
    } // moduleOutputs;
  }
