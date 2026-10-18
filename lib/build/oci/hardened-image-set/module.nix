{ lib }:

let
  inherit (lib) mkOption types;
  claimFiles = types.nullOr (types.either types.path (types.listOf types.path));
in
{
  options = {
    provenance = mkOption {
      type = types.enum [ "nix-built" "vendor-rewrap" ];
      default = "nix-built";
      description = ''
        `nix-built`: `package` is built from source by Nix and the image is its
        closure on a hardened base. `vendor-rewrap`: the binary is extracted
        from a pinned upstream image (`upstreamDigest`, `upstreamSha256`,
        `binaryPath`) and repackaged on a hardened base, for a property only
        the vendor bytes carry, such as a FIPS validation.
      '';
    };

    upstreamDigest = mkOption {
      type = types.nullOr (types.strMatching "^sha256:[0-9a-f]{64}$");
      default = null;
      description = "vendor-rewrap only. The pinned upstream manifest digest.";
    };

    upstreamSha256 = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "vendor-rewrap only. Hash of the pulled image tarball.";
    };

    binaryPath = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "vendor-rewrap only. Absolute path of the entrypoint binary inside the upstream rootfs.";
    };

    extraBinaryPaths = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "vendor-rewrap only. Sibling binaries version-locked to `binaryPath`.";
    };

    srcCredsEnv = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "vendor-rewrap only. Name of the environment variable holding the source-registry password.";
    };

    srcCredsUser = mkOption {
      type = types.str;
      default = "AWS";
      description = "vendor-rewrap only. Source-registry username.";
    };

    extraRootfsPaths = mkOption {
      type = types.listOf (types.submodule {
        options = {
          from = mkOption { type = types.str; description = "Path inside the upstream rootfs."; };
          to = mkOption { type = types.str; description = "Path in the emitted image, no leading slash."; };
        };
      });
      default = [ ];
      description = "vendor-rewrap only. Non-binary upstream files carried into the image, declared explicitly.";
    };

    service = mkOption {
      type = types.strMatching "^[a-z][a-z0-9-]*$";
      description = "Service slug: names the `release:<service>` and scan apps.";
    };

    base = mkOption {
      type = types.enum [ "wolfi" "distroless-glibc" "distroless-static" ];
      default = "distroless-glibc";
      description = ''
        Hardened base tier. `wolfi` carries busybox and requires
        `wolfiRationale`; prefer `shell` / `entrypointTools` for a shell or a
        few tools.
      '';
    };

    shell = mkOption {
      type = types.bool;
      default = false;
      description = "Add a glibc-only dash `/bin/sh` through `mkDistrolessImage`.";
    };

    maxLayers = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "OCI layer ceiling for the `mkDistrolessImage` path; null keeps dockerTools' default.";
    };

    entrypointTools = mkOption {
      type = types.listOf (types.either types.str types.package);
      default = [ ];
      description = "Distroless toolset bundle names or raw packages the entrypoint invokes.";
    };

    package = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = "The Nix-built package. Required for `nix-built`, null for `vendor-rewrap`.";
    };

    upstreamImage = mkOption {
      type = types.str;
      description = "The image this hardened image replaces, or the artifact it is the hardened form of.";
    };

    hardeningRationale = mkOption {
      type = types.str;
      description = "One line: what this image hardens and why.";
    };

    publishName = mkOption {
      type = types.strMatching "^ghcr\\.io/pleme-io/[a-z][a-z0-9-]*$";
      description = "Full OCI image name under ghcr.io/pleme-io.";
    };

    publishTag = mkOption {
      type = types.strMatching "^[0-9]+\\.[0-9]+\\.[0-9]+$";
      description = "Exact `<major>.<minor>.<patch>` build version.";
    };

    entrypoint = mkOption {
      type = types.listOf types.str;
      description = "Container ENTRYPOINT.";
    };

    user = mkOption {
      type = types.strMatching "^[0-9]+:[0-9]+$";
      default = "65532:65532";
      description = "Container USER. Root requires `rootRationale`.";
    };

    wolfiRationale = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Required when `base = \"wolfi\"`: the structural need for busybox.";
    };

    rootRationale = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Required when `user` is uid 0: the structural need for root.";
    };

    cmd = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Container CMD.";
    };

    exposedPorts = mkOption {
      type = types.attrsOf (types.attrsOf types.anything);
      default = { };
      description = "OCI exposedPorts map.";
    };

    volumes = mkOption {
      type = types.attrsOf (types.attrsOf types.anything);
      default = { };
      description = "OCI volumes map.";
    };

    env = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Container env, `KEY=value` strings.";
    };

    extraContents = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Additional store paths shipped in the image.";
    };

    writablePaths = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Paths the non-root user can write at boot.";
    };

    workdir = mkOption {
      type = types.str;
      default = "/";
      description = "The image's working directory.";
    };

    hardeningTarget = mkOption {
      type = types.bool;
      default = true;
      description = "Whether `vulnix-scan:<service>` is generated over the delivered closure.";
    };

    goReachability = mkOption {
      type = types.bool;
      default = false;
      description = "Whether `grype-scan:<service>` judges Go findings with substrate's go-reachability primitive, the same one pleme-io/actions/image-scan runs for `go-reachability: true`.";
    };

    bundledCryptoFloor = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Minimum statically bundled OpenSSL `X.Y.Z` the package binaries must report; null means no gate.";
    };

    trivyAnalysableTargets = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      description = ''
        The trivy target types this image is measured to present. null is
        unmeasured and is refused unless the name is in the caller's
        `undeclaredDenominatorBaseline`; `[ ]` is measured trivy-blind and
        requires `hardeningTarget`.
      '';
    };

    vulnixWhitelist = mkOption {
      type = claimFiles;
      default = null;
      description = "vulnix TOML whitelist file(s), read only with `cveClaims.enable`.";
    };

    cveClaims.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Whether `vulnixWhitelist` and `grypeIgnoreFile` reach the scan gates.";
    };

    grypeIgnoreFile = mkOption {
      type = claimFiles;
      default = null;
      description = "grype TOML claim file(s) (`fixed-at-cause` | `accepted-floor`), read only with `cveClaims.enable`.";
    };
  };
}
