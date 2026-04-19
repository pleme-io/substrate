# Pure-eval tests for mkNixosAwsAmi.
#
# Uses substrate's pure-eval test harness (util/test-helpers.nix). Tests
# exercise the raw Packer template attr set (`packerTemplateValue`) so no
# derivations are built — the tests run at Nix eval time.
#
# Usage:
#   nix eval --impure --expr \
#     '(import ./lib/build/nixos/tests.nix {}).summary'
#
# The `pkgs` that feeds `mkNixosAwsAmi` is a MINIMAL mock exposing only
# what the primitive touches at attr-set-construction time:
#   - `pkgs.lib`           (from nixpkgs)
#   - `pkgs.writeText`     (forced only when rendering the realized path;
#                           tests touch only the pure attr set, so we
#                           can stub it with any function)
#   - `pkgs.writeShellScript` (same)
{
  # Caller supplies nixpkgs.lib (matches the convention used by the rest
  # of substrate's pure-eval test files — see lib/infra/tests.nix).
  # Usage from flake.nix:
  #   nixosTests = import lib/build/nixos/tests.nix { lib = pkgs.lib; };
  lib ? (import <nixpkgs> { system = builtins.currentSystem; }).lib,
  # Optional: pass a real `pkgs` to exercise the realized derivations too.
  # Default: a minimal stub that returns fake store paths from writeText.
  pkgs ? null,
}:

let

  # Stub pkgs — only what mkNixosAwsAmi destructures.
  stubPkgs = {
    inherit lib;
    # Both writeText and writeShellScript return a "derivation-like"
    # string; the tests never inspect them, but we keep .outPath for
    # type safety in case a future test does.
    writeText = name: content: {
      _type = "derivation";
      inherit name;
      outPath = "/nix/store/stub-${name}";
      drvPath = "/nix/store/stub-${name}.drv";
    };
    writeShellScript = name: content: {
      _type = "derivation";
      inherit name;
      outPath = "/nix/store/stub-${name}";
      drvPath = "/nix/store/stub-${name}.drv";
    };
  };

  effectivePkgs = if pkgs != null then pkgs else stubPkgs;

  testHelpers = import ../../util/test-helpers.nix { inherit lib; };
  inherit (testHelpers) mkTest runTests;

  mkNixosAwsAmi = import ./aws-ami.nix { pkgs = effectivePkgs; };

  # ── Fixtures ──────────────────────────────────────────────────────
  # Tags modeling the shape `arch-synthesizer::AmiConventionDecl.all_tags()`
  # produces (as a Nix attr set — `Vec<(String, String)>` → attr set).
  conventionTags = {
    ManagedBy                          = "pangea";
    Platform                           = "quero";
    Role                               = "builder";
    Purpose                            = "ami-builder";
    "Amazon-AMI-Management-Identifier" = "quero-builder";
    RetentionClass                     = "packer-replace";
  };

  conventionName = "quero-builder-2026-04-19-154530";

  # Packer-mode ARM64 (canonical case — matches platform-packer today).
  packerArm64 = mkNixosAwsAmi {
    nixosSystem = "github:pleme-io/kindling-profiles#ami-builder";
    amiName     = conventionName;
    amiTags     = conventionTags;
    architecture = "arm64";
    region      = "us-east-1";
    mode        = "packer";
  };

  packerX86 = mkNixosAwsAmi {
    nixosSystem = "github:pleme-io/kindling-profiles#ami-builder";
    amiName     = conventionName;
    amiTags     = conventionTags;
    architecture = "x86_64";
    region      = "us-east-1";
    mode        = "packer";
  };

  direct = mkNixosAwsAmi {
    nixosSystem = "github:pleme-io/kindling-profiles#ami-builder";
    amiName     = conventionName;
    amiTags     = conventionTags;
    architecture = "arm64";
    region      = "us-east-1";
    mode        = "direct";
  };

  packerWithMgmt = mkNixosAwsAmi {
    nixosSystem = "github:pleme-io/kindling-profiles#ami-builder";
    amiName     = conventionName;
    amiTags     = conventionTags;
    architecture = "arm64";
    mode        = "packer";
    amiMgmtIdentifier = "quero-builder";
    keepReleases      = 2;
  };

  packerWithRunOverride = mkNixosAwsAmi {
    nixosSystem = "github:pleme-io/kindling-profiles#ami-builder";
    amiName     = conventionName;
    amiTags     = conventionTags;
    architecture = "arm64";
    mode        = "packer";
    runTagOverrides = {
      "ami-forge:purpose"   = "layer-build";
      "ami-forge:ttl-hours" = "8";
    };
  };

  packerAttrSystem = mkNixosAwsAmi {
    nixosSystem = {
      flakeRef = "github:pleme-io/kindling-profiles";
      profile  = "k8s-builder";
    };
    amiName     = conventionName;
    amiTags     = conventionTags;
    architecture = "arm64";
    mode        = "packer";
  };

  # Helpers for rummaging around in the template attr set.
  firstBuilder = t: builtins.elemAt t.packerTemplateValue.builders 0;
  firstProvisioner = t: builtins.elemAt t.packerTemplateValue.provisioners 0;

in runTests [
  # ════════════════════════════════════════════════════════════════════
  # mode="packer" — template shape
  # ════════════════════════════════════════════════════════════════════

  (mkTest "packer-returns-mode"
    (packerArm64.mode == "packer")
    "packer mode should preserve mode in output")

  (mkTest "packer-returns-amiName"
    (packerArm64.amiName == conventionName)
    "amiName should be preserved in output")

  (mkTest "packer-returns-arch"
    (packerArm64.architecture == "arm64")
    "architecture should be preserved in output")

  (mkTest "packer-returns-region"
    (packerArm64.region == "us-east-1")
    "region should be preserved in output")

  (mkTest "packer-template-has-builders"
    (builtins.length packerArm64.packerTemplateValue.builders == 1)
    "template should have exactly one builder")

  (mkTest "packer-template-has-two-provisioners"
    (builtins.length packerArm64.packerTemplateValue.provisioners == 2)
    "template should have provisioner (rebuild + cleanup)")

  (mkTest "packer-builder-is-amazon-ebs"
    ((firstBuilder packerArm64).type == "amazon-ebs")
    "builder type should be amazon-ebs")

  (mkTest "packer-builder-has-ami-name"
    ((firstBuilder packerArm64).ami_name == conventionName)
    "builder ami_name should match amiName input")

  (mkTest "packer-builder-has-shutdown-terminate"
    ((firstBuilder packerArm64).shutdown_behavior == "terminate")
    "shutdown_behavior = terminate (no orphan instances)")

  (mkTest "packer-builder-has-imdsv2"
    ((firstBuilder packerArm64).metadata_options.http_tokens == "required")
    "IMDSv2 required — metadata_options.http_tokens = required")

  (mkTest "packer-post-processor-manifest-present"
    (let pp = packerArm64.packerTemplateValue."post-processors";
     in builtins.length pp == 1
        && (builtins.elemAt pp 0).type == "manifest")
    "packer-manifest.json post-processor always present")

  # ════════════════════════════════════════════════════════════════════
  # mode="packer" — tag flattening
  # ════════════════════════════════════════════════════════════════════

  (mkTest "packer-tags-flattened-to-ami-tags"
    ((firstBuilder packerArm64).tags == conventionTags)
    "amiTags flattened directly into builder.tags")

  (mkTest "packer-snapshot-tags-default-to-ami-tags"
    ((firstBuilder packerArm64).snapshot_tags == conventionTags)
    "snapshot_tags default to amiTags when snapshotTags is null")

  (mkTest "packer-run-tags-default"
    ((firstBuilder packerArm64).run_tags.ManagedBy == "ami-forge"
     && (firstBuilder packerArm64).run_tags."ami-forge:purpose" == "ami-build")
    "default run_tags identify the ephemeral builder instance")

  (mkTest "packer-run-tags-name-derived-from-ami-name"
    ((firstBuilder packerArm64).run_tags.Name == "${conventionName}-builder")
    "default run_tags Name = <amiName>-builder")

  (mkTest "packer-run-tags-override-merged"
    ((firstBuilder packerWithRunOverride).run_tags."ami-forge:purpose" == "layer-build"
     && (firstBuilder packerWithRunOverride).run_tags."ami-forge:ttl-hours" == "8"
     && (firstBuilder packerWithRunOverride).run_tags.ManagedBy == "ami-forge")
    "runTagOverrides merge last-wins over defaults")

  # ════════════════════════════════════════════════════════════════════
  # mode="packer" — arch → source AMI filter
  # ════════════════════════════════════════════════════════════════════

  (mkTest "packer-arm64-source-ami-filter"
    ((firstBuilder packerArm64).source_ami_filter.filters.architecture == "arm64")
    "arm64 → source_ami_filter.filters.architecture = arm64")

  (mkTest "packer-x86-source-ami-filter"
    ((firstBuilder packerX86).source_ami_filter.filters.architecture == "x86_64")
    "x86_64 → source_ami_filter.filters.architecture = x86_64")

  (mkTest "packer-arm64-systemtarget-aarch64-linux"
    (packerArm64.resolved.systemTarget == "aarch64-linux")
    "architecture=arm64 → systemTarget=aarch64-linux")

  (mkTest "packer-x86-systemtarget-x86-64-linux"
    (packerX86.resolved.systemTarget == "x86_64-linux")
    "architecture=x86_64 → systemTarget=x86_64-linux")

  (mkTest "packer-arm64-instance-type-default-c7g"
    ((firstBuilder packerArm64).instance_type == "c7g.large")
    "architecture=arm64 → default instance_type = c7g.large (Graviton)")

  (mkTest "packer-x86-instance-type-default-c7i"
    ((firstBuilder packerX86).instance_type == "c7i.large")
    "architecture=x86_64 → default instance_type = c7i.large")

  # ════════════════════════════════════════════════════════════════════
  # mode="packer" — provisioner
  # ════════════════════════════════════════════════════════════════════

  (mkTest "packer-provisioner-runs-nixos-rebuild"
    (let p = firstProvisioner packerArm64;
     in p.type == "shell"
        && builtins.any (l:
          builtins.match ".*nixos-rebuild switch --refresh --flake github:pleme-io/kindling-profiles#ami-builder.*" l != null
        ) p.inline)
    "provisioner runs nixos-rebuild switch --refresh --flake <ref>#<profile>")

  (mkTest "packer-provisioner-github-token-gated"
    (let p = firstProvisioner packerArm64;
     in builtins.any (l:
       builtins.match ".*GITHUB_TOKEN.*access-tokens.*" l != null
     ) p.inline)
    "provisioner conditionally exports GITHUB_TOKEN as nix access-tokens")

  # ════════════════════════════════════════════════════════════════════
  # mode="packer" — amazon-ami-management retention (optional)
  # ════════════════════════════════════════════════════════════════════

  (mkTest "packer-no-mgmt-identifier-by-default"
    (builtins.length packerArm64.packerTemplateValue."post-processors" == 1)
    "no amazon-ami-management post-processor without amiMgmtIdentifier")

  (mkTest "packer-mgmt-identifier-adds-post-processor"
    (builtins.length packerWithMgmt.packerTemplateValue."post-processors" == 2)
    "amiMgmtIdentifier → amazon-ami-management post-processor appended")

  (mkTest "packer-mgmt-identifier-values"
    (let pp = builtins.elemAt packerWithMgmt.packerTemplateValue."post-processors" 1;
     in pp.type == "amazon-ami-management"
        && pp.identifier == "quero-builder"
        && pp.keep_releases == 2)
    "amazon-ami-management post-processor receives identifier + keep_releases")

  # ════════════════════════════════════════════════════════════════════
  # mode="packer" — nixosSystem string vs attr-set
  # ════════════════════════════════════════════════════════════════════

  (mkTest "packer-attr-system-parses"
    (packerAttrSystem.resolved.flakeRef == "github:pleme-io/kindling-profiles"
     && packerAttrSystem.resolved.profile == "k8s-builder")
    "nixosSystem as attr set {flakeRef, profile} parses correctly")

  (mkTest "packer-attr-system-provisioner-uses-k8s-builder"
    (let p = firstProvisioner packerAttrSystem;
     in builtins.any (l:
       builtins.match ".*kindling-profiles#k8s-builder.*" l != null
     ) p.inline)
    "attr-set nixosSystem renders correct flake-ref#profile in provisioner")

  (mkTest "packer-string-system-parses"
    (packerArm64.resolved.flakeRef == "github:pleme-io/kindling-profiles"
     && packerArm64.resolved.profile == "ami-builder")
    "nixosSystem as string \"<ref>#<profile>\" parses correctly")

  # ════════════════════════════════════════════════════════════════════
  # mode="direct" — interface shape (stub implementation)
  # ════════════════════════════════════════════════════════════════════

  (mkTest "direct-returns-mode"
    (direct.mode == "direct")
    "direct mode should preserve mode in output")

  (mkTest "direct-has-package"
    (direct ? package)
    "direct mode exposes .package — the aws-ami-<name> build artifact")

  (mkTest "direct-package-name"
    (direct.packageName == "aws-ami-${conventionName}")
    "direct mode package name follows aws-ami-<amiName> convention")

  (mkTest "direct-has-register-app"
    (direct ? registerApp && direct.registerApp.type == "app")
    "direct mode exposes .registerApp — `nix run` aws ec2 registration")

  (mkTest "direct-register-app-name"
    (direct.registerAppName == "register-aws-ami-${conventionName}")
    "direct register app follows register-aws-ami-<name> naming")

  (mkTest "direct-resolved-same-as-packer"
    (direct.resolved.systemTarget == "aarch64-linux"
     && direct.resolved.flakeRef == "github:pleme-io/kindling-profiles"
     && direct.resolved.profile == "ami-builder")
    "direct mode resolves inputs identically to packer mode")

  # ════════════════════════════════════════════════════════════════════
  # Invariants — behavior shared across modes
  # ════════════════════════════════════════════════════════════════════

  (mkTest "both-modes-preserve-tags"
    (packerArm64.resolved.tags == conventionTags
     && direct.resolved.tags == conventionTags)
    "both modes expose amiTags unchanged under .resolved.tags")

  (mkTest "both-modes-default-snapshot-tags-to-ami-tags"
    (packerArm64.resolved.snapshotTags == conventionTags
     && direct.resolved.snapshotTags == conventionTags)
    "when snapshotTags is null, both modes default to amiTags")
]
