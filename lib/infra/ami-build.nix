# Reusable AMI build + test pipeline.
#
# Packer orchestrates everything — SSH keys, instance lifecycle, cleanup.
# ami-forge is called BY Packer as a provisioner tool.
# Nix generates all Packer templates as JSON via builtins.toJSON.
#
# Usage:
#   amiBuild = import "${substrate}/lib/infra/ami-build.nix" { inherit pkgs; };
#
#   packages.build-template = amiBuild.mkBuildTemplate { ... };
#   packages.test-template = amiBuild.mkTestTemplate { ... };
#
#   apps = amiBuild.mkAmiBuildPipeline {
#     forgePackage = inputs.ami-forge.packages.${system}.default;
#     buildTemplate = self.packages.${system}.build-template;
#     testTemplate = self.packages.${system}.test-template;
#     ssmParameter = "/my/ssm/param";
#     amiName = "my-ami";
#   };
{ pkgs }:

let
  # Packer is BSL-licensed (unfree)
  unfreePkgs = import pkgs.path {
    inherit (pkgs) system;
    config.allowUnfreePredicate = pkg: builtins.elem (pkgs.lib.getName pkg) [ "packer" ];
  };

  # Shared NixOS-optimized Packer source defaults
  nixosSourceDefaults = {
    ssh_username = "root";
    ssh_timeout = "10m";
    shutdown_behavior = "terminate";
    temporary_key_pair_type = "ed25519";
    ssh_clear_authorized_keys = true;
    associate_public_ip_address = true;
  };

  requiredPlugins = {
    amazon = {
      version = ">= 1.3.0";
      source = "github.com/hashicorp/amazon";
    };
  };

in rec {

  # ── Build Template ──────────────────────────────────────────
  # Generates build.pkr.json — builds a NixOS AMI from a base image.
  # Packer handles SSH, instance lifecycle, and cleanup.
  mkBuildTemplate = {
    name ? "build-template.pkr.json",
    amiName,
    flakeRef,
    sourceAmiFilter ? { name = "nixos/25.*"; architecture = "x86_64"; },
    sourceAmiOwners ? [ "427812963091" ],
    instanceType ? "c7i.4xlarge",
    volumeSize ? 30,
    region ? "us-east-1",
    iops ? 8000,
    throughput ? 500,
    provisionerScript ? [],
    # Binary to upload to /tmp/ before running provisioner (e.g. kindling)
    uploadBinary ? null,
    extraVariables ? {},
    extraTags ? {},
    extraEnvironmentVars ? [],
  }: let
    template = {
      variable = {
        ami_name = { type = "string"; default = amiName; };
        region = { type = "string"; default = region; };
        instance_type = { type = "string"; default = instanceType; };
        volume_size = { type = "number"; default = volumeSize; };
        github_token = { type = "string"; default = ""; sensitive = true; };
        flake_ref = { type = "string"; default = flakeRef; };
      } // extraVariables;

      packer.required_plugins = requiredPlugins;

      source.amazon-ebs.nixos = nixosSourceDefaults // {
        ami_name = "\${var.ami_name}";
        region = "\${var.region}";
        instance_type = "\${var.instance_type}";
        source_ami_filter = {
          filters = {
            virtualization-type = "hvm";
            root-device-type = "ebs";
          } // sourceAmiFilter;
          owners = sourceAmiOwners;
          most_recent = true;
        };
        launch_block_device_mappings = [{
          device_name = "/dev/xvda";
          volume_size = "\${var.volume_size}";
          volume_type = "gp3";
          inherit iops throughput;
          delete_on_termination = true;
        }];
        force_deregister = true;
        force_delete_snapshot = true;
        tags = {
          Name = "\${var.ami_name}";
          ManagedBy = "ami-forge";
          BuildTimestamp = "{{timestamp}}";
          SourceFlake = "\${var.flake_ref}";
        } // extraTags;
        run_tags = {
          Name = "ami-forge-builder";
          ManagedBy = "ami-forge";
        };
      };

      build = [{
        sources = [ "source.amazon-ebs.nixos" ];
        provisioner =
          # Upload binary to instance if specified (e.g. kindling)
          (pkgs.lib.optional (uploadBinary != null) {
            file = {
              source = uploadBinary;
              destination = "/tmp/${builtins.baseNameOf uploadBinary}";
            };
          })
          ++ [{
            shell = {
              inline = provisionerScript;
              environment_vars = [
                "GITHUB_TOKEN=\${var.github_token}"
                "FLAKE_REF=\${var.flake_ref}"
              ] ++ extraEnvironmentVars;
            };
          }];
        post-processor.manifest = {
          output = "packer-manifest.json";
          strip_path = true;
        };
      }];
    };
  in pkgs.writeText name (builtins.toJSON template);

  # ── Test Template ───────────────────────────────────────────
  # Generates test.pkr.json — boots from built AMI, runs checks.
  # skip_create_ami = true: no snapshot, just validate.
  # Packer handles SSH natively — no manual key management.
  mkTestTemplate = {
    name ? "test-template.pkr.json",
    region ? "us-east-1",
    instanceType ? "t3.medium",
    testScript ? [             # Commands to run on the test instance
      "echo '=== boot check ==='"
      "kindling --version"
      "k3s --version"
      "wg --version"
      "systemctl is-system-running --wait || true"
      "echo '=== boot check passed ==='"
    ],
  }: let
    template = {
      variable = {
        source_ami = { type = "string"; };
        region = { type = "string"; default = region; };
      };

      packer.required_plugins = requiredPlugins;

      source.amazon-ebs.test = nixosSourceDefaults // {
        ami_name = "ami-forge-test-{{timestamp}}";
        region = "\${var.region}";
        instance_type = instanceType;
        source_ami = "\${var.source_ami}";
        skip_create_ami = true;
        run_tags = {
          Name = "ami-forge-test";
          ManagedBy = "ami-forge";
        };
      };

      build = [{
        sources = [ "source.amazon-ebs.test" ];
        provisioner.shell = {
          inline = testScript;
        };
      }];
    };
  in pkgs.writeText name (builtins.toJSON template);

  # ── Pipeline Apps ───────────────────────────────────────────
  # Generates nix run apps that orchestrate: packer build → packer test → promote
  mkAmiBuildPipeline = {
    forgePackage,
    buildTemplate,
    testTemplate,
    ssmParameter,
    amiName,
    region ? "us-east-1",
    awsProfile ? null,
    extraBinaries ? [],
  }: let
    mkApp = name: script: {
      type = "app";
      program = toString (pkgs.writeShellScript name ''
        set -euo pipefail
        export PATH="${pkgs.lib.makeBinPath ([ forgePackage unfreePkgs.packer pkgs.awscli2 ] ++ extraBinaries)}:$PATH"
        ${pkgs.lib.optionalString (awsProfile != null) ''export AWS_PROFILE="${awsProfile}"''}
        BUILD_TPL="${buildTemplate}"
        TEST_TPL="${testTemplate}"
        SSM="${ssmParameter}"
        AMI_NAME="${amiName}"
        REGION="${region}"
        GITHUB_TOKEN="''${GITHUB_TOKEN:-}"
        ${script}
      '');
    };

    buildScript = ''
      packer init "$BUILD_TPL"
      packer build -var "github_token=$GITHUB_TOKEN" "$BUILD_TPL"
      AMI_ID=$(ami-forge manifest-id packer-manifest.json)
    '';

    testScript = ''
      packer init "$TEST_TPL"
      if ! packer build -var "source_ami=$AMI_ID" "$TEST_TPL"; then
        echo "Tests FAILED — deregistering AMI $AMI_ID"
        ami-forge rotate --ami-name "$AMI_NAME" --region "$REGION" || true
        rm -f packer-manifest.json
        exit 1
      fi
    '';

    promoteScript = ''
      ami-forge promote --ami-id "$AMI_ID" --ssm "$SSM" --region "$REGION"
      rm -f packer-manifest.json
      echo "AMI $AMI_ID promoted to $SSM"
    '';

  in {
    # Build only — no integration tests
    ami-build = mkApp "ami-build" ''
      ${buildScript}
      ${promoteScript}
    '';

    # Build + test gate → promote
    ami-build-tested = mkApp "ami-build-tested" ''
      ${buildScript}
      ${testScript}
      ${promoteScript}
    '';

    # Test existing AMI from SSM
    ami-test = mkApp "ami-test" ''
      AMI_ID=$(aws ssm get-parameter --name "$SSM" --region "$REGION" --query 'Parameter.Value' --output text)
      echo "Testing AMI: $AMI_ID"
      packer init "$TEST_TPL"
      packer build -var "source_ami=$AMI_ID" "$TEST_TPL"
    '';

    # Show AMI status
    ami-status = mkApp "ami-status" ''
      ami-forge status --ssm "$SSM" --region "$REGION"
    '';
  };
}
