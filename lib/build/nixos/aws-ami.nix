# mkNixosAwsAmi — build an AWS AMI from a NixOS configuration.
#
# Reusable substrate primitive that wraps the "NixOS-system-closure → AWS AMI"
# pattern. Any pleme-io NixOS configuration can become an AMI with one call.
#
# Formalizes the approach Agent X's platform-packer migration takes today
# (arch-synthesizer@f2ef263 + pangea-architectures@da0f1ee): a Packer
# template invokes `nixos-rebuild switch --refresh --flake <ref>#<profile>`
# on a bootstrap EC2 instance, then snapshots to AMI. That exact flow is
# the `packer` mode here, emitted via a content-equivalent JSON shape.
#
# Two modes:
#
#   - "packer" (default, current path): emits a Packer JSON template. The
#     consumer feeds it to `packer build`. This is what platform-packer
#     does today. ZERO-COST adoption for kindling-profiles — the emitted
#     template matches the hand-written one to a narrow, documented diff.
#
#   - "direct" (future path, stubbed): `nix build` produces a raw image
#     (via nixos-generators' `amazon` format). Registration happens via
#     `aws ec2 import-snapshot` + `aws ec2 register-image`. No Packer, no
#     bootstrap instance. The interface is shipped; the nixos-generators
#     integration lands incrementally (see TODO in `mkDirect`).
#
# ── AmiConventionDecl integration ────────────────────────────────────
# `arch-synthesizer::AmiConventionDecl` produces:
#   - `.name(ctx)`               → canonical AMI name
#   - `.all_tags()`              → `Vec<(String, String)>` tag pairs
#   - `.snapshot_tags()`         → snapshot tag pairs
#   - `.ami_mgmt_identifier()`   → retention identifier
#
# `mkNixosAwsAmi` consumes those as `amiName` + `amiTags` (attr set) +
# `snapshotTags` (attr set, optional). The Rust convention → Nix builder
# → AWS AMI path is typed end-to-end.
#
# ── Flattening ────────────────────────────────────────────────────────
# Packer receives identical tag attr sets on three axes:
#   - `tags`           → applied to the AMI itself
#   - `snapshot_tags`  → applied to the backing EBS snapshot(s)
#   - `run_tags`       → applied to the ephemeral builder instance
#
# `run_tags` deviates from `tags`: it tags the instance as a *builder*
# (ami-forge observability), not as the final artifact. Callers may pass
# `runTagOverrides` to replace/extend the builder-instance tag set.
#
# ── Usage ────────────────────────────────────────────────────────────
#   substrateLib = substrate.lib.${system};
#   ami = substrateLib.mkNixosAwsAmi {
#     nixosSystem  = "github:pleme-io/kindling-profiles#ami-builder";
#     amiName      = amiConvention.name;          # from Rust
#     amiTags      = amiConvention.allTags;       # from Rust
#     architecture = "arm64";
#     region       = "us-east-1";
#     mode         = "packer";                    # default
#   };
#   # packer mode: ami.packerTemplate is a /nix/store/....pkr.json path
#   # direct mode: ami.package is the build derivation,
#   #              ami.registerApp is a `nix run` app that uploads + registers.
{ pkgs, ... }:

{
  nixosSystem,                          # string: flake ref "github:org/repo#config"
                                        #          OR an attr {flakeRef, profile}
  amiName,                              # string (from AmiConventionDecl::name)
  amiTags ? {},                         # attr set (from AmiConventionDecl::all_tags
                                        #           rendered as {K = V;})
  snapshotTags ? null,                  # attr set, defaults to amiTags if null
  runTagOverrides ? {},                 # attr set, extra tags on the builder
                                        # instance (NOT the final AMI)
  architecture ? "arm64",               # "arm64" | "x86_64"
  region ? "us-east-1",
  mode ? "packer",                      # "packer" | "direct"

  # ── Packer-mode knobs (ignored in direct mode) ────────────────────
  instanceType ? (if architecture == "arm64" then "c7g.large" else "c7i.large"),
  volumeSizeGb ? 30,
  nixosVersion ? "25.05",
  nixosOwner ? "427812963091",           # official NixOS AMI owner account
  subnetId ? null,                      # optional: pin to a specific subnet
  vpcId ? null,                         # optional: pin to a specific VPC
  iamInstanceProfile ? null,            # optional: IAM role for the builder
  kmsKeyId ? null,                      # optional: KMS key for EBS encryption
  amiMgmtIdentifier ? null,             # optional: amazon-ami-management
                                        #   retention series identifier
  keepReleases ? 1,                     # retention count for the sweeper
  extraProvisionerCommands ? [],        # extra shell commands appended to
                                        # the provisioner script

  # ── Direct-mode knobs (ignored in packer mode) ────────────────────
  nixosGenerators ? null,               # nixos-generators flake input;
                                        # required when mode == "direct"
  bucket ? null,                        # S3 bucket for import-snapshot;
                                        # required when mode == "direct"
  ...
}:

let
  inherit (pkgs) lib;

  # ── Arch normalization ─────────────────────────────────────────────
  # architecture:    "arm64" | "x86_64"
  # systemTarget:    "aarch64-linux" | "x86_64-linux"
  # packerArch:      same as architecture (Packer matches NixOS AMI labels)
  archMap = {
    "arm64"  = "aarch64-linux";
    "x86_64" = "x86_64-linux";
  };
  systemTarget = archMap.${architecture} or (throw
    "mkNixosAwsAmi: unsupported architecture '${architecture}' (expected 'arm64' or 'x86_64')");

  # ── Flake ref parsing ──────────────────────────────────────────────
  # Accept either a string "github:org/repo#profile" or an attr set.
  parsedNixosSystem =
    if builtins.isAttrs nixosSystem then {
      flakeRef = nixosSystem.flakeRef or
        (throw "mkNixosAwsAmi: nixosSystem attr set must have flakeRef");
      profile  = nixosSystem.profile or "default";
    } else if builtins.isString nixosSystem then
      # "github:x/y#profile" → split on '#'
      let
        parts = builtins.split "#" nixosSystem;
      in
      if (builtins.length parts) == 3 then {
        flakeRef = builtins.elemAt parts 0;
        profile  = builtins.elemAt parts 2;
      } else {
        flakeRef = nixosSystem;
        profile  = "default";
      }
    else throw "mkNixosAwsAmi: nixosSystem must be a string or attr set";

  # ── Tag sets ───────────────────────────────────────────────────────
  effectiveSnapshotTags =
    if snapshotTags == null then amiTags else snapshotTags;

  # Builder-instance tags — ephemeral instance, ami-forge observability.
  # Caller overrides via runTagOverrides (merged last-wins).
  defaultRunTags = {
    Name                     = "${amiName}-builder";
    ManagedBy                = "ami-forge";
    "ami-forge:purpose"      = "ami-build";
    "ami-forge:ttl-hours"    = "4";
  };
  effectiveRunTags = defaultRunTags // runTagOverrides;

  # ── Packer mode ────────────────────────────────────────────────────
  mkPackerTemplate = let
    provisionerInline = [
      "set -euo pipefail"
      "mkdir -p /etc/nix"
      "echo 'experimental-features = nix-command flakes' > /etc/nix/nix.conf"
      "mkdir -p /root/.config/nix && chmod 700 /root/.config/nix"
      # Private-flake access via GITHUB_TOKEN environment variable.
      "if [ -n \"$GITHUB_TOKEN\" ]; then echo \"access-tokens = github.com=$GITHUB_TOKEN\" >> /etc/nix/nix.conf; fi"
      # The one-line point of this primitive:
      "nixos-rebuild switch --refresh --flake ${parsedNixosSystem.flakeRef}#${parsedNixosSystem.profile}"
      "nix-collect-garbage -d"
      "nix-store --optimize"
    ] ++ extraProvisionerCommands;

    # Standard cleanup provisioner (run after nixos-rebuild).
    cleanupInline = [
      "set -euo pipefail"
      "rm -rf /tmp/* /var/tmp/*"
      "journalctl --vacuum-size=1M || true"
      "rm -f /etc/ssh/ssh_host_*"
      "truncate -s 0 /etc/machine-id"
      ": > /var/log/lastlog"
      ": > /var/log/wtmp"
      ": > /var/log/btmp"
      "rm -f /root/.ssh/authorized_keys"
    ];

    # Source AMI filter — matches NixOS official AMIs for the target arch.
    sourceAmiFilter = {
      architecture         = architecture;
      name                 = "nixos/${nixosVersion}*";
      "root-device-type"   = "ebs";
      "virtualization-type" = "hvm";
    };

    # Builder block — one amazon-ebs source, shell provisioners,
    # manifest + (optional) amazon-ami-management post-processor.
    builder = {
      type                                      = "amazon-ebs";
      name                                      = "nixos-builder";
      ami_name                                  = amiName;
      ami_description                           = "NixOS ${nixosVersion} system closure from ${parsedNixosSystem.flakeRef}#${parsedNixosSystem.profile}";
      region                                    = region;
      instance_type                             = instanceType;
      associate_public_ip_address               = true;
      ssh_username                              = "root";
      ssh_timeout                               = "30m";
      ssh_handshake_attempts                    = 30;
      temporary_key_pair_type                   = "ed25519";
      temporary_security_group_source_public_ip = true;
      shutdown_behavior                         = "terminate";
      force_deregister                          = true;
      force_delete_snapshot                     = true;
      source_ami_filter = {
        filters     = sourceAmiFilter;
        most_recent = true;
        owners      = [ nixosOwner ];
      };
      launch_block_device_mappings = [
        ({
          device_name          = "/dev/xvda";
          volume_size          = volumeSizeGb;
          volume_type          = "gp3";
          delete_on_termination = true;
          encrypted            = (kmsKeyId != null);
        } // (lib.optionalAttrs (kmsKeyId != null) { kms_key_id = kmsKeyId; }))
      ];
      metadata_options = {
        http_endpoint             = "enabled";
        http_put_response_hop_limit = 1;
        http_tokens               = "required";
      };
      tags           = amiTags;
      snapshot_tags  = effectiveSnapshotTags;
      run_tags       = effectiveRunTags;
    }
      // (lib.optionalAttrs (vpcId != null) { vpc_id = vpcId; })
      // (lib.optionalAttrs (subnetId != null) { subnet_id = subnetId; })
      // (lib.optionalAttrs (iamInstanceProfile != null) { iam_instance_profile = iamInstanceProfile; });

    postProcessors =
      [ { type = "manifest"; output = "packer-manifest.json"; strip_path = true; } ]
      ++ (lib.optional (amiMgmtIdentifier != null) {
        type          = "amazon-ami-management";
        identifier    = amiMgmtIdentifier;
        keep_releases = keepReleases;
        regions       = [ region ];
      });

    template = {
      builders = [ builder ];
      provisioners = [
        { type = "shell"; inline = provisionerInline; }
        { type = "shell"; inline = cleanupInline; }
      ];
      "post-processors" = postProcessors;
    };
  in {
    # Pure attr set — pure-eval testable, no derivation build required.
    value = template;
    # Realized /nix/store path for Packer to consume at build time.
    file = pkgs.writeText "${amiName}.pkr.json" (builtins.toJSON template);
  };

  # ── Direct mode (future) ───────────────────────────────────────────
  # TODO: wire nixos-generators' `amazon` format. Today this emits a
  # stub derivation + app that clearly declares the gap, so consumers
  # can depend on the interface while the integration lands.
  #
  # Landing plan:
  #   1. Take nixosGenerators flake input (`github:nix-community/nixos-generators`).
  #   2. Build the NixOS system via `nixosGenerators.nixosGenerate {
  #        inherit system; format = "amazon"; modules = [ ... ]; }`.
  #   3. Upload the resulting VHD to `bucket` (aws s3 cp).
  #   4. `aws ec2 import-snapshot` → wait → `aws ec2 register-image`
  #      with `amiTags` applied via `--tag-specifications`.
  #
  # The public shape of direct-mode output is already fixed:
  #   { package, registerApp }
  mkDirect = let
    stubPackage = pkgs.writeText "${amiName}-direct-stub.txt" ''
      mkNixosAwsAmi direct-mode stub for ${amiName}.

      nixos-generators integration is pending. When ready, this file
      will be replaced by the actual amazon-image VHD built from:

        nixosSystem = ${builtins.toJSON parsedNixosSystem}
        systemTarget = ${systemTarget}
        region = ${region}

      Tracking: substrate/lib/build/nixos/aws-ami.nix mkDirect TODO.
    '';

    registerScript = pkgs.writeShellScript "register-aws-ami-${amiName}" ''
      set -euo pipefail
      echo "direct-mode registration for ${amiName} is not yet implemented."
      echo "See substrate/lib/build/nixos/aws-ami.nix mkDirect TODO."
      exit 1
    '';
  in {
    package     = stubPackage;
    packageName = "aws-ami-${amiName}";
    registerApp = {
      type    = "app";
      program = toString registerScript;
    };
    registerAppName = "register-aws-ami-${amiName}";
  };

in
  if mode == "packer" then {
    inherit mode amiName architecture region;
    # File path (consumed by Packer at build time).
    packerTemplate = mkPackerTemplate.file;
    # Raw attr set — for pure-eval tests + assertions + programmatic
    # rewriting by downstream tooling that wants to transform the
    # template before `packer build` sees it.
    packerTemplateValue = mkPackerTemplate.value;
    # Expose normalized inputs for consumers who want to inspect what
    # the primitive resolved (arch map, parsed flake ref, tag sets).
    resolved = {
      inherit systemTarget;
      inherit (parsedNixosSystem) flakeRef profile;
      tags         = amiTags;
      snapshotTags = effectiveSnapshotTags;
      runTags      = effectiveRunTags;
    };
  }
  else if mode == "direct" then {
    inherit mode amiName architecture region;
    inherit (mkDirect) package packageName registerApp registerAppName;
    resolved = {
      inherit systemTarget;
      inherit (parsedNixosSystem) flakeRef profile;
      tags         = amiTags;
      snapshotTags = effectiveSnapshotTags;
      runTags      = effectiveRunTags;
    };
  }
  else throw "mkNixosAwsAmi: unknown mode '${mode}' (expected 'packer' or 'direct')"
