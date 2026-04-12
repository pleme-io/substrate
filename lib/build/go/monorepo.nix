# Go monorepo source factory
#
# Builds a shared source + ldflags for Go projects that produce multiple
# binaries from a single repository (e.g., kubernetes/kubernetes → kubelet,
# kubeadm, kube-apiserver, kube-controller-manager, kube-scheduler, kube-proxy).
#
# Extends the Go toolchain story alongside mkGoTool (single-repo tools).
# mkGoTool builds one tool from one repo; mkGoMonorepoSource provides the
# shared source that multiple mkGoTool calls can reference.
#
# Usage (standalone):
#   mkGoMonorepoSource = (import "${substrate}/lib/go-monorepo.nix").mkGoMonorepoSource;
#   k8sSrc = mkGoMonorepoSource pkgs {
#     owner = "kubernetes";
#     repo = "kubernetes";
#     version = "1.34.3";
#     srcHash = "sha256-...";
#     versionPackage = "k8s.io/component-base/version";
#   };
#   kubelet = pkgs.buildGoModule {
#     inherit (k8sSrc) src version ldflags;
#     pname = "kubelet";
#     subPackages = [ "cmd/kubelet" ];
#     vendorHash = null;
#   };
#
# The returned attrset contains:
#   - version: the version string (e.g., "1.34.3")
#   - src: fetchFromGitHub derivation
#   - ldflags: list of -X flags for version injection
{
  # Build a shared source + ldflags for a Go monorepo.
  #
  # Required attrs:
  #   owner       — GitHub owner (e.g., "kubernetes")
  #   repo        — GitHub repo name (e.g., "kubernetes")
  #   version     — version string without "v" prefix (e.g., "1.34.3")
  #   srcHash     — SRI hash for the source tarball
  #
  # Optional attrs:
  #   tag             — git tag (default: "v${version}")
  #   versionPackage  — Go package path for version injection via -X ldflags
  #                     (e.g., "k8s.io/component-base/version")
  #                     When set, injects: gitVersion, gitMajor, gitMinor,
  #                     gitTreeState, buildDate
  #   extraLdflags    — additional ldflags beyond -s -w and version injection
  mkGoMonorepoSource = pkgs: {
    owner,
    repo,
    version,
    srcHash,
    tag ? "v${version}",
    versionPackage ? null,
    extraLdflags ? [],
  }: let
    lib = pkgs.lib;
    check = import ../../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "owner" owner)
      (check.nonEmptyStr "repo" repo)
      (check.nonEmptyStr "version" version)
      (check.nonEmptyStr "srcHash" srcHash)
      (check.str "tag" tag)
      (check.strOrNull "versionPackage" versionPackage)
      (check.list "extraLdflags" extraLdflags)
    ];

    # Parse major.minor from semver for version ldflags
    majorMinor = builtins.match "([0-9]+)\\.([0-9]+)\\..+" version;
    gitMajor = if majorMinor != null then builtins.elemAt majorMinor 0 else "";
    gitMinor = if majorMinor != null then builtins.elemAt majorMinor 1 else "";
  in {
    inherit version;

    src = pkgs.fetchFromGitHub {
      inherit owner repo tag;
      hash = srcHash;
    };

    ldflags = ["-s" "-w"]
      ++ lib.optionals (versionPackage != null) [
        "-X ${versionPackage}.gitVersion=v${version}"
        "-X ${versionPackage}.gitMajor=${gitMajor}"
        "-X ${versionPackage}.gitMinor=${gitMinor}"
        "-X ${versionPackage}.gitTreeState=clean"
        "-X ${versionPackage}.buildDate=1970-01-01T00:00:00Z"
      ]
      ++ extraLdflags;
  };
}
