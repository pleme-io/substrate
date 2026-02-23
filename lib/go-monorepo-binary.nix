# Go monorepo binary builder
#
# Builds a single binary from a Go monorepo source. Extends mkGoMonorepoSource
# (which provides shared {src, version, ldflags}) by wrapping it in buildGoModule
# with per-binary metadata.
#
# Eliminates the boilerplate of 6+ near-identical files that only differ in
# pname, description, homepage, and optional completions.
#
# Usage:
#   mkGoMonorepoBinary = (import "${substrate}/lib/go-monorepo-binary.nix").mkGoMonorepoBinary;
#   kubelet = mkGoMonorepoBinary pkgs k8sSrc {
#     pname = "kubelet";
#     description = "Kubernetes node agent";
#     homepage = "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/";
#   };
#
# The k8sSrc argument is the result of mkGoMonorepoSource:
#   { version, src, ldflags }
{
  # Build a single binary from a Go monorepo.
  #
  # Required attrs:
  #   pname       — binary/package name (e.g., "kubelet")
  #   description — package description for meta
  #
  # Optional attrs:
  #   subPackages      — Go packages to build (default: [ "cmd/${pname}" ])
  #   homepage         — URL for meta
  #   completions      — shell completion config: { install = true; command = "kubeadm"; }
  #   nativeBuildInputs — additional build-time dependencies
  #   postInstall      — additional post-install script (appended after completions)
  #   platforms        — supported platforms (default: lib.platforms.linux)
  mkGoMonorepoBinary = pkgs: monoSrc: {
    pname,
    subPackages ? [ "cmd/${pname}" ],
    description,
    homepage ? null,
    completions ? null,
    nativeBuildInputs ? [],
    postInstall ? "",
    platforms ? pkgs.lib.platforms.linux,
  }: let
    lib = pkgs.lib;

    # Shell completion support (reuses logic from go-tool.nix)
    needsInstallShellFiles = completions != null && (completions.install or false);
    completionBuildInputs = lib.optional needsInstallShellFiles pkgs.installShellFiles;

    completionScript = if completions == null || !(completions.install or false) then ""
      else if completions ? command then let
        cmd = completions.command;
      in ''
        installShellCompletion --cmd ${cmd} \
          --bash <($out/bin/${cmd} completion bash) \
          --zsh <($out/bin/${cmd} completion zsh)
      ''
      else "";

  in pkgs.buildGoModule {
    inherit pname subPackages;
    inherit (monoSrc) version src;

    vendorHash = null;
    ldflags = monoSrc.ldflags;
    doCheck = false;

    nativeBuildInputs = completionBuildInputs ++ nativeBuildInputs;

    postInstall = completionScript + postInstall;

    meta = {
      inherit description platforms;
      license = lib.licenses.asl20;
      mainProgram = pname;
    } // lib.optionalAttrs (homepage != null) { inherit homepage; };
  };
}
