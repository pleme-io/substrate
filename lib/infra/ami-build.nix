# Reusable AMI build + test pipeline apps.
#
# Generates nix run apps that use ami-forge's JSON-driven pipeline subcommand.
# Nix generates the config, Rust executes it — zero shell logic in between.
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
  # Internal: create a pipeline config JSON as a Nix derivation
  mkPipelineConfig = {
    packerTemplate,
    ssmParameter,
    region,
    awsProfile,
    sshUser,
    testInstanceType,
    testSubnet,
    packerVars,
    bootTest,
    vpnTest,
  }: pkgs.writeText "pipeline.json" (builtins.toJSON ({
    template = "${packerTemplate}";
    ssm_parameter = ssmParameter;
    inherit region;
    packer_vars = { github_token = ""; } // packerVars;
    test_subnet = testSubnet;
    tests = {
      boot = {
        enabled = bootTest;
        ssh_user = sshUser;
        instance_type = testInstanceType;
      };
      vpn = {
        enabled = vpnTest;
        ssh_user = sshUser;
        instance_type = testInstanceType;
      };
    };
  } // pkgs.lib.optionalAttrs (awsProfile != null) {
    aws_profile = awsProfile;
  }));

  # Packer is BSL-licensed (unfree) — import with allowUnfree for just this package
  unfreePkgs = import pkgs.path {
    inherit (pkgs) system;
    config.allowUnfreePredicate = pkg: builtins.elem (pkgs.lib.getName pkg) [ "packer" ];
  };

  # Internal: one-line app — just ami-forge pipeline --config <nix-generated-json>
  mkPipelineApp = { forgePackage, extraBinaries ? [] }:
    name: config: flags: {
      type = "app";
      program = toString (pkgs.writeShellScript name ''
        set -euo pipefail
        export PATH="${pkgs.lib.makeBinPath ([ forgePackage unfreePkgs.packer pkgs.awscli2 ] ++ extraBinaries)}:$PATH"
        exec ami-forge pipeline --config "${config}" ${flags}
      '');
    };

in rec {

  # Generate all AMI pipeline apps.
  #
  # Returns an attrset of 7 apps suitable for flake `apps.${system}` output.
  # Each app is a single `ami-forge pipeline --config <json>` call —
  # all logic lives in Rust, config is pure Nix → JSON.
  mkAmiBuildApps = {
    forgePackage,
    packerTemplate,
    ssmParameter,
    region ? "us-east-1",
    awsProfile ? null,
    sshUser ? "root",
    testInstanceType ? "t3.medium",
    testSubnet ? null,
    extraBinaries ? [],
    packerVars ? {},
  }: let
    app = mkPipelineApp { inherit forgePackage extraBinaries; };
    sharedArgs = { inherit packerTemplate ssmParameter region awsProfile sshUser testInstanceType testSubnet packerVars; };

    # JSON configs with different test gate combinations
    configBuild    = mkPipelineConfig (sharedArgs // { bootTest = false; vpnTest = false; });
    configBoot     = mkPipelineConfig (sharedArgs // { bootTest = true;  vpnTest = false; });
    configVpn      = mkPipelineConfig (sharedArgs // { bootTest = false; vpnTest = true;  });
    configFull     = mkPipelineConfig (sharedArgs // { bootTest = true;  vpnTest = true;  });

  in {
    ami-build            = app "ami-build"            configBuild "--skip-tests";
    ami-build-tested     = app "ami-build-tested"     configBoot  "";
    ami-build-vpn-tested = app "ami-build-vpn-tested" configVpn   "";
    ami-build-full       = app "ami-build-full"       configFull  "";
    ami-boot-test        = app "ami-boot-test"        configBoot  "--test-only";
    ami-vpn-test         = app "ami-vpn-test"         configVpn   "--test-only";
    ami-status           = app "ami-status"           configBuild "--status";
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
