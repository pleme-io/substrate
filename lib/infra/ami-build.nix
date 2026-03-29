# Reusable AMI build + test pipeline.
#
# Packer orchestrates everything — SSH keys, instance lifecycle, cleanup.
# ami-forge (Rust CLI) is called BY Packer and by the Nix-generated pipeline apps.
# Nix generates all Packer templates as JSON via builtins.toJSON.
#
# Architecture:
#   Nix (this file) generates Packer JSON templates.
#   mkAmiBuildPipeline creates `nix run` apps that invoke `ami-forge pipeline-run`.
#   ami-forge orchestrates: packer build → extract AMI → packer test → cluster-test → promote.
#   On any test failure, ami-forge deregisters the AMI (no bad AMIs in inventory).
#
# Key exports:
#   mkBuildTemplate   — generates build.pkr.json (base NixOS → nixos-rebuild → snapshot)
#   mkTestTemplate    — generates test.pkr.json (boot AMI, run validation)
#                       When testUserData is provided: boots with userdata, runs
#                       `kindling ami-integration-test` (VPN + K3s + kubectl).
#                       When null: runs `kindling ami-test` (11 static checks).
#   mkAmiBuildPipeline — generates nix run apps that call `ami-forge pipeline-run`
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

  # ── Cluster Test Config ──────────────────────────────────────
  # Generates a YAML config file (JSON is valid YAML) describing the
  # multi-node cluster topology for ami-forge cluster-test.
  mkClusterTestConfig = {
    nodes,
    instanceType ? "c7i.xlarge",
    timeout ? 600,
    k3sToken ? "ami-forge-cluster-test-token",
    clusterName ? "cluster-test",
    minReadyNodes ? (builtins.length nodes),
    minVpnHandshakes ? 2,
    kubectlFromClient ? true,
    # IAM instance profile name for EC2 tag-based state reporting.
    # Deployed via Pangea (one-time IaC). Instances tag themselves with
    # BootstrapPhase during kindling-init, orchestrator polls tags.
    instanceProfileName ? null,
  }: pkgs.writeText "cluster-test-config.yaml" (builtins.toJSON ({
    inherit timeout;
    instance_type = instanceType;
    k3s_token = k3sToken;
    cluster_name = clusterName;
    nodes = builtins.map (n: {
      name = n.name;
      role = n.role;
      vpn_address = n.vpn_address;
      node_index = n.node_index;
      cluster_init = n.cluster_init or false;
    }) nodes;
    checks = {
      min_ready_nodes = minReadyNodes;
      min_vpn_handshakes = minVpnHandshakes;
      kubectl_from_client = kubectlFromClient;
    };
  } // (if instanceProfileName != null then {
    instance_profile_name = instanceProfileName;
  } else {})));

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
          [{
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
    # Test userdata (JSON string) — injected as EC2 user_data.
    # Provides a minimal cluster-config for kindling-init to bootstrap.
    # If null, no userdata is injected (basic boot check only).
    testUserData ? null,
    # Commands to run on the test instance.
    # When testUserData is set: defaults to integration test (waits for kindling-init + validates VPN/K3s/kubectl).
    # When null: defaults to static AMI checks (binary presence, services, no stale state).
    testScript ? (if testUserData != null then [
      "export PATH=/run/current-system/sw/bin:$PATH"
      "kindling ami-integration-test --timeout 600"
    ] else [
      "kindling ami-test"
    ]),
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
      } // (if testUserData != null then {
        user_data = testUserData;
      } else {});

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
  # Configuration follows the shikumi pattern: Nix option → YAML config → Rust reads config.
  mkAmiBuildPipeline = {
    forgePackage,
    buildTemplate,
    testTemplate,
    ssmParameter,
    amiName,
    region ? "us-east-1",
    awsProfile ? null,
    extraBinaries ? [],
    skipClusterTest ? false,
    clusterTestConfig ? null,
    clusterTestInstanceType ? "c7i.xlarge",
    clusterTestTimeout ? 480,
  }: let
    # Generate pipeline config as YAML via Nix (JSON is valid YAML)
    pipelineConfig = pkgs.writeText "pipeline-config.yaml" (builtins.toJSON ({
      build_template = "${buildTemplate}";
      test_template = "${testTemplate}";
      ssm = ssmParameter;
      ami_name = amiName;
      inherit region;
      skip_cluster_test = skipClusterTest;
      cluster_test_instance_type = clusterTestInstanceType;
      cluster_test_timeout = clusterTestTimeout;
    } // (if skipClusterTest || clusterTestConfig == null then {}
      else { cluster_test = { config = "${clusterTestConfig}"; }; })));

    mkApp = name: script: {
      type = "app";
      program = toString (pkgs.writeShellScript name ''
        set -euo pipefail
        export PATH="${pkgs.lib.makeBinPath ([ forgePackage unfreePkgs.packer pkgs.awscli2 ] ++ extraBinaries)}:$PATH"
        ${pkgs.lib.optionalString (awsProfile != null) ''export AWS_PROFILE="${awsProfile}"''}
        ${script}
      '');
    };

  in {
    # Build AMI: build → test → promote (ONE pipeline, always tested)
    # All orchestration logic in Rust (ami-forge pipeline-run).
    # Config is a Nix-generated YAML file (shikumi pattern).
    ami-build = mkApp "ami-build" ''
      exec ami-forge pipeline-run --config "${pipelineConfig}"
    '';

    # Test existing AMI from SSM (re-run tests without rebuilding)
    ami-test = mkApp "ami-test" ''
      AMI_ID=$(aws ssm get-parameter --name "${ssmParameter}" --region "${region}" --query 'Parameter.Value' --output text)
      echo "Testing AMI: $AMI_ID"
      packer init "${testTemplate}"
      packer build -var "source_ami=$AMI_ID" "${testTemplate}"
    '';

    # Show AMI status
    ami-status = mkApp "ami-status" ''
      ami-forge status --ssm "${ssmParameter}" --region "${region}"
    '';
  };
}
