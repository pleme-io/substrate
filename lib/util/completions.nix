# ============================================================================
# COMPLETIONS - Shared shell completion generation for Go builders
# ============================================================================
# Extracts the duplicated completion logic from go-tool.nix and
# go-monorepo-binary.nix into a single helper. Also fixes the missing
# fish completion support in the monorepo builder.
#
# Internal helper — not exported from lib/default.nix.
#
# Usage:
#   completionAttrs = (import ./completions.nix).mkCompletionAttrs pkgs {
#     pname = "kubeadm";
#     completions = { install = true; command = "kubeadm"; };
#   };
#   # Returns: { nativeBuildInputs = [...]; postInstallScript = "..."; }
{
  # Generate nativeBuildInputs and postInstall script for shell completions.
  #
  # completions: null or { install = true; command = "name"; } or
  #              { install = true; fromSource = "completion/dir"; }
  # pname: package name (used for fromSource --cmd name)
  # src: source derivation (needed for fromSource to check path existence)
  mkCompletionAttrs = pkgs: {
    pname,
    completions ? null,
    src ? null,
  }: let
    lib = pkgs.lib;
    needsInstallShellFiles = completions != null && (completions.install or false);
  in {
    nativeBuildInputs = lib.optional needsInstallShellFiles pkgs.installShellFiles;

    postInstallScript =
      if completions == null || !(completions.install or false) then ""
      else if completions ? command then let
        cmd = completions.command;
      in ''
        installShellCompletion --cmd ${cmd} \
          --bash <($out/bin/${cmd} completion bash) \
          --zsh <($out/bin/${cmd} completion zsh) \
          --fish <($out/bin/${cmd} completion fish)
      ''
      else if completions ? fromSource then ''
        installShellCompletion --cmd ${pname} \
          ${lib.optionalString (builtins.pathExists "${src}/${completions.fromSource}/bash") "--bash ${src}/${completions.fromSource}/*.bash"} \
          ${lib.optionalString (builtins.pathExists "${src}/${completions.fromSource}/zsh") "--zsh ${src}/${completions.fromSource}/*.zsh"} \
          ${lib.optionalString (builtins.pathExists "${src}/${completions.fromSource}/fish") "--fish ${src}/${completions.fromSource}/*.fish"}
      ''
      else "";
  };
}
