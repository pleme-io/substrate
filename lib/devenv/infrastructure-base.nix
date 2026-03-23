# Devenv base module for infrastructure/K8s-adjacent development.
#
# Shared packages used by both gitops.nix and infrastructure.nix:
# kubectl, helm, yq, jq, sops, age, git.
#
# Not intended for direct import — use gitops.nix or infrastructure.nix.
{ pkgs, lib, ... }: {
  packages = with pkgs; [
    kubectl
    kubernetes-helm
    yq-go
    jq
    sops
    age
    git
  ];
}
