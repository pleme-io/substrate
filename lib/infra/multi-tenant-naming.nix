# Multi-Tenant Resource Naming Conventions
#
# Pure functions (no pkgs dependency) for tenant-aware resource naming.
# Handles conditional tenant-prefixed naming common in enterprise
# deployments where a "default" tenant uses shorter names.
#
# Naming convention:
#   Default tenant:  {region}-{environment}-{resource}
#   Named tenant:    {tenant}-{environment}-{region}-{resource}
#
# Usage:
#   naming = import "${substrate}/lib/infra/multi-tenant-naming.nix";
#
#   name = naming.mkResourceName {
#     tenant = "customer-a"; environment = "production";
#     region = "us-east-2"; resource = "eks";
#   };
#   # → "customer-a-production-us-east-2-eks"
#
#   name = naming.mkResourceName {
#     tenant = "mte"; environment = "production";
#     region = "us-east-2"; resource = "eks";
#   };
#   # → "us-east-2-production-eks"
rec {
  # ── Core: is this tenant a "default" (short-name) tenant? ──────────
  isDefaultTenant = {
    tenant,
    defaultTenants ? [ "default" "mte" "" ],
  }: builtins.elem tenant defaultTenants;

  # ── Resource Name Builder ──────────────────────────────────────────
  mkResourceName = {
    tenant,
    environment,
    region ? null,
    resource ? null,
    defaultTenants ? [ "default" "mte" "" ],
    separator ? "-",
    maxLength ? 0,
  }: let
    isDefault = isDefaultTenant { inherit tenant defaultTenants; };
    parts =
      if isDefault
      then builtins.filter (s: s != "" && s != null) [ region environment resource ]
      else builtins.filter (s: s != "" && s != null) [ tenant environment region resource ];
    joined = builtins.concatStringsSep separator parts;
  in
    if maxLength > 0 && builtins.stringLength joined > maxLength
    then builtins.substring 0 maxLength joined
    else joined;

  # ── Full Naming Scheme ─────────────────────────────────────────────
  # Returns an attrset of named resource generators.
  mkNamingScheme = {
    tenant,
    environment,
    region ? null,
    cloudProvider ? null,
    defaultTenants ? [ "default" "mte" "" ],
    separator ? "-",
  }: let
    base = { inherit tenant environment region defaultTenants separator; };
  in {
    prefix    = mkResourceName base;
    resource  = r: mkResourceName (base // { resource = r; });
    namespace = mkResourceName (base // { resource = "ns"; });
    helmRelease = svc: mkResourceName (base // { resource = svc; });

    eksCluster  = mkResourceName (base // { resource = "eks"; });
    rdsInstance = svc: mkResourceName (base // { resource = "${svc}-rds"; });
    s3Bucket    = purpose: mkResourceName (base // { resource = "${purpose}-s3"; });
    kmsKey      = purpose: mkResourceName (base // { resource = "${purpose}-kms"; });

    labels = { inherit tenant environment; }
      // (if region != null then { inherit region; } else {})
      // (if cloudProvider != null then { inherit cloudProvider; } else {});
  };

  # ── GoTemplate Expressions ─────────────────────────────────────────
  # Build ArgoCD GoTemplate tenant expressions for ApplicationSets.

  # Simple tenant expression with optional mappings.
  # tenantMappings: { mte = "akeyless_global"; } →
  #   {{ if eq .metadata.labels.tenant "mte" }}akeyless_global{{ else }}{{.metadata.labels.tenant}}{{ end }}
  mkTenantExpr = { tenantMappings ? {} }:
    if tenantMappings == {} then "{{.metadata.labels.tenant}}"
    else let
      entries = builtins.attrNames tenantMappings;
      build = remaining:
        if remaining == [] then "{{.metadata.labels.tenant}}"
        else let
          k = builtins.head remaining;
          v = tenantMappings.${k};
        in ''{{ if eq .metadata.labels.tenant "${k}" }}${v}{{ else }}'' + (build (builtins.tail remaining)) + "{{ end }}";
    in build entries;

  # Tenant path expression with fallback label.
  # If tenantPathLabel is set, uses `{{ or (index .metadata.labels "tenant_path") (index .metadata.labels "tenant") }}`
  # Otherwise delegates to mkTenantExpr.
  mkTenantPathExpr = { tenantPathLabel ? null, tenantMappings ? {} }:
    if tenantPathLabel != null
    then ''{{ or (index .metadata.labels "${tenantPathLabel}") (index .metadata.labels "tenant") }}''
    else mkTenantExpr { inherit tenantMappings; };

  # ── Terraform HCL Generators ───────────────────────────────────────

  mkTerraformNamingLocals = {
    tenantVar ? "var.tenant",
    environmentVar ? "var.environment",
    regionVar ? "data.aws_region.current.name",
    defaultTenants ? [ "mte" "" ],
    prefixLocal ? "resource_prefix",
    tenantEnvLocal ? "tenant_env",
  }: let
    defaultList = builtins.concatStringsSep ", " (map (t: ''"${t}"'') defaultTenants);
  in ''
    locals {
      ${prefixLocal} = contains([${defaultList}], ${tenantVar}) ? "${"\${"}${regionVar}}-${"\${"}${environmentVar}}" : "${"\${"}${tenantVar}}-${"\${"}${environmentVar}}-${"\${"}${regionVar}}"
      ${tenantEnvLocal} = contains([${defaultList}], ${tenantVar}) ? ${environmentVar} : "${"\${"}${tenantVar}}-${"\${"}${environmentVar}}"
    }
  '';
}
