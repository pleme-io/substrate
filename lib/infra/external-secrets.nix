# External Secrets Builder
#
# Reusable patterns for generating Kubernetes ExternalSecret manifests.
# Supports any secret store backend (Akeyless, AWS Secrets Manager,
# HashiCorp Vault, Azure Key Vault, GCP Secret Manager).
#
# Composes with multi-tenant-naming.nix for environment-scoped paths,
# and k8s-manifest.nix for metadata construction.
#
# Usage:
#   esBuilder = import "${substrate}/lib/infra/external-secrets.nix";
#   manifest = esBuilder.mkExternalSecret {
#     name = "gateway-conf-secret";
#     secretStoreName = "my-cluster-secret-store";
#     secrets = [
#       { secretKey = "admin-access-id";  remotePath = "/platform/prod/access-id"; }
#       { secretKey = "admin-access-key"; remotePath = "/platform/prod/access-key"; }
#     ];
#   };
let
  k8s = import ./k8s-manifest.nix;
in rec {

  # ── ExternalSecret Manifest ────────────────────────────────────────
  # Pure attrset builder — no pkgs needed.
  mkExternalSecret = {
    name,
    namespace ? null,
    secretStoreName,
    secretStoreKind ? "ClusterSecretStore",
    refreshInterval ? "1h0m0s",
    targetName ? name,
    creationPolicy ? "Owner",
    deletionPolicy ? "Retain",
    secrets ? [],
    dataFrom ? [],
    labels ? {},
    annotations ? {},
    targetLabels ? {},
    targetAnnotations ? {},
    secretType ? null,
    template ? null,
  }: let
    # Build target.template carefully — avoid silent overwrites.
    # Priority: explicit template > secretType > targetLabels/Annotations
    targetTemplate =
      if template != null then template
      else if secretType != null then { type = secretType; }
        // (if targetLabels != {} || targetAnnotations != {} then {
          metadata = {}
            // (if targetLabels != {} then { labels = targetLabels; } else {})
            // (if targetAnnotations != {} then { annotations = targetAnnotations; } else {});
        } else {})
      else if targetLabels != {} || targetAnnotations != {} then {
        metadata = {}
          // (if targetLabels != {} then { labels = targetLabels; } else {})
          // (if targetAnnotations != {} then { annotations = targetAnnotations; } else {});
      }
      else null;

    target = {
      name = targetName;
      inherit creationPolicy deletionPolicy;
    } // (if targetTemplate != null then { template = targetTemplate; } else {});

    data = map (s: {
      inherit (s) secretKey;
      remoteRef = { key = s.remotePath; }
        // (if s ? property then { inherit (s) property; } else {})
        // (if s ? version then { inherit (s) version; } else {});
    }) secrets;

  in {
    apiVersion = "external-secrets.io/v1beta1";
    kind = "ExternalSecret";
    metadata = k8s.mkMetadata { inherit name namespace labels annotations; };
    spec = {
      inherit refreshInterval target;
      secretStoreRef = { kind = secretStoreKind; name = secretStoreName; };
    } // (if secrets != [] then { inherit data; } else {})
      // (if dataFrom != [] then { inherit dataFrom; } else {});
  };

  # ── Helm Template String ───────────────────────────────────────────
  mkExternalSecretHelmTemplate = {
    name,
    secretStoreName,
    secretStoreKind ? "ClusterSecretStore",
    refreshInterval ? "1h0m0s",
    secrets ? [],
    condition ? null,
    secretConditions ? {},
  }: let
    secretEntry = s: let
      cond = secretConditions.${s.secretKey} or null;
      base = "    - secretKey: ${s.secretKey}\n      remoteRef:\n        key: ${s.remotePath}";
    in if cond != null
      then "    {{- if ${cond} }}\n${base}\n    {{- end }}"
      else base;
    secretBlock = builtins.concatStringsSep "\n" (map secretEntry secrets);
  in
    (if condition != null then "{{- if ${condition} }}\n" else "")
    + ''
      apiVersion: external-secrets.io/v1beta1
      kind: ExternalSecret
      metadata:
        name: ${name}
        namespace: {{ .Release.Namespace }}
      spec:
        refreshInterval: ${refreshInterval}
        secretStoreRef:
          kind: ${secretStoreKind}
          name: ${secretStoreName}
        target:
          name: ${name}
          creationPolicy: Owner
        data:
      ${secretBlock}''
    + (if condition != null then "\n{{- end }}" else "");

  # ── ClusterSecretStore ─────────────────────────────────────────────
  mkClusterSecretStore = {
    name,
    provider,
    providerConfig ? {},
    labels ? {},
    annotations ? {},
  }: let
    providers = {
      akeyless = { akeyless = {
        akeylessGWApiURL = providerConfig.gatewayUrl or "https://api.akeyless.io";
        authSecretRef = providerConfig.authSecretRef or {};
      }; };
      aws = { aws = {
        service = "SecretsManager";
        region = providerConfig.region or "us-east-1";
      } // (if providerConfig ? role then { role = providerConfig.role; } else {}); };
      vault = { vault = {
        server = providerConfig.server or "https://vault.example.com";
        path = providerConfig.path or "secret";
        version = providerConfig.version or "v2";
      } // (if providerConfig ? auth then { auth = providerConfig.auth; } else {}); };
      azure = { azurekv = {
        vaultUrl = providerConfig.vaultUrl or "";
      } // (if providerConfig ? authSecretRef then { authSecretRef = providerConfig.authSecretRef; } else {}); };
      gcp = { gcpsm = { projectID = providerConfig.projectID or ""; }; };
    };
  in {
    apiVersion = "external-secrets.io/v1beta1";
    kind = "ClusterSecretStore";
    metadata = k8s.mkMetadata { inherit name labels annotations; };
    spec.provider = providers.${provider}
      or (throw "Unknown provider: ${provider}. Supported: akeyless, aws, vault, azure, gcp");
  };

  # ── Secret Path Builder ────────────────────────────────────────────
  # Composes with multi-tenant-naming for path conventions.
  mkSecretPaths = {
    basePath,
    pathTemplate ? "{basePath}/{env}/{key}",
    keys,
    environment ? null,
    tenant ? null,
    service ? null,
  }: let
    resolve = key: builtins.replaceStrings
      [ "{basePath}" "{env}" "{tenant}" "{service}" "{key}" ]
      [ basePath
        (if environment != null then environment else "{{ $.Values.environment }}")
        (if tenant != null then tenant else "{{ $.Values.tenant }}")
        (if service != null then service else "{{ $.Values.service }}")
        key ]
      pathTemplate;
  in map (key: { secretKey = key; remotePath = resolve key; }) keys;
}
