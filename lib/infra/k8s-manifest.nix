# Kubernetes Manifest Primitives
#
# Shared pure functions for building K8s manifest attrsets.
# Used by argocd-appset.nix, external-secrets.nix, and environment-config.nix
# to avoid duplicating metadata/syncPolicy/source construction.
#
# No pkgs dependency — these are pure attrset builders.
rec {
  # ── Metadata ───────────────────────────────────────────────────────
  mkMetadata = {
    name,
    namespace ? null,
    annotations ? {},
    labels ? {},
  }: { inherit name; }
    // (if namespace != null then { inherit namespace; } else {})
    // (if annotations != {} then { inherit annotations; } else {})
    // (if labels != {} then { inherit labels; } else {});

  # ── ArgoCD SyncPolicy ─────────────────────────────────────────────
  mkSyncPolicy = {
    preserveResourcesOnDeletion ? true,
    autoSync ? true,
    selfHeal ? true,
    prune ? true,
    retryLimit ? 5,
    retryDuration ? "5s",
    retryFactor ? 2,
    retryMaxDuration ? "3m",
    createNamespace ? true,
    syncOptions ? [],
  }: { inherit preserveResourcesOnDeletion; }
    // (if autoSync then { automated = { inherit selfHeal prune; }; } else {})
    // (if retryLimit > 0 then {
      retry = {
        limit = retryLimit;
        backoff = {
          duration = retryDuration;
          factor = retryFactor;
          maxDuration = retryMaxDuration;
        };
      };
    } else {})
    // (let
      allOpts = (if createNamespace then [ "CreateNamespace=true" ] else []) ++ syncOptions;
    in if allOpts != [] then { syncOptions = allOpts; } else {});

  # ── ArgoCD Helm Source ─────────────────────────────────────────────
  mkHelmSource = {
    repoURL,
    targetRevision ? "master",
    chartPath,
    releaseName ? null,
    valueFiles ? [],
    parameters ? [],
  }: {
    inherit repoURL targetRevision;
    path = chartPath;
    helm = {}
      // (if releaseName != null then { inherit releaseName; } else {})
      // (if valueFiles != [] then { inherit valueFiles; } else {})
      // (if parameters != [] then { inherit parameters; } else {});
  };

  # ── ArgoCD ApplicationSet Envelope ─────────────────────────────────
  # Wraps a generator + template into a complete ApplicationSet.
  mkApplicationSet = {
    name,
    namespace ? "argocd",
    annotations ? {},
    labels ? {},
    generators,
    template,
  }: {
    apiVersion = "argoproj.io/v1alpha1";
    kind = "ApplicationSet";
    metadata = mkMetadata { inherit name namespace annotations labels; };
    spec = {
      goTemplate = true;
      goTemplateOptions = [ "missingkey=error" ];
      inherit generators template;
    };
  };

  # ── ArgoCD Application Template ────────────────────────────────────
  # Wraps source + destination + syncPolicy into an Application template.
  mkAppTemplate = {
    nameTemplate,
    project ? "default",
    source,
    destinationServer,
    namespace ? null,
    syncPolicy ? {},
    ignoreDifferences ? [],
    annotations ? {},
  }: {
    metadata = {
      name = nameTemplate;
    } // (if annotations != {} then { inherit annotations; } else {});
    spec = {
      inherit project source;
      destination = {
        server = destinationServer;
      } // (if namespace != null then { inherit namespace; } else {});
    } // (if syncPolicy != {} then { inherit syncPolicy; } else {})
      // (if ignoreDifferences != [] then { inherit ignoreDifferences; } else {});
  };

  # ── Cluster Selector ───────────────────────────────────────────────
  mkClusterSelector = {
    requiredLabel,
    requiredLabels ? [],
    excludeTenants ? [],
    cloudProviders ? [],
    extraExpressions ? [],
  }: {
    matchExpressions =
      [{ key = requiredLabel; operator = "Exists"; }]
      ++ map (l: { key = l; operator = "Exists"; }) requiredLabels
      ++ (if excludeTenants != [] then [{ key = "tenant"; operator = "NotIn"; values = excludeTenants; }] else [])
      ++ (if cloudProviders != [] then [{ key = "cloudProvider"; operator = "In"; values = cloudProviders; }] else [])
      ++ extraExpressions;
  };

  # ── Manifest Generate Paths Annotation ─────────────────────────────
  mkManifestGeneratePaths = paths:
    { "argocd.argoproj.io/manifest-generate-paths" = builtins.concatStringsSep ";" paths; };
}
