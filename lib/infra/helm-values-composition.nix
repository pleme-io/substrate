# Helm Values Composition Hierarchy Builder
#
# Reusable pattern for multi-tenant, multi-environment Helm value file
# management. Generates and validates the directory layout and provides
# apps for scaffolding, validating, and diffing value files.
#
# Extracted from production deployments with 5+ tenants × 3 environments
# × 3 cloud providers × N regions.
#
# Directory convention:
#   environments/
#   ├── global/
#   │   ├── staging/
#   │   │   └── values.yaml          # tier 1: global per-environment
#   │   └── production/
#   │       └── values.yaml
#   ├── {tenant}/
#   │   ├── staging/
#   │   │   ├── {cloud}/
#   │   │   │   ├── common-values.yaml     # tier 2: tenant + env + cloud
#   │   │   │   └── {region}/
#   │   │   │       └── values.yaml        # tier 3: full specificity
#   │   │   └── helm_values_files/
#   │   │       └── {region}/
#   │   │           └── {service}-values.yaml  # tier 4: per-service overrides
#   │   └── production/
#   │       └── ...
#
# Usage:
#   valuesBuilder = import "${substrate}/lib/infra/helm-values-composition.nix";
#   suite = valuesBuilder.mkValuesHierarchy pkgs {
#     name = "my-platform";
#     src = ./environments;
#     tenants = [ "global" "customer-a" "customer-b" ];
#     environments = [ "staging" "production" ];
#     cloudProviders = [ "AWS" "AZR" "GCP" ];
#     regions = {
#       AWS = [ "us-east-1" "us-east-2" "eu-west-1" ];
#       AZR = [ "eastus2" "westeurope" ];
#       GCP = [ "us-central1" ];
#     };
#     services = [ "api-gateway" "config" "monitoring" ];
#   };
{
  # ──────────────────────────────────────────────────────────────────
  # Values Hierarchy Definition
  # ──────────────────────────────────────────────────────────────────
  # Returns resolution order for ArgoCD valueFiles, plus validation
  # and scaffold apps.
  mkValuesHierarchy = pkgs: {
    name,
    src ? null,
    tenants ? [ "default" ],
    environments ? [ "staging" "production" ],
    cloudProviders ? [ "AWS" ],
    regions ? { AWS = [ "us-east-1" ]; },
    services ? [],

    # Template for value file paths at each tier.
    # Use these variables: {tenant}, {env}, {cloud}, {region}, {service}
    tiers ? [
      "environments/global/{env}/values.yaml"
      "environments/{tenant}/{env}/{cloud}/common-values.yaml"
      "environments/{tenant}/{env}/{cloud}/{region}/values.yaml"
    ],

    # Per-service tier (appended per service)
    serviceTier ? "environments/{tenant}/{env}/{cloud}/helm_values_files/{region}/{service}-values.yaml",

    # Base path prefix for ArgoCD valueFiles (relative from chart to repo root)
    argocdPrefix ? "../../../../",
  }: let
    lib = pkgs.lib;

    # Resolve a tier template with concrete values
    resolveTier = template: { tenant, env, cloud, region, service ? null }:
      builtins.replaceStrings
        [ "{tenant}" "{env}" "{cloud}" "{region}" "{service}" ]
        [ tenant env cloud region (if service != null then service else "") ]
        template;

    # Generate ArgoCD GoTemplate value file paths
    # These use cluster label interpolation instead of concrete values
    mkArgocdValuePaths = { tenantExpr ? "{{tenant}}", envExpr ? "{{.metadata.labels.environment}}", cloudExpr ? "{{.metadata.labels.cloudProvider}}", regionExpr ? "{{.metadata.labels.region}}" }:
      map (tier:
        argocdPrefix + (builtins.replaceStrings
          [ "{tenant}" "{env}" "{cloud}" "{region}" ]
          [ tenantExpr envExpr cloudExpr regionExpr ]
          tier)
      ) tiers;

    # All combinations for validation
    allCombinations = lib.concatMap (tenant:
      lib.concatMap (env:
        lib.concatMap (cloud:
          map (region: { inherit tenant env cloud region; })
            (regions.${cloud} or [])
        ) cloudProviders
      ) environments
    ) tenants;

    # Validate that all expected directories/files exist
    validateScript = pkgs.writeShellScript "validate-${name}-values" ''
      set -euo pipefail
      SRC="''${1:-.}"
      errors=0
      warnings=0

      ${lib.concatMapStringsSep "\n" (combo:
        lib.concatMapStringsSep "\n" (tier: let
          path = resolveTier tier combo;
        in ''
          if [ ! -f "$SRC/${path}" ]; then
            echo "MISSING: ${path}"
            errors=$((errors + 1))
          fi
        '') tiers
      ) allCombinations}

      ${lib.concatMapStringsSep "\n" (combo:
        lib.concatMapStringsSep "\n" (service: let
          path = resolveTier serviceTier (combo // { inherit service; });
        in ''
          if [ ! -f "$SRC/${path}" ]; then
            echo "WARNING: ${path} (service-specific)"
            warnings=$((warnings + 1))
          fi
        '') services
      ) allCombinations}

      echo ""
      echo "Validation complete: $errors errors, $warnings warnings"
      if [ $errors -gt 0 ]; then exit 1; fi
    '';

    # Scaffold missing directories and empty value files
    scaffoldScript = pkgs.writeShellScript "scaffold-${name}-values" ''
      set -euo pipefail
      SRC="''${1:-.}"
      created=0

      ${lib.concatMapStringsSep "\n" (combo:
        lib.concatMapStringsSep "\n" (tier: let
          path = resolveTier tier combo;
          dir = builtins.dirOf path;
        in ''
          mkdir -p "$SRC/${dir}"
          if [ ! -f "$SRC/${path}" ]; then
            echo "# ${name} values: ${combo.tenant}/${combo.env}/${combo.cloud}/${combo.region}" > "$SRC/${path}"
            echo "---" >> "$SRC/${path}"
            echo "Created: ${path}"
            created=$((created + 1))
          fi
        '') tiers
      ) allCombinations}

      ${lib.concatMapStringsSep "\n" (combo:
        lib.concatMapStringsSep "\n" (service: let
          path = resolveTier serviceTier (combo // { inherit service; });
          dir = builtins.dirOf path;
        in ''
          mkdir -p "$SRC/${dir}"
          if [ ! -f "$SRC/${path}" ]; then
            echo "# ${name} ${service} values: ${combo.tenant}/${combo.env}/${combo.cloud}/${combo.region}" > "$SRC/${path}"
            echo "---" >> "$SRC/${path}"
            echo "Created: ${path}"
            created=$((created + 1))
          fi
        '') services
      ) allCombinations}

      echo "Scaffolded $created new value files."
    '';

    # Diff values between two environments
    diffScript = pkgs.writeShellApplication {
      name = "diff-${name}-values";
      runtimeInputs = with pkgs; [ diffutils yq-go ];
      text = ''
        TENANT="''${1:?Usage: diff <tenant> <env1> <env2> [cloud] [region]}"
        ENV1="''${2:?}"
        ENV2="''${3:?}"
        CLOUD="''${4:-AWS}"
        REGION="''${5:-}"
        SRC="''${6:-.}"

        if [ -n "$REGION" ]; then
          DIR1="$SRC/environments/$TENANT/$ENV1/$CLOUD/$REGION"
          DIR2="$SRC/environments/$TENANT/$ENV2/$CLOUD/$REGION"
        else
          DIR1="$SRC/environments/$TENANT/$ENV1/$CLOUD"
          DIR2="$SRC/environments/$TENANT/$ENV2/$CLOUD"
        fi

        echo "Comparing: $DIR1 ↔ $DIR2"
        echo "─────────────────────────────────────────────"

        diff -rq "$DIR1" "$DIR2" 2>/dev/null || true
        echo ""

        for f in "$DIR1"/*.yaml "$DIR1"/*.yml; do
          [ -f "$f" ] || continue
          base=$(basename "$f")
          if [ -f "$DIR2/$base" ]; then
            echo "━━━ $base ━━━"
            diff -u "$f" "$DIR2/$base" || true
            echo ""
          fi
        done
      '';
    };

  in {
    # ArgoCD valueFiles paths using GoTemplate expressions
    argocdValuePaths = mkArgocdValuePaths {};

    # ArgoCD valueFiles with custom tenant expression
    mkArgocdValuePaths = mkArgocdValuePaths;

    # All expected file paths (for external validation)
    expectedPaths = lib.concatMap (combo:
      (map (tier: resolveTier tier combo) tiers)
      ++ (map (service: resolveTier serviceTier (combo // { inherit service; })) services)
    ) allCombinations;

    # Nix apps
    validate = {
      type = "app";
      program = toString validateScript;
    };

    scaffold = {
      type = "app";
      program = toString scaffoldScript;
    };

    diff = {
      type = "app";
      program = "${diffScript}/bin/diff-${name}-values";
    };

    # Resolution metadata (for consumers that need to compose their own paths)
    meta = {
      inherit tenants environments cloudProviders regions services tiers serviceTier;
      combinationCount = builtins.length allCombinations;
    };
  };
}
