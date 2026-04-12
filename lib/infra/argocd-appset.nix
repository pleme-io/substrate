# ArgoCD ApplicationSet Builder
#
# Reusable patterns for generating ArgoCD ApplicationSet manifests.
# Extracted from production multi-tenant, multi-cloud, multi-region deployments.
#
# Three generator strategies:
#   1. Cluster-generator: cluster labels → tenant/env/region/cloud selection
#   2. Git-generator: git directory structure → environment discovery
#   3. Matrix-generator: git × list cartesian product
#
# All generators compose from shared primitives in k8s-manifest.nix
# and tenant logic from multi-tenant-naming.nix.
#
# Usage:
#   appsetBuilder = import "${substrate}/lib/infra/argocd-appset.nix";
#   appSet = appsetBuilder.mkClusterAppSet pkgs {
#     name = "api-gateway";
#     repoURL = "git@github.com:myorg/environments.git";
#     chartPath = "helm/api-gateway";
#     clusterLabel = "api-gateway";
#     valuesHierarchy = [ "envs/{{tenant}}/{{.metadata.labels.environment}}/values.yaml" ];
#   };
let
  check = import ../types/assertions.nix;
  k8s = import ./k8s-manifest.nix;
  naming = import ./multi-tenant-naming.nix;
in rec {

  # ── Shared: resolve {{tenant}} in value file paths ─────────────────
  resolveValuePaths = { tenantPathLabel ? null, tenantMappings ? {} }: let
    tenantExpr = naming.mkTenantPathExpr { inherit tenantPathLabel tenantMappings; };
  in map (path: builtins.replaceStrings ["{{tenant}}"] [tenantExpr] path);

  # ── Shared: resolve Helm parameters from cluster labels ────────────
  resolveHelmParams = map (p:
    if p ? labelKey
    then { name = p.name; value = "{{.metadata.labels.${p.labelKey}}}"; }
    else { inherit (p) name value; });

  # ── Shared: build manifest-generate-paths from value hierarchy ─────
  valuePathDirs = resolvedPaths: chartPath:
    (map builtins.dirOf resolvedPaths) ++ [ chartPath ];

  # ── Cluster-Generator ApplicationSet ───────────────────────────────
  mkClusterAppSet = pkgs: {
    name,
    project ? "default",
    repoURL,
    chartPath,
    targetRevision ? "master",
    clusterLabel,
    requiredLabels ? [],
    excludeTenants ? [],
    cloudProviders ? [],
    valuesHierarchy ? [],
    helmParameters ? [],
    tenantMappings ? {},
    tenantPathLabel ? null,
    ignoreDifferences ? [],
    namespace ? null,
    createNamespace ? true,
    preserveResourcesOnDeletion ? true,
    autoSync ? true,
    selfHeal ? true,
    prune ? true,
    retryLimit ? 5,
    annotations ? {},
    labels ? {},
  }: let
    _ = check.all [
      (check.nonEmptyStr "name" name)
      (check.nonEmptyStr "repoURL" repoURL)
      (check.nonEmptyStr "chartPath" chartPath)
      (check.str "project" project)
      (check.str "targetRevision" targetRevision)
      (check.bool "autoSync" autoSync)
      (check.bool "selfHeal" selfHeal)
      (check.bool "prune" prune)
      (check.bool "createNamespace" createNamespace)
      (check.positiveInt "retryLimit" retryLimit)
      (check.attrs "annotations" annotations)
      (check.attrs "labels" labels)
    ];
    resolvedValues = resolveValuePaths { inherit tenantPathLabel tenantMappings; } valuesHierarchy;
    resolvedParams = resolveHelmParams helmParameters;
    source = k8s.mkHelmSource {
      inherit repoURL targetRevision chartPath;
      releaseName = "{{ normalize .name }}-${name}";
      valueFiles = resolvedValues;
      parameters = resolvedParams;
    };
    syncPolicy = k8s.mkSyncPolicy {
      inherit preserveResourcesOnDeletion autoSync selfHeal prune retryLimit createNamespace;
    };
    template = k8s.mkAppTemplate {
      nameTemplate = "{{.name}}-${name}";
      inherit project source syncPolicy ignoreDifferences namespace;
      destinationServer = "{{.server}}";
      annotations = k8s.mkManifestGeneratePaths (valuePathDirs resolvedValues chartPath);
    };
    selector = k8s.mkClusterSelector {
      requiredLabel = clusterLabel;
      inherit requiredLabels excludeTenants cloudProviders;
    };
  in k8s.mkApplicationSet {
    inherit name annotations labels;
    generators = [{ clusters = { inherit selector; }; }];
    inherit template;
  };

  # ── Git-Generator ApplicationSet ───────────────────────────────────
  mkGitAppSet = pkgs: {
    name,
    project ? "default",
    repoURL,
    chartPath,
    targetRevision ? "master",
    filePaths,
    valuesHierarchy ? [],
    helmParameters ? [],
    ignoreDifferences ? [],
    namespace ? null,
    createNamespace ? true,
    preserveResourcesOnDeletion ? true,
    autoSync ? true,
    selfHeal ? true,
    prune ? true,
    retryLimit ? 5,
    annotations ? {},
    labels ? {},
  }: let
    resolvedParams = resolveHelmParams helmParameters;
    source = k8s.mkHelmSource {
      inherit repoURL targetRevision chartPath;
      releaseName = name;
      valueFiles = valuesHierarchy;
      parameters = resolvedParams;
    };
    syncPolicy = k8s.mkSyncPolicy {
      inherit preserveResourcesOnDeletion autoSync selfHeal prune retryLimit createNamespace;
    };
    template = k8s.mkAppTemplate {
      nameTemplate = "{{.cluster}}-${name}";
      inherit project source syncPolicy ignoreDifferences namespace;
      destinationServer = "{{.url}}";
    };
  in k8s.mkApplicationSet {
    inherit name annotations labels;
    generators = [{
      git = {
        inherit repoURL;
        revision = targetRevision;
        files = map (path: { inherit path; }) filePaths;
      };
    }];
    inherit template;
  };

  # ── Matrix-Generator ApplicationSet ────────────────────────────────
  mkMatrixAppSet = pkgs: {
    name,
    project ? "default",
    repoURL,
    chartPath,
    targetRevision ? "master",
    filePaths,
    elements,
    valuesHierarchy ? [],
    helmParameters ? [],
    ignoreDifferences ? [],
    namespace ? null,
    createNamespace ? true,
    preserveResourcesOnDeletion ? true,
    autoSync ? true,
    selfHeal ? true,
    prune ? true,
    retryLimit ? 5,
    annotations ? {},
    labels ? {},
  }: let
    resolvedParams = resolveHelmParams helmParameters;
    source = k8s.mkHelmSource {
      inherit repoURL targetRevision chartPath;
      valueFiles = valuesHierarchy;
      parameters = resolvedParams;
    };
    syncPolicy = k8s.mkSyncPolicy {
      inherit preserveResourcesOnDeletion autoSync selfHeal prune retryLimit createNamespace;
    };
    template = k8s.mkAppTemplate {
      nameTemplate = "{{.cluster}}-${name}";
      inherit project source syncPolicy ignoreDifferences namespace;
      destinationServer = "{{.url}}";
    };
  in k8s.mkApplicationSet {
    inherit name annotations labels;
    generators = [{
      matrix.generators = [
        { git = { inherit repoURL; revision = targetRevision; files = map (path: { inherit path; }) filePaths; }; }
        { list = { inherit elements; }; }
      ];
    }];
    inherit template;
  };

  # ── YAML Derivation from any AppSet ────────────────────────────────
  mkAppSetYaml = pkgs: appSet:
    let json = pkgs.writeText "${appSet.metadata.name}-appset.json" (builtins.toJSON appSet);
    in pkgs.runCommand "${appSet.metadata.name}-appset-yaml" {
      nativeBuildInputs = [ pkgs.yq-go ];
    } ''
      mkdir -p $out
      yq -P '.' ${json} > $out/${appSet.metadata.name}-appset.yaml
    '';

  mkClusterAppSetYaml = pkgs: args: mkAppSetYaml pkgs (mkClusterAppSet pkgs args);

  # ── Batch Suite ────────────────────────────────────────────────────
  mkAppSetSuite = pkgs: { services, outputDir ? "argocd-appsets" }: let
    lib = pkgs.lib;
    yamls = lib.mapAttrsToList (svcName: svcDef: let
      appSet =
        if svcDef ? filePaths
        then mkGitAppSet pkgs (svcDef // { name = svcName; })
        else mkClusterAppSet pkgs (svcDef // { name = svcName; });
      json = pkgs.writeText "${svcName}-appset.json" (builtins.toJSON appSet);
    in { name = svcName; inherit json; }) services;
  in pkgs.runCommand "appset-suite" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
    mkdir -p $out/${outputDir}
    ${lib.concatMapStringsSep "\n" (y: ''
      yq -P '.' ${y.json} > $out/${outputDir}/${y.name}-generator.yaml
    '') yamls}
  '';

  # ── IgnoreDifferences Presets ──────────────────────────────────────
  ignoreDifferencesPresets = {
    hpa = [
      { group = "apps"; kind = "Deployment"; jqPathExpressions = [ ".spec.replicas" ]; }
      { group = "autoscaling"; kind = "HorizontalPodAutoscaler"; jqPathExpressions = [ ".spec.metrics" ".status" ]; }
    ];
    webhookCaBundle = [
      { group = "admissionregistration.k8s.io"; kind = "MutatingWebhookConfiguration"; jqPathExpressions = [ ".webhooks[].clientConfig.caBundle" ]; }
      { group = "admissionregistration.k8s.io"; kind = "ValidatingWebhookConfiguration"; jqPathExpressions = [ ".webhooks[].clientConfig.caBundle" ]; }
    ];
    configMapTimestamps = [
      { group = ""; kind = "ConfigMap"; jqPathExpressions = [ ".data.install_id" ".data.install_time" ".data.install_info" ]; }
    ];
    secretData = [
      { group = ""; kind = "Secret"; jsonPointers = [ "/data" ]; }
    ];
  };
}
