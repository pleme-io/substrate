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
]
