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
  #
  # shutdown_behavior = "terminate": the builder instance self-terminates on OS
  # shutdown, preventing orphaned instances if Packer loses connectivity or the
  # pipeline process is killed.
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

  # ── Hardening profile bundle ────────────────────────────────
  # Re-export so consumers can build their own provisioner scripts
  # without a separate import. See lib/infra/hardening-profiles/
  # for the underlying yaml files + helper.
  hardeningProfiles = import ./hardening-profiles { inherit pkgs; };

  # ── Nix build parallelism, sized to the builder instance ─────
  #
  # Every mkBuildTemplate provisioner runs `nixos-rebuild switch` on a
  # box that may have no reachable substituter (rio's Attic cache is
  # Tailscale MagicDNS-only — confirmed unreachable from a Camelot-VPC
  # builder via a live SSM probe, 2026-07-16), meaning a fully-cold
  # from-source build of the whole flake closure is a real, expected
  # path, not an edge case. nix's own default (max-jobs=auto == nproc,
  # cores=0 == unlimited per job) lets every core start its own
  # concurrent derivation build — fine for small closures, but for a
  # closure with dozens of heavy Rust crates (several large AWS SDK
  # crates, async-graphql, tatara-lisp, the project's own binaries) it
  # blows past available RAM and the box disconnects mid-build (the
  # portao-camelot-ami-build incident this table exists to prevent a
  # repeat of: 16-way-parallel on a 32GB c7i.4xlarge, 27 minutes in,
  # SSH dropped). The fix already landed once by hand as a hardcoded
  # `--option max-jobs 1 --option cores 1` in kindling-profiles — the
  # exact fleet-known-good pangea-operator CI value for a MUCH smaller
  # runner. That's safe everywhere but leaves most of a bigger box's
  # real capacity idle. This table auto-sizes instead: known-safe on a
  # box we've never measured, and not needlessly serial on one we have
  # real headroom on.
  #
  # perJobRamGb is a heuristic, not a measured ceiling — pangea-
  # operator's own postmortem (release.yml) found even 2 CONCURRENT
  # native compiles OOM'd a smaller runner, well under what a naive
  # "assume 2GB/job" division would predict was safe. Defaulting to
  # 4GB/job here is deliberately conservative given that lesson; pass
  # a lower value only once a specific crate graph's real peak RSS has
  # actually been measured (`/usr/bin/time -v` around a cold build),
  # not by guessing tighter.
  amiBuilderInstanceSpecs = {
    "t3.small"    = { vcpu = 2;  ramGb = 2;  };
    "t3.medium"   = { vcpu = 2;  ramGb = 4;  };
    "t3.large"    = { vcpu = 2;  ramGb = 8;  };
    "t3.xlarge"   = { vcpu = 4;  ramGb = 16; };
    "c7i.xlarge"  = { vcpu = 4;  ramGb = 8;  };
    "c7i.2xlarge" = { vcpu = 8;  ramGb = 16; };
    "c7i.4xlarge" = { vcpu = 16; ramGb = 32; };
    "c7i.8xlarge" = { vcpu = 32; ramGb = 64; };
  };

  # Returns the literal `--option max-jobs N --option cores M` string
  # to interpolate into a `nixos-rebuild switch` invocation, sized to
  # `instanceType`. Unknown instance types fall back to the
  # fleet-proven pangea-operator floor (max-jobs=1, cores=1) rather
  # than guessing — an unrecognized type is exactly the case where
  # this table has no evidence to size from, so it defers to the
  # known-safe value instead of extrapolating.
  nixBuildOptsFor = { instanceType, perJobRamGb ? 4 }:
    let
      spec = amiBuilderInstanceSpecs.${instanceType} or null;
      maxJobs =
        if spec == null then 1
        else pkgs.lib.max 1 (pkgs.lib.min spec.vcpu (spec.ramGb / perJobRamGb));
      cores =
        if spec == null then 1
        else pkgs.lib.max 1 (spec.vcpu / maxJobs);
    in "--option max-jobs ${toString maxJobs} --option cores ${toString cores}";

  # The FIRST `nixos-rebuild switch` every mkBuildTemplate provisioner runs
  # is unavoidably raw shell, not a `kindling ami-build` call — `kindling`
  # itself is one of the packages THIS rebuild installs, so it doesn't
  # exist on the box's PATH yet (the chicken-and-egg every consumer's own
  # `--skip-rebuild` flag on its SECOND `kindling ami-build` step already
  # assumes). What was genuinely a "solve once" violation is that six
  # kindling-profiles call sites each hand-typed their own copy of this
  # ~230-character Attic-conditional string — one had drifted to
  # hand-append `--option max-jobs 1 --option cores 1`, the other five
  # didn't, an inconsistency nixBuildOptsFor's $NIX_BUILD_OPTS (env var,
  # already exported by mkBuildTemplate/mkLayerTemplate below) now makes
  # structurally impossible to drift on. Callers interpolate this ONE
  # string instead of retyping the conditional; $FLAKE_REF/$GITHUB_TOKEN/
  # $ATTIC_URL/$NIX_BUILD_OPTS all come from the provisioner's own
  # environment_vars.
  nixosRebuildSwitchStep =
    ''if [ -n "$ATTIC_URL" ]; then echo "Using Attic cache: $ATTIC_URL"; nixos-rebuild switch --flake $FLAKE_REF --option access-tokens github.com=$GITHUB_TOKEN --option extra-substituters "$ATTIC_URL" --option require-sigs false $NIX_BUILD_OPTS; else nixos-rebuild switch --flake $FLAKE_REF --option access-tokens github.com=$GITHUB_TOKEN $NIX_BUILD_OPTS; fi'';

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
    # List of profile names to apply via `kindling harden` after the
    # main provisionerScript. Accepts the same stack keys as the
    # hardening-profiles bundle: "base", "hardened", "ami-full",
    # "cis-level-1". Pass `null` (default) to skip — some pipelines
    # handle hardening themselves inside provisionerScript.
    hardeningStack ? null,
    # When true, a Degraded hardening report also fails the build.
    # Default `false` matches `kindling harden`'s exit semantics.
    hardeningStrict ? false,
  }: let
    hardeningProfiles = import ./hardening-profiles { inherit pkgs; };
    # Resolve a stack name ("base", "hardened", "ami-full",
    # "cis-level-1") into its ordered list of profile-name strings.
    # ami-full expands to base + hardened + ami-snapshot; cis-level-1
    # is standalone. The resolved names are passed to mkHardenStep
    # as `stackNames` so the profile YAML is inlined into the Packer
    # provisioner (remote /nix/store paths don't resolve otherwise).
    stackNameList = {
      base = [ "base" ];
      hardened = [ "base" "hardened" ];
      ami-full = [ "base" "hardened" "ami-snapshot" ];
      cis-level-1 = [ "cis-level-1" ];
    };
    hardeningSteps =
      if hardeningStack == null
      then []
      else hardeningProfiles.mkHardenStep {
        stackNames = stackNameList.${hardeningStack};
        strict = hardeningStrict;
      };
    fullProvisioner = provisionerScript ++ hardeningSteps;
    template = {
      variable = {
        ami_name = { type = "string"; default = amiName; };
        region = { type = "string"; default = region; };
        instance_type = { type = "string"; default = instanceType; };
        volume_size = { type = "number"; default = volumeSize; };
        github_token = { type = "string"; default = ""; sensitive = true; };
        flake_ref = { type = "string"; default = flakeRef; };
        attic_url = { type = "string"; default = ""; };
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
          ManagedBy = "pangea";
          BuildTimestamp = "{{timestamp}}";
          SourceFlake = "\${var.flake_ref}";
        } // extraTags;
        run_tags = {
          Name = "ami-forge-builder";
          ManagedBy = "pangea";
          "ami-forge:purpose" = "ami-build";
          "ami-forge:ttl-hours" = "4";
        };
      };

      build = [{
        sources = [ "source.amazon-ebs.nixos" ];
        provisioner =
          [{
            shell = {
              inline = fullProvisioner;
              environment_vars = [
                "GITHUB_TOKEN=\${var.github_token}"
                "FLAKE_REF=\${var.flake_ref}"
                "ATTIC_URL=\${var.attic_url}"
                # Auto-sized nix build parallelism for THIS template's
                # instanceType — see nixBuildOptsFor above. Every
                # provisionerScript should interpolate $NIX_BUILD_OPTS
                # into its `nixos-rebuild switch` invocation instead of
                # a hand-typed --option max-jobs/--option cores literal,
                # so the safe value tracks the instance the template
                # actually declares rather than drifting per-consumer.
                "NIX_BUILD_OPTS=${nixBuildOptsFor { inherit instanceType; }}"
              ] ++ extraEnvironmentVars;
              # `nixos-rebuild switch` (the standard first step of
              # fullProvisioner/provisionerScript for every mkBuildTemplate
              # consumer) CAN legitimately restart networking/sshd when the
              # activation touches those units, dropping Packer's SSH
              # session mid-script — kept as defensive hardening for that
              # case. Correction (2026-07-16, same day): the original
              # comment here cited the portao-camelot-ami-build 27-minute
              # disconnect as "confirmed live" evidence for THIS failure
              # mode, but a direct read of that build's own log shows the
              # disconnect landed mid-way through `nixos-rebuild switch`'s
              # BUILD phase (compiling rust_pleme-kindling-0.3.0.drv, one
              # of the last derivations in the graph) — well before any
              # activation step runs, so no networking/sshd restart could
              # have occurred yet. That incident's real cause was nix's
              # unconstrained max-jobs=auto running ~16 heavy Rust crate
              # builds concurrently on the c7i.4xlarge builder with no
              # substituter cache reachable (rio's Attic is Tailscale-only,
              # unreachable from that VPC), OOM-adjacent resource
              # exhaustion — fixed via nixBuildOptsFor below (auto-sized
              # max-jobs/cores), not by this setting. Leaving
              # expect_disconnect=true in place regardless — it is still
              # sound defensive coverage for a genuine, separate failure
              # mode, just not what actually happened here.
              expect_disconnect = true;
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
          ManagedBy = "pangea";
          "ami-forge:purpose" = "ami-test";
          "ami-forge:ttl-hours" = "2";
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

  # ── Layer Template (for multi-layer AMI pipelines) ──────────────
  # Generalized template builder supporting both source AMI filter mode
  # (Layer 1 — finds base NixOS) and explicit source AMI mode (Layers 2+).
  mkLayerTemplate = {
    name ? "layer.pkr.json",
    amiName,
    provisionerScript,
    # When false: uses sourceAmiFilter to find base AMI (like mkBuildTemplate)
    # When true: uses source_ami variable (like mkTestTemplate)
    sourceAmiVariable ? false,
    sourceAmiFilter ? { name = "nixos/25.*"; architecture = "x86_64"; },
    sourceAmiOwners ? [ "427812963091" ],
    instanceType ? "c7i.4xlarge",
    volumeSize ? 30,
    region ? "us-east-1",
    iops ? 8000,
    throughput ? 500,
    extraVariables ? {},
    extraEnvironmentVars ? [],
    extraTags ? {},
    skipCreateAmi ? false,
  }: let
    template = {
      variable = {
        ami_name = { type = "string"; default = amiName; };
        region = { type = "string"; default = region; };
        instance_type = { type = "string"; default = instanceType; };
        volume_size = { type = "number"; default = volumeSize; };
        github_token = { type = "string"; default = ""; sensitive = true; };
        attic_url = { type = "string"; default = ""; };
      } // (if sourceAmiVariable then {
        source_ami = { type = "string"; };
      } else {}) // extraVariables;

      packer.required_plugins = requiredPlugins;

      source.amazon-ebs.nixos = nixosSourceDefaults // {
        ami_name = "\${var.ami_name}";
        region = "\${var.region}";
        instance_type = "\${var.instance_type}";
      } // (if sourceAmiVariable then {
        source_ami = "\${var.source_ami}";
      } else {
        source_ami_filter = {
          filters = {
            virtualization-type = "hvm";
            root-device-type = "ebs";
          } // sourceAmiFilter;
          owners = sourceAmiOwners;
          most_recent = true;
        };
      }) // {
        launch_block_device_mappings = [{
          device_name = "/dev/xvda";
          volume_size = "\${var.volume_size}";
          volume_type = "gp3";
          inherit iops throughput;
          delete_on_termination = true;
        }];
        skip_create_ami = skipCreateAmi;
        force_deregister = !skipCreateAmi;
        force_delete_snapshot = !skipCreateAmi;
        tags = {
          Name = "\${var.ami_name}";
          ManagedBy = "pangea";
          BuildTimestamp = "{{timestamp}}";
        } // extraTags;
        run_tags = {
          Name = "ami-forge-layer-builder";
          ManagedBy = "pangea";
          "ami-forge:purpose" = "layer-build";
          "ami-forge:ttl-hours" = "4";
        };
      };

      build = [({
        sources = [ "source.amazon-ebs.nixos" ];
        provisioner = [{
          shell = {
            inline = provisionerScript;
            environment_vars = [
              "GITHUB_TOKEN=\${var.github_token}"
              "ATTIC_URL=\${var.attic_url}"
              # See mkBuildTemplate's identical field — same nixosRebuildSwitchStep
              # is usable here for any layer whose provisionerScript runs its own
              # `nixos-rebuild switch`.
              "NIX_BUILD_OPTS=${nixBuildOptsFor { inherit instanceType; }}"
            ] ++ extraEnvironmentVars;
            # See mkBuildTemplate's identical field for why: a caller-supplied
            # provisionerScript that runs `nixos-rebuild switch` can
            # legitimately disconnect Packer's SSH session mid-activation.
            expect_disconnect = true;
          };
        }];
      } // (if !skipCreateAmi then {
        post-processor.manifest = {
          output = "packer-manifest.json";
          strip_path = true;
        };
      } else {}))];
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
    # Attic ephemeral cache (optional). When set, ami-forge boots an Attic
    # instance before building, uses it as a substituter, snapshots after.
    atticSsm ? null,          # SSM parameter with Attic AMI ID
    atticInstanceType ? "t3.medium",
    atticCacheName ? "nexus",
    # When true, ami-forge adds a public LaunchPermission (Group=all)
    # after promoting to SSM. Lets any AWS account launch the AMI
    # without per-account shares. Use only for AMIs known to carry no
    # secrets — privkeys must arrive at runtime (e.g. SSM, IMDSv2).
    makePublic ? false,
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
      make_public = makePublic;
    } // (if skipClusterTest || clusterTestConfig == null then {}
      else { cluster_test = { config = "${clusterTestConfig}"; }; })
    // (if atticSsm == null then {}
      else { attic = {
        ssm = atticSsm;
        instance_type = atticInstanceType;
        cache_name = atticCacheName;
      }; })));

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

  # ── Multi-Layer Pipeline Apps ────────────────────────────────────
  # Generates nix run apps for multi-layer AMI build pipeline.
  # Each layer produces an intermediate AMI checkpointed in SSM.
  mkMultiLayerPipeline = {
    forgePackage,
    layers,           # list of { template, name, ssmParameter, fingerprintInputs ? [] }
    testLayers ? [],  # list of { template, name }
    promoteSsm,
    amiName,
    region ? "us-east-1",
    awsProfile ? null,
    extraBinaries ? [],
    atticSsm ? null,
    atticInstanceType ? "t3.medium",
    atticCacheName ? "nexus",
  }: let
    pipelineConfig = pkgs.writeText "multi-layer-pipeline-config.yaml" (builtins.toJSON ({
      layers = map (l: {
        template = "${l.template}";
        name = l.name;
        ssm_parameter = l.ssmParameter;
        fingerprint_inputs = l.fingerprintInputs or [];
      }) layers;
      test_layers = map (t: {
        template = "${t.template}";
        name = t.name;
      }) testLayers;
      promote_ssm = promoteSsm;
      ami_name = amiName;
      inherit region;
    } // (if atticSsm == null then {} else {
      attic = {
        ssm = atticSsm;
        instance_type = atticInstanceType;
        cache_name = atticCacheName;
      };
    })));

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
    ami-build = mkApp "ami-build-layered" ''
      exec ami-forge multi-layer-run --config "${pipelineConfig}"
    '';

    ami-status = mkApp "ami-status-layered" ''
      echo "Layer status:"
      ${builtins.concatStringsSep "\n" (map (l: ''
        echo -n "  ${l.name}: "
        aws ssm get-parameter --name "${l.ssmParameter}" --region "${region}" --query 'Parameter.Value' --output text 2>/dev/null || echo "not built"
      '') layers)}
      echo -n "  promoted: "
      aws ssm get-parameter --name "${promoteSsm}" --region "${region}" --query 'Parameter.Value' --output text 2>/dev/null || echo "not promoted"
    '';
  };

  # ── Multi-Arch AMI Pipelines ──────────────────────────────────
  # The common case: same AMI shape, different CPU architectures (and
  # whatever arch-dependent knobs fall out — source AMI SSM path,
  # Packer build template, AMI name prefix). Instead of every caller
  # copy-pasting mkAmiBuildPipeline once per arch, declare the list
  # once and get symmetrical nix-run apps out.
  #
  # Input:  archs = [ "aarch64" "x86_64" ... ];
  #         anything produced "for this arch" is supplied as a
  #         function `a -> …`.
  # Output: { ami-build-<arch>, ami-test-<arch>, ami-status-<arch> }
  #         for each arch, plus a `ami-build-all` helper that runs
  #         every build sequentially.
  mkAmiBuildPipelines = {
    forgePackage,
    archs,                 # [ "aarch64" "x86_64" ]
    buildTemplateFor,      # arch -> derivation (Packer build template)
    testTemplateFor,       # arch -> derivation (Packer test template)
    ssmParameterFor,       # arch -> string (SSM path holding promoted AMI id)
    amiNameFor,            # arch -> string (Packer ami_name)
    region ? "us-east-1",
    awsProfile ? null,
    extraBinaries ? [],
    skipClusterTest ? false,
    clusterTestConfigFor ? null,  # arch -> derivation  (or null for skip)
    clusterTestInstanceType ? "c7i.xlarge",
    clusterTestTimeout ? 480,
    atticSsm ? null,
    atticInstanceType ? "t3.medium",
    atticCacheName ? "nexus",
    makePublic ? false,
  }: let
    # Reuse the single-arch builder for each arch in the list, and
    # rewrite the resulting attribute keys to be arch-suffixed so
    # they can all coexist under `apps = { … }`.
    perArch = arch: let
      cluster = if clusterTestConfigFor == null then null else clusterTestConfigFor arch;
      apps = mkAmiBuildPipeline {
        inherit forgePackage region awsProfile extraBinaries
          skipClusterTest clusterTestInstanceType clusterTestTimeout
          atticSsm atticInstanceType atticCacheName makePublic;
        buildTemplate = buildTemplateFor arch;
        testTemplate  = testTemplateFor arch;
        ssmParameter  = ssmParameterFor arch;
        amiName       = amiNameFor arch;
        clusterTestConfig = cluster;
      };
    in
      pkgs.lib.mapAttrs' (name: value:
        pkgs.lib.nameValuePair "${name}-${arch}" value
      ) apps;

    merged = pkgs.lib.foldl' (a: b: a // b) {} (map perArch archs);

    # Convenience aggregator: run every ami-build-<arch> in order.
    buildAll = {
      type = "app";
      program = toString (pkgs.writeShellScript "ami-build-all" ''
        set -euo pipefail
        ${pkgs.lib.concatMapStringsSep "\n" (a: ''
          echo "=== build ${a} ==="
          ${merged."ami-build-${a}".program}
        '') archs}
      '');
    };
  in merged // { ami-build-all = buildAll; };
}
