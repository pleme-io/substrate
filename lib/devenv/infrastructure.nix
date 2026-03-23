# Devenv module for infrastructure development.
#
# Provides: Terraform/OpenTofu, TFLint, terraform-docs, cloud CLIs,
# Python for automation scripts, and git-hooks for fmt validation.
#
# Usage (in a devenv shell definition):
#   imports = [ "${substrate}/lib/devenv/infrastructure.nix" ];
{ pkgs, lib, config, ... }: {

  # Import the shared base for K8s + YAML tools
  imports = [ ./infrastructure-base.nix ];

  options.infrastructure = {
    cloudProviders = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [ "aws" "azure" "gcp" ]);
      default = [ "aws" ];
      description = "Cloud provider CLIs to include";
    };
    terraform = lib.mkOption {
      type = lib.types.package;
      default = pkgs.opentofu;
      description = "Terraform/OpenTofu package";
    };
    pythonAutomation = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Include Python environment for automation scripts";
    };
  };

  config = let
    cfg = config.infrastructure;
    cloudPkgs = lib.concatLists [
      (lib.optional (builtins.elem "aws" cfg.cloudProviders) pkgs.awscli2)
      (lib.optional (builtins.elem "azure" cfg.cloudProviders) pkgs.azure-cli)
      (lib.optional (builtins.elem "gcp" cfg.cloudProviders) pkgs.google-cloud-sdk)
    ];
    pythonPkgs = lib.optional cfg.pythonAutomation (pkgs.python3.withPackages (ps: with ps; [
      boto3 pyyaml rich click jsonschema
    ]));
  in {
    packages = [
      cfg.terraform
      pkgs.tflint
      pkgs.terraform-docs
      pkgs.gnumake
    ] ++ cloudPkgs ++ pythonPkgs;

    env.TF_PLUGIN_CACHE_DIR = "$HOME/.terraform.d/plugin-cache";

    scripts = {
      tf-fmt = {
        exec = "${lib.getExe cfg.terraform} fmt -recursive .";
        description = "Format all Terraform files";
      };
      tf-validate-all = {
        exec = ''
          errors=0
          for mod in $(find . -name '*.tf' -exec dirname {} \; | sort -u); do
            echo "==> $mod"
            (cd "$mod" && ${lib.getExe cfg.terraform} init -backend=false -input=false 2>/dev/null && ${lib.getExe cfg.terraform} validate) || {
              echo "FAIL: $mod"; errors=$((errors + 1))
            }
          done
          [ $errors -gt 0 ] && { echo "$errors module(s) failed"; exit 1; }
          echo "All modules valid"
        '';
        description = "Validate all Terraform modules";
      };
      tf-docs = {
        exec = ''
          for mod in $(find . -name '*.tf' -exec dirname {} \; | sort -u); do
            [ -f "$mod/main.tf" ] && { echo "==> $mod"; ${pkgs.terraform-docs}/bin/terraform-docs markdown "$mod" > "$mod/README.md" || true; }
          done
          echo "Documentation generated"
        '';
        description = "Generate README.md for all Terraform modules";
      };
    };

    git-hooks.hooks.terraform-format = {
      enable = lib.mkDefault true;
      entry = "${lib.getExe cfg.terraform} fmt -check -diff";
      files = "\\.tf$";
      pass_filenames = false;
    };
  };
}
