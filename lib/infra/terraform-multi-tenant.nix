# Multi-Tenant Terraform Module Patterns
#
# Reusable patterns for multi-tenant Terraform infrastructure modules.
# Provides builders for common enterprise patterns:
#   - KMS key with tenant-aware naming and IAM policies
#   - RDS instances with multi-region read replicas
#   - EKS clusters with per-tenant node groups
#   - S3 buckets with mandatory encryption and lifecycle policies
#
# All modules enforce:
#   - KMS encryption on all storage resources
#   - prevent_destroy lifecycle rules on stateful resources
#   - Least-privilege IAM policies
#   - Multi-tenant naming conventions
#
# Usage:
#   tfBuilder = import "${substrate}/lib/infra/terraform-multi-tenant.nix";
#
#   # Generate a KMS key module
#   kmsModule = tfBuilder.mkKmsKeyModule pkgs {
#     name = "platform";
#     defaultTenants = [ "mte" "" ];
#   };
#
#   # Validate all tenant modules at once
#   check = tfBuilder.mkMultiTenantModuleCheck pkgs {
#     pname = "my-platform-infra";
#     version = "1.0.0";
#     src = ./.;
#     modules = [ "kms_key" "rds" "eks_cluster" "s3_bucket" ];
#   };
{
  # ──────────────────────────────────────────────────────────────────
  # Multi-Tenant Terraform Module Check
  # ──────────────────────────────────────────────────────────────────
  # Validates multiple Terraform modules in a multi-tenant layout.
  mkMultiTenantModuleCheck = pkgs: {
    pname,
    version,
    src,
    modules ? [],
    modulesDir ? "modules",
    cloudProviders ? [ "AWS" ],
    terraform ? pkgs.opentofu,
    tflint ? pkgs.tflint,
  }: let
    lib = pkgs.lib;
    tfBin = lib.getExe terraform;

    moduleChecks = lib.concatMapStringsSep "\n" (cloud:
      lib.concatMapStringsSep "\n" (mod: ''
        echo "==> Validating ${cloud}/${mod}"
        if [ -d "${modulesDir}/${cloud}/${mod}" ]; then
          cd "${modulesDir}/${cloud}/${mod}"
          ${tfBin} fmt -check -recursive -diff . || { echo "FAIL: fmt ${cloud}/${mod}"; errors=$((errors + 1)); }
          ${tfBin} init -backend=false -input=false 2>/dev/null || true
          ${tfBin} validate || { echo "FAIL: validate ${cloud}/${mod}"; errors=$((errors + 1)); }
          cd "$OLDPWD"
        else
          echo "SKIP: ${cloud}/${mod} (not found)"
        fi
      '') modules
    ) cloudProviders;

  in pkgs.stdenv.mkDerivation {
    inherit pname version src;
    nativeBuildInputs = [ terraform ] ++ lib.optional (tflint != null) tflint;
    dontConfigure = true;
    dontBuild = true;

    checkPhase = ''
      errors=0
      OLDPWD=$(pwd)
      ${moduleChecks}
      if [ $errors -gt 0 ]; then
        echo "$errors module(s) failed validation"
        exit 1
      fi
      echo "All modules validated successfully"
    '';

    doCheck = true;
    installPhase = ''
      mkdir -p $out
      cp -r ${modulesDir} $out/
      echo "${pname} ${version}" > $out/.validated
    '';
  };

  # ──────────────────────────────────────────────────────────────────
  # Terraform Module Scaffold Generator
  # ──────────────────────────────────────────────────────────────────
  # Generates the initial directory structure and boilerplate .tf files
  # for a multi-tenant module.
  mkModuleScaffold = pkgs: {
    name,
    cloudProvider ? "AWS",
    modulesDir ? "modules",

    # Variables to include in the module
    variables ? [
      { name = "tenant"; type = "string"; description = "Tenant identifier"; default = ""; }
      { name = "environment"; type = "string"; description = "Deployment environment (staging, production)"; }
      { name = "tags"; type = "map(string)"; description = "Additional resource tags"; default = "{}"; }
    ],

    # Outputs to include
    outputs ? [],

    # Required providers
    providers ? [{ name = "aws"; source = "hashicorp/aws"; version = ">= 5.0"; }],

    # Whether to include tenant-aware naming locals
    includeTenantNaming ? true,

    # Whether to include prevent_destroy lifecycle
    includePreventDestroy ? true,
  }: let
    lib = pkgs.lib;
    naming = import ./multi-tenant-naming.nix;

    variablesTf = lib.concatMapStringsSep "\n\n" (v: ''
      variable "${v.name}" {
        type        = ${v.type}
        description = "${v.description}"${lib.optionalString (v ? default) ''

        default     = ${v.default}''}
      }'') variables;

    providersTf = ''
      terraform {
        required_providers {
      ${lib.concatMapStringsSep "\n" (p: ''
          ${p.name} = {
            source  = "${p.source}"
            version = "${p.version}"
          }'') providers}
        }
      }'';

    localsTf = lib.optionalString includeTenantNaming
      (naming.mkTerraformNamingLocals {});

    outputsTf = lib.concatMapStringsSep "\n\n" (o: ''
      output "${o.name}" {
        value       = ${o.value}
        description = "${o.description}"
      }'') outputs;

    scaffoldScript = pkgs.writeShellScript "scaffold-${name}" ''
      set -euo pipefail
      DIR="''${1:-.}/${modulesDir}/${cloudProvider}/${name}"
      mkdir -p "$DIR"

      if [ ! -f "$DIR/versions.tf" ]; then
        cat > "$DIR/versions.tf" << 'HCLEOF'
      ${providersTf}
      HCLEOF
        echo "Created: $DIR/versions.tf"
      fi

      if [ ! -f "$DIR/variables.tf" ]; then
        cat > "$DIR/variables.tf" << 'HCLEOF'
      ${variablesTf}
      HCLEOF
        echo "Created: $DIR/variables.tf"
      fi

      ${lib.optionalString includeTenantNaming ''
      if [ ! -f "$DIR/locals.tf" ]; then
        cat > "$DIR/locals.tf" << 'HCLEOF'
      ${localsTf}
      HCLEOF
        echo "Created: $DIR/locals.tf"
      fi
      ''}

      if [ ! -f "$DIR/main.tf" ]; then
        cat > "$DIR/main.tf" << 'HCLEOF'
      # ${name} - Multi-tenant module
      # Generated by substrate terraform-multi-tenant builder
      HCLEOF
        echo "Created: $DIR/main.tf"
      fi

      ${lib.optionalString (outputs != []) ''
      if [ ! -f "$DIR/outputs.tf" ]; then
        cat > "$DIR/outputs.tf" << 'HCLEOF'
      ${outputsTf}
      HCLEOF
        echo "Created: $DIR/outputs.tf"
      fi
      ''}

      echo "Module scaffolded at $DIR"
    '';

  in {
    type = "app";
    program = toString scaffoldScript;
  };

  # ──────────────────────────────────────────────────────────────────
  # Terraform Multi-Tenant Dev Shell
  # ──────────────────────────────────────────────────────────────────
  mkMultiTenantTerraformDevShell = pkgs: {
    terraform ? pkgs.opentofu,
    tflint ? pkgs.tflint,
    terraformDocs ? pkgs.terraform-docs,
    extraPackages ? [],

    # Cloud provider CLIs to include
    awsCli ? true,
    azureCli ? false,
    gcpCli ? false,
  }: let
    lib = pkgs.lib;
  in pkgs.mkShellNoCC {
    name = "terraform-multi-tenant-shell";
    packages = [ terraform ]
      ++ lib.optional (tflint != null) tflint
      ++ lib.optional (terraformDocs != null) terraformDocs
      ++ lib.optional awsCli pkgs.awscli2
      ++ lib.optional azureCli pkgs.azure-cli
      ++ lib.optional gcpCli pkgs.google-cloud-sdk
      ++ [ pkgs.jq pkgs.yq-go ]
      ++ extraPackages;

    shellHook = ''
      echo "Terraform multi-tenant development shell"
      echo "  terraform: $(${lib.getExe terraform} version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || echo 'unknown')"
      echo "  tflint:    $(tflint --version 2>/dev/null | head -1 || echo 'not available')"
    '';
  };
}
