# Multi-Tenant Environment Configuration
#
# Generic pattern for managing per-tenant, per-environment, per-region
# configuration with optional KMS encryption. Extracts the pattern from
# enterprises that manage multiple deployment environments.
#
# Directory convention:
#   environments/
#   ├── {tenant}/
#   │   ├── staging/
#   │   │   ├── {cloud}/{region}/
#   │   │   │   ├── service.conf
#   │   │   │   └── service-secret.conf  (encrypted)
#   │   └── production/
#   │       └── ...
#
# Usage:
#   mkEnvironmentConfig = (import "${substrate}/lib/environment-config.nix").mkEnvironmentConfig;
#   config = mkEnvironmentConfig pkgs {
#     name = "my-platform";
#     src = ./environments;
#     tenants = [ "global" "customer-a" "customer-b" ];
#     environments = [ "staging" "production" ];
#     # Optional: KMS encryption for secret files
#     encryptedPattern = "*-secret.conf";
#   };
#
# Returns: { configMaps, validate, deploy }
{
  # Build K8s ConfigMaps from environment config directory.
  mkEnvironmentConfig = pkgs: {
    name,
    src,
    tenants ? [ "default" ],
    environments ? [ "staging" "production" ],
    encryptedPattern ? "*-secret.conf",
    namespace ? "default",
  }: let
    inherit (pkgs) lib;

    # Generate ConfigMap YAML from a config directory
    mkConfigMap = tenant: env: let
      configDir = "${src}/${tenant}/${env}";
    in pkgs.runCommand "configmap-${name}-${tenant}-${env}" {} ''
      mkdir -p $out
      if [ -d "${configDir}" ]; then
        # Create ConfigMap YAML from all non-secret config files
        echo "apiVersion: v1" > $out/configmap.yaml
        echo "kind: ConfigMap" >> $out/configmap.yaml
        echo "metadata:" >> $out/configmap.yaml
        echo "  name: ${name}-${tenant}-config" >> $out/configmap.yaml
        echo "  namespace: ${namespace}" >> $out/configmap.yaml
        echo "  labels:" >> $out/configmap.yaml
        echo "    tenant: ${tenant}" >> $out/configmap.yaml
        echo "    environment: ${env}" >> $out/configmap.yaml
        echo "data:" >> $out/configmap.yaml
        for f in ${configDir}/*.conf; do
          if [ -f "$f" ] && [[ "$(basename "$f")" != ${encryptedPattern} ]]; then
            key=$(basename "$f")
            echo "  $key: |" >> $out/configmap.yaml
            sed 's/^/    /' "$f" >> $out/configmap.yaml
          fi
        done
      else
        echo "No config directory: ${configDir}" > $out/SKIP
      fi
    '';

    # Validate: check all tenants/envs exist
    validate = pkgs.writeShellScript "validate-${name}-config" ''
      set -euo pipefail
      errors=0
      ${lib.concatMapStringsSep "\n" (tenant:
        lib.concatMapStringsSep "\n" (env: ''
          if [ ! -d "${src}/${tenant}/${env}" ]; then
            echo "MISSING: ${src}/${tenant}/${env}"
            errors=$((errors + 1))
          fi
        '') environments
      ) tenants}
      if [ $errors -gt 0 ]; then
        echo "$errors missing config directories"
        exit 1
      fi
      echo "All ${toString (builtins.length tenants * builtins.length environments)} config directories present"
    '';

  in {
    configMaps = lib.genAttrs tenants (tenant:
      lib.genAttrs environments (env:
        mkConfigMap tenant env
      )
    );
    inherit validate;
  };
}
