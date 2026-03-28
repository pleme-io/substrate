# Reusable AMI build + test pipeline apps.
#
# Generates nix run apps that orchestrate ami-forge + Packer for building,
# testing, and promoting AMIs. Also provides mkPackerTemplate to generate
# Packer JSON templates from Nix attrsets.
#
# Usage:
#   amiBuild = import "${substrate}/lib/infra/ami-build.nix" { inherit pkgs; };
#
#   # Generate all pipeline apps (7 apps)
#   apps = amiBuild.mkAmiBuildApps {
#     forgePackage = inputs.ami-forge.packages.${system}.default;
#     packerTemplate = self.packages.${system}.packer-template;
#     ssmParameter = "/my/ssm/parameter";
#   };
#
#   # Generate Packer template from Nix
#   packages.packer-template = amiBuild.mkPackerTemplate {
#     amiName = "my-ami";
#     flakeRef = "github:my-org/my-profiles#builder";
#     provisionerScript = [ "nixos-rebuild switch --flake $FLAKE_REF" "my-tool validate" ];
#   };
{ pkgs }:

let
  # Internal: create a nix run app with ami-forge + packer + awscli2 on PATH
  mkApp = { forgePackage, extraBinaries ? [], envVars ? {} }:
    name: script: {
      type = "app";
      program = toString (pkgs.writeShellScript name ''
        set -euo pipefail
        export PATH="${pkgs.lib.makeBinPath ([ forgePackage pkgs.packer pkgs.awscli2 ] ++ extraBinaries)}:$PATH"
        ${builtins.concatStringsSep "\n" (
          pkgs.lib.mapAttrsToList (k: v: ''export ${k}="${v}"'') envVars
        )}
        ${script}
      '');
    };

in rec {

  # Generate all AMI pipeline apps.
  #
  # Returns an attrset of 7 apps suitable for flake `apps.${system}` output:
  #   ami-build           — Packer build, no integration tests
  #   ami-build-tested    — Packer build + boot test gate
  #   ami-build-vpn-tested — Packer build + VPN connectivity test gate
  #   ami-build-full      — Packer build + boot test + VPN test gates
  #   ami-boot-test       — Boot-test an existing AMI (from SSM or arg)
  #   ami-vpn-test        — VPN-test an existing AMI (from SSM or arg)
  #   ami-status          — Show current AMI from SSM
  mkAmiBuildApps = {
    forgePackage,
    packerTemplate,
    ssmParameter,
    region ? "us-east-1",
    sshUser ? "root",
    testInstanceType ? "t3.medium",
    testSubnet ? null,
    extraBinaries ? [],
    extraVars ? [],
  }: let
    app = mkApp {
      inherit forgePackage extraBinaries;
      envVars = {
        TEMPLATE = "${packerTemplate}";
        SSM = ssmParameter;
        REGION = region;
      };
    };

    varFlags = builtins.concatStringsSep " " (
      map (v: "--var '${v}'") extraVars
    );

    testFlags = builtins.concatStringsSep " " ([
      "--test-ssh-user ${sshUser}"
      "--test-instance-type ${testInstanceType}"
    ] ++ pkgs.lib.optional (testSubnet != null) "--test-subnet ${testSubnet}");

  in {
    ami-build = app "ami-build" ''
      ami-forge packer \
        --template "$TEMPLATE" --ssm "$SSM" --region "$REGION" \
        --var "github_token=''${GITHUB_TOKEN:-}" ${varFlags}
    '';

    ami-build-tested = app "ami-build-tested" ''
      ami-forge packer \
        --template "$TEMPLATE" --ssm "$SSM" --region "$REGION" \
        --var "github_token=''${GITHUB_TOKEN:-}" ${varFlags} \
        --boot-test ${testFlags}
    '';

    ami-build-vpn-tested = app "ami-build-vpn-tested" ''
      ami-forge packer \
        --template "$TEMPLATE" --ssm "$SSM" --region "$REGION" \
        --var "github_token=''${GITHUB_TOKEN:-}" ${varFlags} \
        --vpn-test ${testFlags}
    '';

    ami-build-full = app "ami-build-full" ''
      ami-forge packer \
        --template "$TEMPLATE" --ssm "$SSM" --region "$REGION" \
        --var "github_token=''${GITHUB_TOKEN:-}" ${varFlags} \
        --boot-test --vpn-test ${testFlags}
    '';

    ami-boot-test = app "ami-boot-test" ''
      AMI_ID="''${1:-$(aws ssm get-parameter --name "$SSM" --region "$REGION" \
        --query 'Parameter.Value' --output text)}"
      echo "Boot testing AMI: $AMI_ID"
      ami-forge boot-test --ami-id "$AMI_ID" --region "$REGION" \
        --ssh-user ${sshUser} --instance-type ${testInstanceType}
    '';

    ami-vpn-test = app "ami-vpn-test" ''
      AMI_ID="''${1:-$(aws ssm get-parameter --name "$SSM" --region "$REGION" \
        --query 'Parameter.Value' --output text)}"
      echo "VPN testing AMI: $AMI_ID"
      ami-forge vpn-test --ami-id "$AMI_ID" --region "$REGION" \
        --ssh-user ${sshUser} --instance-type ${testInstanceType}
    '';

    ami-status = app "ami-status" ''
      ami-forge status --ssm "$SSM" --region "$REGION"
    '';
  };

  # Generate a Packer JSON template from Nix attrsets.
  #
  # Produces a NixOS-optimized Packer template with:
  #   - gp3 EBS with 8K IOPS + 500 MB/s throughput
  #   - force_deregister for idempotent builds
  #   - Manifest post-processor for ami-forge consumption
  #   - Configurable provisioner script
  mkPackerTemplate = {
    name ? "packer-template.pkr.json",
    amiName,
    flakeRef,
    sourceAmiFilter ? { name = "nixos/25.*"; architecture = "x86_64"; },
    sourceAmiOwners ? [ "427812963091" ],
    instanceType ? "c7i.4xlarge",
    volumeSize ? 30,
    region ? "us-east-1",
    sshUsername ? "root",
    sshTimeout ? "10m",
    iops ? 8000,
    throughput ? 500,
    provisionerScript ? [],
    extraVariables ? {},
    extraTags ? {},
    extraRunTags ? {},
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

      packer.required_plugins.amazon = {
        version = ">= 1.3.0";
        source = "github.com/hashicorp/amazon";
      };

      source.amazon-ebs.nixos = {
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
        ssh_username = sshUsername;
        ssh_timeout = sshTimeout;
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
          Name = "ami-forge-packer-builder";
          ManagedBy = "ami-forge";
        } // extraRunTags;
      };

      build = [{
        sources = [ "source.amazon-ebs.nixos" ];
        provisioner.shell = {
          inline = provisionerScript;
          environment_vars = [
            "GITHUB_TOKEN=\${var.github_token}"
            "FLAKE_REF=\${var.flake_ref}"
          ] ++ extraEnvironmentVars;
        };
        post-processor.manifest = {
          output = "packer-manifest.json";
          strip_path = true;
        };
      }];
    };
  in pkgs.writeText name (builtins.toJSON template);
}
