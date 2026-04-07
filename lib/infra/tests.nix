# Infrastructure Module Tests
#
# Pure Nix evaluation tests for all infra builders.
# No builds, no pkgs, instant feedback.
#
# Usage:
#   nix eval .#lib.aarch64-darwin --apply 'lib: (import ./lib/infra/tests.nix).summary'
#   nix eval .#lib.aarch64-darwin --apply 'lib: (import ./lib/infra/tests.nix).allPassed'
let
  testHelpers = import ../util/test-helpers.nix { lib = (import <nixpkgs> { system = "aarch64-darwin"; }).lib; };
  naming = import ./multi-tenant-naming.nix;
  k8s = import ./k8s-manifest.nix;
  appset = import ./argocd-appset.nix;
  es = import ./external-secrets.nix;
  valuesComp = import ./helm-values-composition.nix;

  inherit (testHelpers) mkTest runTests;
in runTests [

  # ════════════════════════════════════════════════════════════════════
  # multi-tenant-naming.nix
  # ════════════════════════════════════════════════════════════════════

  # -- mkResourceName --
  (mkTest "naming-named-tenant"
    (naming.mkResourceName { tenant = "customer-a"; environment = "production"; region = "us-east-2"; resource = "eks"; }
      == "customer-a-production-us-east-2-eks")
    "named tenant should include tenant prefix")

  (mkTest "naming-default-tenant-mte"
    (naming.mkResourceName { tenant = "mte"; environment = "production"; region = "us-east-2"; resource = "eks"; }
      == "us-east-2-production-eks")
    "mte tenant should omit tenant prefix")

  (mkTest "naming-default-tenant-empty"
    (naming.mkResourceName { tenant = ""; environment = "staging"; region = "eu-west-1"; resource = "rds"; }
      == "eu-west-1-staging-rds")
    "empty tenant should omit tenant prefix")

  (mkTest "naming-no-region"
    (naming.mkResourceName { tenant = "cvs"; environment = "production"; resource = "kms"; }
      == "cvs-production-kms")
    "null region should be omitted")

  (mkTest "naming-no-resource"
    (naming.mkResourceName { tenant = "cvs"; environment = "production"; region = "us-east-2"; }
      == "cvs-production-us-east-2")
    "null resource should be omitted")

  (mkTest "naming-custom-separator"
    (naming.mkResourceName { tenant = "cvs"; environment = "prod"; region = "use2"; separator = "_"; }
      == "cvs_prod_use2")
    "custom separator should be used")

  (mkTest "naming-max-length"
    (naming.mkResourceName { tenant = "customer"; environment = "production"; region = "us-east-2"; resource = "eks"; maxLength = 20; }
      == "customer-production-")
    "maxLength should truncate")

  (mkTest "naming-custom-default-tenants"
    (naming.mkResourceName { tenant = "shared"; environment = "prod"; region = "us1"; defaultTenants = [ "shared" ]; }
      == "us1-prod")
    "custom defaultTenants should be respected")

  # -- isDefaultTenant --
  (mkTest "is-default-mte"
    (naming.isDefaultTenant { tenant = "mte"; })
    "mte should be default")

  (mkTest "is-default-empty"
    (naming.isDefaultTenant { tenant = ""; })
    "empty should be default")

  (mkTest "is-not-default-cvs"
    (!(naming.isDefaultTenant { tenant = "cvs"; }))
    "cvs should not be default")

  # -- mkNamingScheme --
  (let s = naming.mkNamingScheme { tenant = "cvs"; environment = "production"; region = "us-east-2"; };
  in mkTest "scheme-prefix"
    (s.prefix == "cvs-production-us-east-2")
    "scheme prefix should match")

  (let s = naming.mkNamingScheme { tenant = "cvs"; environment = "production"; region = "us-east-2"; };
  in mkTest "scheme-eks"
    (s.eksCluster == "cvs-production-us-east-2-eks")
    "scheme eksCluster should append -eks")

  (let s = naming.mkNamingScheme { tenant = "cvs"; environment = "production"; region = "us-east-2"; };
  in mkTest "scheme-rds"
    (s.rdsInstance "gateway" == "cvs-production-us-east-2-gateway-rds")
    "scheme rdsInstance should append service-rds")

  (let s = naming.mkNamingScheme { tenant = "mte"; environment = "production"; region = "us-east-2"; };
  in mkTest "scheme-default-tenant"
    (s.prefix == "us-east-2-production")
    "default tenant scheme should omit tenant")

  (let s = naming.mkNamingScheme { tenant = "cvs"; environment = "production"; region = "us-east-2"; cloudProvider = "AWS"; };
  in mkTest "scheme-labels"
    (s.labels == { tenant = "cvs"; environment = "production"; region = "us-east-2"; cloudProvider = "AWS"; })
    "scheme labels should include all dimensions")

  # -- mkTenantExpr --
  (mkTest "tenant-expr-no-mappings"
    (naming.mkTenantExpr {} == "{{.metadata.labels.tenant}}")
    "no mappings should return raw label")

  (mkTest "tenant-expr-single-mapping"
    (builtins.match ".*if eq .metadata.labels.tenant \"mte\".*akeyless_global.*" (naming.mkTenantExpr { tenantMappings = { mte = "akeyless_global"; }; }) != null)
    "single mapping should produce if/else")

  # -- mkTenantPathExpr --
  (mkTest "tenant-path-expr-with-label"
    (naming.mkTenantPathExpr { tenantPathLabel = "tenant_path"; }
      == ''{{ or (index .metadata.labels "tenant_path") (index .metadata.labels "tenant") }}'')
    "tenantPathLabel should produce or expression")

  (mkTest "tenant-path-expr-no-label"
    (naming.mkTenantPathExpr {} == "{{.metadata.labels.tenant}}")
    "no tenantPathLabel should fall through to mkTenantExpr")

  # -- mkTerraformNamingLocals --
  (mkTest "tf-locals-contains-prefix"
    (builtins.match ".*resource_prefix.*" (naming.mkTerraformNamingLocals {}) != null)
    "terraform locals should contain resource_prefix")

  (mkTest "tf-locals-contains-tenant-env"
    (builtins.match ".*tenant_env.*" (naming.mkTerraformNamingLocals {}) != null)
    "terraform locals should contain tenant_env")

  # ════════════════════════════════════════════════════════════════════
  # k8s-manifest.nix
  # ════════════════════════════════════════════════════════════════════

  (mkTest "metadata-minimal"
    (k8s.mkMetadata { name = "test"; } == { name = "test"; })
    "minimal metadata should only have name")

  (mkTest "metadata-full"
    (k8s.mkMetadata { name = "test"; namespace = "ns"; labels = { a = "b"; }; annotations = { c = "d"; }; }
      == { name = "test"; namespace = "ns"; labels = { a = "b"; }; annotations = { c = "d"; }; })
    "full metadata should include all fields")

  (mkTest "metadata-omits-empty"
    (!(k8s.mkMetadata { name = "test"; } ? namespace))
    "null namespace should be omitted")

  (mkTest "sync-policy-defaults"
    (let sp = k8s.mkSyncPolicy {};
    in sp.preserveResourcesOnDeletion && sp ? automated && sp.automated.selfHeal && sp.automated.prune && sp ? retry)
    "default syncPolicy should have automated + retry + preserve")

  (mkTest "sync-policy-no-auto"
    (let sp = k8s.mkSyncPolicy { autoSync = false; };
    in !(sp ? automated))
    "autoSync=false should omit automated")

  (mkTest "sync-policy-no-retry"
    (let sp = k8s.mkSyncPolicy { retryLimit = 0; };
    in !(sp ? retry))
    "retryLimit=0 should omit retry")

  (mkTest "sync-policy-create-ns"
    (let sp = k8s.mkSyncPolicy {};
    in builtins.elem "CreateNamespace=true" sp.syncOptions)
    "createNamespace should add syncOption")

  (mkTest "sync-policy-no-create-ns"
    (let sp = k8s.mkSyncPolicy { createNamespace = false; };
    in !(sp ? syncOptions) || sp.syncOptions == [])
    "createNamespace=false should omit syncOption")

  (mkTest "cluster-selector-minimal"
    (let s = k8s.mkClusterSelector { requiredLabel = "my-svc"; };
    in s.matchExpressions == [{ key = "my-svc"; operator = "Exists"; }])
    "minimal selector should have one Exists expression")

  (mkTest "cluster-selector-exclude"
    (let s = k8s.mkClusterSelector { requiredLabel = "svc"; excludeTenants = [ "walmart" ]; };
    in builtins.length s.matchExpressions == 2
      && (builtins.elemAt s.matchExpressions 1).operator == "NotIn")
    "excludeTenants should add NotIn expression")

  (mkTest "cluster-selector-cloud"
    (let s = k8s.mkClusterSelector { requiredLabel = "svc"; cloudProviders = [ "AWS" "aws" ]; };
    in builtins.length s.matchExpressions == 2
      && (builtins.elemAt s.matchExpressions 1).operator == "In")
    "cloudProviders should add In expression")

  (mkTest "helm-source-minimal"
    (let s = k8s.mkHelmSource { repoURL = "git@github.com:o/r.git"; chartPath = "charts/x"; };
    in s.repoURL == "git@github.com:o/r.git" && s.path == "charts/x" && !(s.helm ? releaseName))
    "minimal helm source should omit optional fields")

  (mkTest "helm-source-full"
    (let s = k8s.mkHelmSource { repoURL = "u"; chartPath = "p"; releaseName = "r"; valueFiles = ["a"]; parameters = [{ name = "x"; value = "y"; }]; };
    in s.helm.releaseName == "r" && s.helm.valueFiles == ["a"] && builtins.length s.helm.parameters == 1)
    "full helm source should include all fields")

  (mkTest "appset-envelope"
    (let a = k8s.mkApplicationSet { name = "test"; generators = []; template = {}; };
    in a.apiVersion == "argoproj.io/v1alpha1" && a.kind == "ApplicationSet" && a.spec.goTemplate)
    "ApplicationSet envelope should have correct apiVersion and goTemplate")

  (mkTest "manifest-generate-paths"
    (let p = k8s.mkManifestGeneratePaths [ "a/b" "c/d" ];
    in p."argocd.argoproj.io/manifest-generate-paths" == "a/b;c/d")
    "manifest-generate-paths should join with semicolons")

  # ════════════════════════════════════════════════════════════════════
  # argocd-appset.nix
  # ════════════════════════════════════════════════════════════════════

  (mkTest "resolve-value-paths-no-mappings"
    (appset.resolveValuePaths {} [ "envs/{{tenant}}/values.yaml" ]
      == [ "envs/{{.metadata.labels.tenant}}/values.yaml" ])
    "resolveValuePaths with no mappings should use raw tenant label")

  (mkTest "resolve-value-paths-with-path-label"
    (let r = appset.resolveValuePaths { tenantPathLabel = "tenant_path"; } [ "envs/{{tenant}}/values.yaml" ];
    in builtins.match ".*or.*tenant_path.*tenant.*" (builtins.head r) != null)
    "resolveValuePaths with tenantPathLabel should use or expression")

  (mkTest "resolve-helm-params-label"
    (appset.resolveHelmParams [{ name = "region"; labelKey = "region"; }]
      == [{ name = "region"; value = "{{.metadata.labels.region}}"; }])
    "resolveHelmParams should interpolate label key")

  (mkTest "resolve-helm-params-value"
    (appset.resolveHelmParams [{ name = "x"; value = "static"; }]
      == [{ name = "x"; value = "static"; }])
    "resolveHelmParams should pass through static values")

  (mkTest "ignore-presets-hpa"
    (builtins.length appset.ignoreDifferencesPresets.hpa == 2)
    "HPA preset should have 2 entries")

  (mkTest "ignore-presets-webhook"
    (builtins.length appset.ignoreDifferencesPresets.webhookCaBundle == 2)
    "webhook preset should have 2 entries")

  # ════════════════════════════════════════════════════════════════════
  # external-secrets.nix
  # ════════════════════════════════════════════════════════════════════

  (let m = es.mkExternalSecret {
    name = "test-secret";
    secretStoreName = "my-store";
    secrets = [{ secretKey = "pw"; remotePath = "/path/pw"; }];
  };
  in mkTest "es-basic"
    (m.apiVersion == "external-secrets.io/v1beta1"
      && m.kind == "ExternalSecret"
      && m.metadata.name == "test-secret"
      && m.spec.secretStoreRef.name == "my-store"
      && builtins.length m.spec.data == 1)
    "basic ExternalSecret should have correct structure")

  (let m = es.mkExternalSecret {
    name = "test"; secretStoreName = "s";
    secrets = [{ secretKey = "k"; remotePath = "/p"; property = "nested.key"; version = "1"; }];
  };
  in mkTest "es-secret-with-property-version"
    (let d = builtins.head m.spec.data;
    in d.remoteRef.property == "nested.key" && d.remoteRef.version == "1")
    "secret with property/version should include them in remoteRef")

  (let m = es.mkExternalSecret {
    name = "test"; secretStoreName = "s";
    targetLabels = { app = "gw"; }; secretType = "kubernetes.io/tls";
  };
  in mkTest "es-template-no-collision"
    (m.spec.target.template.type == "kubernetes.io/tls"
      && m.spec.target.template.metadata.labels.app == "gw")
    "secretType + targetLabels should both be present without collision")

  (let m = es.mkExternalSecret {
    name = "test"; secretStoreName = "s";
    template = { type = "Opaque"; data = { custom = "base64data"; }; };
  };
  in mkTest "es-explicit-template-wins"
    (m.spec.target.template.type == "Opaque" && m.spec.target.template.data.custom == "base64data")
    "explicit template should override secretType and targetLabels")

  (let m = es.mkExternalSecret {
    name = "test"; secretStoreName = "s"; namespace = "prod";
    labels = { team = "platform"; }; annotations = { note = "auto"; };
  };
  in mkTest "es-metadata"
    (m.metadata.namespace == "prod" && m.metadata.labels.team == "platform" && m.metadata.annotations.note == "auto")
    "metadata should include namespace, labels, annotations")

  (let s = es.mkClusterSecretStore {
    name = "akeyless-store"; provider = "akeyless";
    providerConfig = { gatewayUrl = "https://gw.example.com"; };
  };
  in mkTest "css-akeyless"
    (s.spec.provider.akeyless.akeylessGWApiURL == "https://gw.example.com")
    "akeyless ClusterSecretStore should use gatewayUrl")

  (let s = es.mkClusterSecretStore {
    name = "aws-store"; provider = "aws";
    providerConfig = { region = "eu-west-1"; role = "arn:aws:iam::123:role/x"; };
  };
  in mkTest "css-aws"
    (s.spec.provider.aws.region == "eu-west-1" && s.spec.provider.aws.role == "arn:aws:iam::123:role/x")
    "aws ClusterSecretStore should include region and role")

  (let paths = es.mkSecretPaths {
    basePath = "/platform/secrets";
    keys = [ "db-password" "api-key" ];
    environment = "production";
  };
  in mkTest "secret-paths-concrete"
    (builtins.length paths == 2
      && (builtins.head paths).remotePath == "/platform/secrets/production/db-password")
    "concrete secret paths should resolve environment")

  (let paths = es.mkSecretPaths {
    basePath = "/platform/secrets";
    keys = [ "db-password" ];
  };
  in mkTest "secret-paths-helm-template"
    (builtins.match ".*\\$\\.Values\\.environment.*" (builtins.head paths).remotePath != null)
    "unresolved secret paths should use Helm template")

  (let t = es.mkExternalSecretHelmTemplate {
    name = "test"; secretStoreName = "store";
    secrets = [{ secretKey = "pw"; remotePath = "/path/pw"; }];
    condition = ".Values.es.enabled";
  };
  in mkTest "es-helm-template-condition"
    (builtins.match ".*if .Values.es.enabled.*" t != null
      && builtins.match ".*end.*" t != null)
    "Helm template should wrap in condition")

  (let t = es.mkExternalSecretHelmTemplate {
    name = "test"; secretStoreName = "store";
    secrets = [
      { secretKey = "a"; remotePath = "/a"; }
      { secretKey = "b"; remotePath = "/b"; }
    ];
    secretConditions = { b = ".Values.includeB"; };
  };
  in mkTest "es-helm-template-per-secret-condition"
    (builtins.match ".*if .Values.includeB.*" t != null)
    "per-secret condition should appear in template")

  # ════════════════════════════════════════════════════════════════════
  # helm-values-composition.nix (pure parts only)
  # ════════════════════════════════════════════════════════════════════
  # Note: mkValuesHierarchy requires pkgs (for writeShellScript), so we
  # test the pure path resolution logic indirectly via naming + appset.

  # ════════════════════════════════════════════════════════════════════
  # Cross-module composition
  # ════════════════════════════════════════════════════════════════════

  (let
    scheme = naming.mkNamingScheme { tenant = "cvs"; environment = "production"; region = "us-east-2"; cloudProvider = "AWS"; };
    secret = es.mkExternalSecret {
      name = "${scheme.prefix}-gateway-secret";
      secretStoreName = "akeyless-store";
      secrets = [{ secretKey = "api-key"; remotePath = "/platform/${scheme.prefix}/api-key"; }];
      labels = scheme.labels;
    };
  in mkTest "cross-naming-es"
    (secret.metadata.name == "cvs-production-us-east-2-gateway-secret"
      && secret.metadata.labels.tenant == "cvs"
      && (builtins.head secret.spec.data).remoteRef.key == "/platform/cvs-production-us-east-2/api-key")
    "naming scheme should compose with ExternalSecret builder")

  (let
    tenantExpr = naming.mkTenantPathExpr { tenantPathLabel = "tenant_path"; tenantMappings = { mte = "akeyless_global"; }; };
  in mkTest "cross-naming-appset-tenant"
    (builtins.match ".*or.*tenant_path.*" tenantExpr != null)
    "tenantPathLabel should take priority over tenantMappings")

  # ════════════════════════════════════════════════════════════════════
  # Edge-case coverage: multi-tenant-naming.nix
  # ════════════════════════════════════════════════════════════════════

  (mkTest "naming-all-null-optional"
    (naming.mkResourceName { tenant = "cvs"; environment = "prod"; }
      == "cvs-prod")
    "both region and resource null should produce just tenant-environment")

  (mkTest "naming-empty-string-resource"
    (naming.mkResourceName { tenant = "cvs"; environment = "prod"; region = "us1"; resource = ""; }
      == "cvs-prod-us1")
    "empty string resource should be filtered out like null")

  (mkTest "naming-max-length-exact"
    (let name = naming.mkResourceName { tenant = "ab"; environment = "cd"; separator = "-"; maxLength = 5; };
    in name == "ab-cd")
    "maxLength equal to string length should not truncate")

  (mkTest "naming-max-length-over"
    (let name = naming.mkResourceName { tenant = "ab"; environment = "cd"; separator = "-"; maxLength = 10; };
    in name == "ab-cd")
    "maxLength larger than string should not truncate")

  (mkTest "naming-default-tenant-literal"
    (naming.isDefaultTenant { tenant = "default"; })
    "'default' string should be treated as default tenant")

  (mkTest "naming-scheme-s3-bucket"
    (let s = naming.mkNamingScheme { tenant = "cvs"; environment = "production"; region = "us-east-2"; };
    in s.s3Bucket "logs" == "cvs-production-us-east-2-logs-s3")
    "scheme s3Bucket should append purpose-s3")

  (mkTest "naming-scheme-kms-key"
    (let s = naming.mkNamingScheme { tenant = "cvs"; environment = "production"; region = "us-east-2"; };
    in s.kmsKey "encryption" == "cvs-production-us-east-2-encryption-kms")
    "scheme kmsKey should append purpose-kms")

  (mkTest "naming-scheme-namespace"
    (let s = naming.mkNamingScheme { tenant = "cvs"; environment = "production"; region = "us-east-2"; };
    in s.namespace == "cvs-production-us-east-2-ns")
    "scheme namespace should append -ns")

  (mkTest "naming-scheme-labels-no-cloud"
    (let s = naming.mkNamingScheme { tenant = "cvs"; environment = "production"; region = "us-east-2"; };
    in !(s.labels ? cloudProvider))
    "scheme labels without cloudProvider should omit it")

  (mkTest "naming-scheme-labels-no-region"
    (let s = naming.mkNamingScheme { tenant = "cvs"; environment = "production"; };
    in !(s.labels ? region))
    "scheme labels without region should omit it")

  (mkTest "naming-tenant-expr-multiple-mappings"
    (let expr = naming.mkTenantExpr { tenantMappings = { mte = "global"; shared = "shared_path"; }; };
    in builtins.match ".*if eq.*" expr != null
      && builtins.match ".*end.*" expr != null)
    "multiple tenantMappings should produce nested if/else GoTemplate")

  (mkTest "naming-tf-locals-custom-vars"
    (let hcl = naming.mkTerraformNamingLocals {
      tenantVar = "local.tenant";
      environmentVar = "local.env";
      regionVar = "local.region";
    };
    in builtins.match ".*local\\.tenant.*" hcl != null
      && builtins.match ".*local\\.env.*" hcl != null)
    "mkTerraformNamingLocals should use custom variable names")

  (mkTest "naming-tf-locals-custom-local-names"
    (let hcl = naming.mkTerraformNamingLocals {
      prefixLocal = "my_prefix";
      tenantEnvLocal = "my_tenant_env";
    };
    in builtins.match ".*my_prefix.*" hcl != null
      && builtins.match ".*my_tenant_env.*" hcl != null)
    "mkTerraformNamingLocals should use custom local names")

  # ════════════════════════════════════════════════════════════════════
  # Edge-case coverage: k8s-manifest.nix
  # ════════════════════════════════════════════════════════════════════

  (mkTest "metadata-with-all-fields"
    (let m = k8s.mkMetadata { name = "x"; namespace = "ns"; labels = { a = "1"; }; annotations = { b = "2"; }; };
    in m.name == "x" && m.namespace == "ns" && m.labels.a == "1" && m.annotations.b == "2")
    "metadata with all fields should include everything")

  (mkTest "metadata-empty-labels-omitted"
    (let m = k8s.mkMetadata { name = "x"; labels = {}; annotations = {}; };
    in !(m ? labels) && !(m ? annotations))
    "empty labels and annotations should be omitted from metadata")

  (mkTest "sync-policy-custom-retry"
    (let sp = k8s.mkSyncPolicy { retryDuration = "10s"; retryFactor = 3; retryMaxDuration = "5m"; };
    in sp.retry.backoff.duration == "10s"
      && sp.retry.backoff.factor == 3
      && sp.retry.backoff.maxDuration == "5m")
    "custom retry parameters should propagate to backoff config")

  (mkTest "sync-policy-custom-sync-options"
    (let sp = k8s.mkSyncPolicy { syncOptions = ["ServerSideApply=true" "PrunePropagationPolicy=foreground"]; };
    in builtins.length sp.syncOptions == 3
      && builtins.elem "CreateNamespace=true" sp.syncOptions
      && builtins.elem "ServerSideApply=true" sp.syncOptions)
    "custom syncOptions should be appended to default CreateNamespace option")

  (mkTest "sync-policy-no-auto-no-prune"
    (let sp = k8s.mkSyncPolicy { autoSync = false; prune = false; };
    in !(sp ? automated))
    "autoSync=false should omit automated regardless of prune setting")

  (mkTest "app-template-minimal"
    (let t = k8s.mkAppTemplate {
      nameTemplate = "{{.name}}-svc";
      source = { repoURL = "u"; path = "p"; };
      destinationServer = "{{.server}}";
    };
    in t.metadata.name == "{{.name}}-svc"
      && t.spec.project == "default"
      && t.spec.source.repoURL == "u"
      && t.spec.destination.server == "{{.server}}"
      && !(t.spec.destination ? namespace)
      && !(t.spec ? syncPolicy)
      && !(t.spec ? ignoreDifferences))
    "minimal app template should omit optional fields")

  (mkTest "app-template-full"
    (let t = k8s.mkAppTemplate {
      nameTemplate = "t";
      project = "infra";
      source = {};
      destinationServer = "s";
      namespace = "prod";
      syncPolicy = { automated = {}; };
      ignoreDifferences = [{ group = "apps"; kind = "Deployment"; }];
      annotations = { "note" = "test"; };
    };
    in t.spec.project == "infra"
      && t.spec.destination.namespace == "prod"
      && t.spec ? syncPolicy
      && builtins.length t.spec.ignoreDifferences == 1
      && t.metadata.annotations.note == "test")
    "full app template should include all optional fields")

  (mkTest "cluster-selector-required-labels"
    (let s = k8s.mkClusterSelector { requiredLabel = "svc"; requiredLabels = ["tier" "env"]; };
    in builtins.length s.matchExpressions == 3
      && (builtins.elemAt s.matchExpressions 1).key == "tier"
      && (builtins.elemAt s.matchExpressions 2).key == "env")
    "requiredLabels should add additional Exists expressions")

  (mkTest "cluster-selector-extra-expressions"
    (let s = k8s.mkClusterSelector {
      requiredLabel = "svc";
      extraExpressions = [{ key = "custom"; operator = "In"; values = ["a"]; }];
    };
    in builtins.length s.matchExpressions == 2
      && (builtins.elemAt s.matchExpressions 1).key == "custom")
    "extraExpressions should be appended to matchExpressions")

  (mkTest "cluster-selector-all-filters"
    (let s = k8s.mkClusterSelector {
      requiredLabel = "svc";
      requiredLabels = ["extra"];
      excludeTenants = ["old"];
      cloudProviders = ["AWS"];
      extraExpressions = [{ key = "x"; operator = "Exists"; }];
    };
    in builtins.length s.matchExpressions == 5)
    "all selector options combined should produce correct expression count")

  (mkTest "appset-namespace-default"
    (let a = k8s.mkApplicationSet { name = "test"; generators = []; template = {}; };
    in a.metadata.namespace == "argocd")
    "ApplicationSet should default to argocd namespace")

  (mkTest "appset-custom-namespace"
    (let a = k8s.mkApplicationSet { name = "test"; namespace = "gitops"; generators = []; template = {}; };
    in a.metadata.namespace == "gitops")
    "ApplicationSet should accept custom namespace")

  (mkTest "appset-labels-annotations"
    (let a = k8s.mkApplicationSet {
      name = "test"; generators = []; template = {};
      labels = { team = "platform"; };
      annotations = { "managed-by" = "nix"; };
    };
    in a.metadata.labels.team == "platform"
      && a.metadata.annotations."managed-by" == "nix")
    "ApplicationSet should propagate labels and annotations to metadata")

  (mkTest "appset-go-template-options"
    (let a = k8s.mkApplicationSet { name = "test"; generators = []; template = {}; };
    in a.spec.goTemplateOptions == [ "missingkey=error" ])
    "ApplicationSet should set goTemplateOptions with missingkey=error")

  (mkTest "manifest-generate-paths-single"
    (let p = k8s.mkManifestGeneratePaths [ "a/b" ];
    in p."argocd.argoproj.io/manifest-generate-paths" == "a/b")
    "single path should not have semicolons")

  (mkTest "manifest-generate-paths-empty"
    (let p = k8s.mkManifestGeneratePaths [];
    in p."argocd.argoproj.io/manifest-generate-paths" == "")
    "empty paths should produce empty string")

  # ════════════════════════════════════════════════════════════════════
  # Edge-case coverage: external-secrets.nix
  # ════════════════════════════════════════════════════════════════════

  (let m = es.mkExternalSecret {
    name = "test"; secretStoreName = "s";
    dataFrom = [{ extract = { key = "/path/all"; }; }];
  };
  in mkTest "es-data-from"
    (builtins.length m.spec.dataFrom == 1
      && (builtins.head m.spec.dataFrom).extract.key == "/path/all")
    "dataFrom should be included when provided")

  (let m = es.mkExternalSecret {
    name = "test"; secretStoreName = "s";
  };
  in mkTest "es-no-data-no-data-from"
    (!(m.spec ? data) && !(m.spec ? dataFrom))
    "empty secrets and dataFrom should omit both fields")

  (let m = es.mkExternalSecret {
    name = "test"; secretStoreName = "s";
    secretStoreKind = "SecretStore";
  };
  in mkTest "es-secret-store-kind"
    (m.spec.secretStoreRef.kind == "SecretStore")
    "custom secretStoreKind should override ClusterSecretStore default")

  (let m = es.mkExternalSecret {
    name = "test"; secretStoreName = "s";
    targetName = "custom-target";
    refreshInterval = "30m";
    creationPolicy = "Merge";
    deletionPolicy = "Delete";
  };
  in mkTest "es-target-customization"
    (m.spec.target.name == "custom-target"
      && m.spec.refreshInterval == "30m"
      && m.spec.target.creationPolicy == "Merge"
      && m.spec.target.deletionPolicy == "Delete")
    "target customization fields should all propagate")

  (let m = es.mkExternalSecret {
    name = "test"; secretStoreName = "s";
    targetLabels = { app = "gw"; };
    targetAnnotations = { note = "auto"; };
  };
  in mkTest "es-target-labels-and-annotations"
    (m.spec.target.template.metadata.labels.app == "gw"
      && m.spec.target.template.metadata.annotations.note == "auto")
    "targetLabels and targetAnnotations should both appear in template.metadata")

  (let m = es.mkExternalSecret {
    name = "test"; secretStoreName = "s";
    targetAnnotations = { note = "auto"; };
  };
  in mkTest "es-annotations-without-labels"
    (m.spec.target.template.metadata.annotations.note == "auto"
      && !(m.spec.target.template.metadata ? labels))
    "targetAnnotations alone should not include empty labels")

  # ClusterSecretStore — vault provider
  (let s = es.mkClusterSecretStore {
    name = "vault-store"; provider = "vault";
    providerConfig = { server = "https://vault.myorg.com"; path = "kv"; version = "v2"; };
  };
  in mkTest "css-vault"
    (s.spec.provider.vault.server == "https://vault.myorg.com"
      && s.spec.provider.vault.path == "kv"
      && s.spec.provider.vault.version == "v2")
    "vault ClusterSecretStore should include server, path, and version")

  # ClusterSecretStore — azure provider
  (let s = es.mkClusterSecretStore {
    name = "azure-store"; provider = "azure";
    providerConfig = { vaultUrl = "https://myvault.vault.azure.net"; };
  };
  in mkTest "css-azure"
    (s.spec.provider.azurekv.vaultUrl == "https://myvault.vault.azure.net")
    "azure ClusterSecretStore should use azurekv key with vaultUrl")

  # ClusterSecretStore — gcp provider
  (let s = es.mkClusterSecretStore {
    name = "gcp-store"; provider = "gcp";
    providerConfig = { projectID = "my-project-123"; };
  };
  in mkTest "css-gcp"
    (s.spec.provider.gcpsm.projectID == "my-project-123")
    "gcp ClusterSecretStore should use gcpsm key with projectID")

  # ClusterSecretStore metadata
  (let s = es.mkClusterSecretStore {
    name = "store"; provider = "akeyless";
    labels = { team = "platform"; };
    annotations = { managed = "nix"; };
  };
  in mkTest "css-metadata"
    (s.metadata.labels.team == "platform"
      && s.metadata.annotations.managed == "nix")
    "ClusterSecretStore should propagate labels and annotations")

  # mkSecretPaths with all resolved values
  (let paths = es.mkSecretPaths {
    basePath = "/secrets";
    keys = [ "a" "b" ];
    environment = "staging";
    tenant = "cvs";
    service = "api";
  };
  in mkTest "secret-paths-all-resolved"
    (builtins.length paths == 2
      && (builtins.head paths).remotePath == "/secrets/staging/a"
      && (builtins.head paths).secretKey == "a")
    "all resolved values should produce concrete paths")

  # mkSecretPaths with custom template
  (let paths = es.mkSecretPaths {
    basePath = "/vault";
    keys = [ "key1" ];
    pathTemplate = "{basePath}/{tenant}/{env}/{key}";
    environment = "prod";
    tenant = "myco";
  };
  in mkTest "secret-paths-custom-template"
    ((builtins.head paths).remotePath == "/vault/myco/prod/key1")
    "custom pathTemplate should be interpolated correctly")

  # ════════════════════════════════════════════════════════════════════
  # Edge-case coverage: argocd-appset.nix
  # ════════════════════════════════════════════════════════════════════

  (mkTest "ignore-presets-configmap"
    (builtins.length appset.ignoreDifferencesPresets.configMapTimestamps == 1)
    "configMapTimestamps preset should have 1 entry")

  (mkTest "ignore-presets-secret"
    (builtins.length appset.ignoreDifferencesPresets.secretData == 1)
    "secretData preset should have 1 entry")

  (mkTest "resolve-helm-params-empty"
    (appset.resolveHelmParams [] == [])
    "resolveHelmParams on empty list should return empty list")

  (mkTest "resolve-value-paths-empty"
    (appset.resolveValuePaths {} [] == [])
    "resolveValuePaths on empty list should return empty list")

  (mkTest "resolve-value-paths-no-tenant-placeholder"
    (appset.resolveValuePaths {} [ "envs/global/values.yaml" ]
      == [ "envs/global/values.yaml" ])
    "path without {{tenant}} should be returned unchanged")

  (mkTest "resolve-helm-params-mixed"
    (let r = appset.resolveHelmParams [
      { name = "region"; labelKey = "region"; }
      { name = "tag"; value = "v1.2.3"; }
    ];
    in builtins.length r == 2
      && (builtins.elemAt r 0).value == "{{.metadata.labels.region}}"
      && (builtins.elemAt r 1).value == "v1.2.3")
    "resolveHelmParams should handle mixed labelKey and static value params")

  # ════════════════════════════════════════════════════════════════════
  # Edge-case coverage: helm-values-composition.nix
  # ════════════════════════════════════════════════════════════════════

  # (mkValuesHierarchy requires pkgs — tested indirectly via appset)

  # ════════════════════════════════════════════════════════════════════
  # Cross-module edge cases
  # ════════════════════════════════════════════════════════════════════

  (let
    scheme = naming.mkNamingScheme { tenant = "mte"; environment = "staging"; region = "eu-west-1"; };
    selector = k8s.mkClusterSelector {
      requiredLabel = "api-gateway";
      excludeTenants = [ "deprecated" ];
    };
  in mkTest "cross-default-tenant-cluster"
    (scheme.prefix == "eu-west-1-staging"
      && builtins.length selector.matchExpressions == 2)
    "default tenant naming should compose with cluster selector for cross-module consistency")

  (let
    paths = es.mkSecretPaths {
      basePath = "/platform/secrets";
      keys = [ "db-password" "api-key" ];
      environment = "production";
    };
    secret = es.mkExternalSecret {
      name = "composed-secret";
      secretStoreName = "store";
      secrets = paths;
    };
  in mkTest "cross-secret-paths-to-es"
    (builtins.length secret.spec.data == 2
      && (builtins.elemAt secret.spec.data 0).remoteRef.key == "/platform/secrets/production/db-password"
      && (builtins.elemAt secret.spec.data 1).remoteRef.key == "/platform/secrets/production/api-key")
    "mkSecretPaths output should compose directly with mkExternalSecret secrets param")
]
