# Devenv module for GitOps development.
#
# Provides: ArgoCD CLI, Helm, kubectl, kustomize, yq, SOPS,
# age, kubeconform, yamllint, and git-hooks for YAML validation.
#
# Usage (in a devenv shell definition):
#   imports = [ "${substrate}/lib/devenv/gitops.nix" ];
{ pkgs, lib, ... }: {

  # Import the infrastructure base for shared K8s + YAML tools
  imports = [ ./infrastructure-base.nix ];

  packages = with pkgs; [
    argocd
    kustomize
    kubeconform
    yamllint
  ] ++ lib.optionals (builtins.hasAttr "kubeseal" pkgs) [
    pkgs.kubeseal
  ];

  env.HELM_EXPERIMENTAL_OCI = "1";

  scripts = {
    validate-yaml = {
      exec = ''
        echo "Validating YAML files..."
        find . -name '*.yaml' -o -name '*.yml' | while read -r f; do
          ${pkgs.yamllint}/bin/yamllint -d relaxed "$f" 2>/dev/null || echo "WARN: $f"
        done
        echo "Done."
      '';
      description = "Validate all YAML files";
    };
    validate-k8s = {
      exec = ''
        echo "Validating Kubernetes manifests..."
        find . -name '*.yaml' -o -name '*.yml' | \
          ${pkgs.kubeconform}/bin/kubeconform -strict -ignore-missing-schemas -summary
      '';
      description = "Validate Kubernetes manifests with kubeconform";
    };
    lint-charts = {
      exec = ''
        for chart in $(find . -name Chart.yaml -exec dirname {} \;); do
          echo "Linting: $chart"
          ${pkgs.kubernetes-helm}/bin/helm lint "$chart" || true
        done
      '';
      description = "Lint all Helm charts";
    };
    argocd-diff = {
      exec = ''
        APP="''${1:?Usage: argocd-diff <app-name>}"
        ${pkgs.argocd}/bin/argocd app diff "$APP" --local .
      '';
      description = "Diff local vs deployed ArgoCD app";
    };
  };

  git-hooks.hooks.yamllint = {
    enable = lib.mkDefault true;
    entry = "${pkgs.yamllint}/bin/yamllint -d relaxed";
    types = [ "yaml" ];
  };
}
