---
name: pangea-infrastructure
description: Security-first infrastructure patterns -- typed Pangea resources, architecture composition, test pyramid, gated workspaces
domain: infrastructure
triggers:
  - pangea
  - infrastructure
  - state backend
  - infra workspace
  - terraform
  - inspec
  - rspec
  - architecture synthesis
  - prevent_destroy
  - kms
  - iam
  - gated workspace
---

# Pangea Infrastructure Skill

Security-first infrastructure patterns using substrate's `lib/infra/` module.
All infrastructure is typed Ruby code with mandatory security constraints,
tested at three layers, and gated on test passage before any cloud operation.

## Security-First Principles

These are non-negotiable defaults. Infrastructure that violates them will not
pass synthesis tests.

### Absolute Least-Privilege

```ruby
# CORRECT: specific actions, specific resources
iam_policy "s3-reader" do
  actions ["s3:GetObject", "s3:ListBucket"]
  resources ["arn:aws:s3:::my-bucket", "arn:aws:s3:::my-bucket/*"]
end

# WRONG: wildcards -- will fail tests
iam_policy "admin" do
  actions ["s3:*"]
  resources ["*"]
end
```

Rules:
- Every service gets its own IAM role (no shared roles)
- Trust policies explicitly list allowed principals
- No wildcards in resource ARNs or actions
- Cross-account access requires explicit `sts:AssumeRole` with `ExternalId`

### KMS Encryption on All Storage

Every S3 bucket and DynamoDB table must use a dedicated KMS key:

```ruby
s3_bucket "state" do
  versioning true
  encryption :kms
  kms_key_id kms_key.arn           # dedicated key, never aws/s3 default
  public_access_block do
    block_public_acls true
    block_public_policy true
    ignore_public_acls true
    restrict_public_buckets true
  end
  lifecycle_rule do
    prevent_destroy true
  end
end
```

### prevent_destroy on All Stateful Resources

All databases, S3 buckets, DynamoDB tables, KMS keys, EBS volumes, and EFS
file systems must have `prevent_destroy`. Destroying a protected resource
requires:
1. Explicitly removing `prevent_destroy` in a separate commit
2. PR review from a platform team member
3. Documented justification

### Required Tags

Every resource must carry:

| Tag | Purpose | Example |
|-----|---------|---------|
| `ManagedBy` | Tool managing the resource | `pangea`, `terraform`, `flux` |
| `Purpose` | What the resource is for | `state-backend`, `app-database` |
| `Environment` | Deployment environment | `production`, `staging`, `test` |
| `Team` | Owning team | `platform`, `product` |

### Secrets Management

- Never in Nix store (`/nix/store` is world-readable)
- Never in Terraform/Pangea state
- Reference by path, not value
- Use Akeyless dynamic producers with automatic rotation
- tameshi hashes secret VALUES (BLAKE3) into the deployment chain without storing them

## Typed Pangea Resource Functions

Resource functions are typed Ruby methods that enforce security constraints
at the type level. Missing required fields cause test failures, not runtime
errors.

```ruby
# lib/resources.rb
module Resources
  def self.kms_key(name)
    {
      type: :kms_key,
      name: name,
      enable_key_rotation: true,
      deletion_window_in_days: 30,
      lifecycle: { prevent_destroy: true },
      tags: default_tags.merge("Purpose" => "encryption")
    }
  end

  def self.s3_bucket(name, region, kms_key_id:)
    {
      type: :s3_bucket,
      name: name,
      region: region,
      versioning: true,
      encryption: :kms,
      kms_key_id: kms_key_id,
      public_access_block: {
        block_public_acls: true,
        block_public_policy: true,
        ignore_public_acls: true,
        restrict_public_buckets: true
      },
      lifecycle: { prevent_destroy: true },
      tags: default_tags.merge("Purpose" => "state-storage")
    }
  end

  def self.dynamodb_table(name, kms_key_id:)
    {
      type: :dynamodb_table,
      name: name,
      billing_mode: "PAY_PER_REQUEST",
      encryption: :kms,
      kms_key_id: kms_key_id,
      point_in_time_recovery: true,
      lifecycle: { prevent_destroy: true },
      tags: default_tags.merge("Purpose" => "state-locking")
    }
  end

  def self.default_tags
    {
      "ManagedBy" => "pangea",
      "Environment" => "production",
      "Team" => "platform"
    }
  end
end
```

## Architecture Composition

An architecture is a reusable composition of typed resource functions. It
synthesizes the complete resource graph in pure Ruby.

```ruby
# lib/architectures/state_backend.rb
module Architectures
  class StateBackend
    def initialize(workspace:, region: "us-east-1")
      @workspace = workspace
      @region = region
    end

    def synthesize
      resources = []

      # KMS key for encryption (shared by bucket and table)
      kms = Resources.kms_key("#{@workspace}-state-key")
      resources << kms

      # S3 bucket for state storage
      resources << Resources.s3_bucket(
        "#{@workspace}-state", @region,
        kms_key_id: kms[:arn]
      )

      # DynamoDB table for state locking
      resources << Resources.dynamodb_table(
        "#{@workspace}-locks",
        kms_key_id: kms[:arn]
      )

      resources
    end
  end
end
```

Key patterns:
- Architecture classes take workspace and region as constructor args
- `synthesize` returns the full resource list
- Resources reference each other via ARNs (typed wiring)
- Security is built in at every resource function -- it cannot be skipped

## RSpec Test Pyramid

### Layer 1: Resource Unit Tests

Test individual resource functions in isolation. Instant, zero cost.

```ruby
# spec/resources/s3_bucket_spec.rb
RSpec.describe "s3_bucket resource" do
  let(:resource) { Resources.s3_bucket("test-bucket", "us-east-1",
    kms_key_id: "arn:aws:kms:us-east-1:123:key/abc") }

  it "enables versioning" do
    expect(resource[:versioning]).to eq(true)
  end

  it "uses KMS encryption" do
    expect(resource[:encryption]).to eq(:kms)
  end

  it "blocks all public access" do
    block = resource[:public_access_block]
    expect(block[:block_public_acls]).to eq(true)
    expect(block[:block_public_policy]).to eq(true)
    expect(block[:ignore_public_acls]).to eq(true)
    expect(block[:restrict_public_buckets]).to eq(true)
  end

  it "sets prevent_destroy" do
    expect(resource[:lifecycle][:prevent_destroy]).to eq(true)
  end
end
```

### Layer 2: Architecture Synthesis Tests

Test full compositions. Verify cross-resource wiring. Zero cloud cost.

```ruby
# spec/architectures/state_backend_spec.rb
RSpec.describe Architectures::StateBackend do
  let(:arch) { described_class.new(workspace: "test", region: "us-east-1") }
  let(:resources) { arch.synthesize }

  describe "resource presence" do
    it "creates a KMS key" do
      expect(resources).to include_resource_of_type(:kms_key)
    end

    it "creates an S3 bucket" do
      expect(resources).to include_resource_of_type(:s3_bucket)
    end

    it "creates a DynamoDB table" do
      expect(resources).to include_resource_of_type(:dynamodb_table)
    end
  end

  describe "encryption wiring" do
    let(:kms) { resources.find_by_type(:kms_key) }

    it "wires KMS key to S3 bucket" do
      bucket = resources.find_by_type(:s3_bucket)
      expect(bucket[:kms_key_id]).to eq(kms[:arn])
    end

    it "wires KMS key to DynamoDB table" do
      table = resources.find_by_type(:dynamodb_table)
      expect(table[:kms_key_id]).to eq(kms[:arn])
    end
  end

  describe "security" do
    it "sets prevent_destroy on all stateful resources" do
      stateful = resources.select { |r|
        [:s3_bucket, :dynamodb_table, :kms_key].include?(r[:type])
      }
      stateful.each do |r|
        expect(r[:lifecycle][:prevent_destroy]).to eq(true),
          "#{r[:type]} #{r[:name]} missing prevent_destroy"
      end
    end

    it "tags all resources" do
      resources.each do |r|
        %w[ManagedBy Purpose Environment Team].each do |tag|
          expect(r[:tags]).to have_key(tag),
            "#{r[:type]} #{r[:name]} missing tag: #{tag}"
        end
      end
    end
  end
end
```

### Security-Specific Tests

Always test these security properties:

```ruby
describe "security constraints" do
  it "no wildcard IAM actions" do
    iam = resources.select { |r| r[:type] == :iam_policy }
    iam.each do |policy|
      policy[:actions].each do |action|
        expect(action).not_to include("*"),
          "#{policy[:name]} has wildcard action: #{action}"
      end
    end
  end

  it "no wildcard IAM resources" do
    iam = resources.select { |r| r[:type] == :iam_policy }
    iam.each do |policy|
      policy[:resources].each do |resource|
        expect(resource).not_to eq("*"),
          "#{policy[:name]} has wildcard resource"
      end
    end
  end
end
```

## Gated Workspace Pattern

Tests must pass before plan or apply can execute. The substrate Pangea
builders enforce this ordering.

```bash
nix run .#test      # Layer 1 + Layer 2 (must pass)
nix run .#plan      # Only runs if test passed
nix run .#apply     # Only runs if test passed
nix run .#verify    # Layer 3 (post-apply InSpec)
nix run .#drift     # Detect configuration drift
nix run .#destroy   # Explicit confirmation required
```

### Setting up a gated workspace

```nix
# flake.nix
outputs = (import "${substrate}/lib/infra/pangea-infra-flake.nix" {
  inherit nixpkgs ruby-nix flake-utils substrate forge;
}) { inherit self; name = "my-infra"; };
```

This produces all the gated apps above. The `pangea-infra.nix` builder
generates shell scripts that enforce ordering.

### Workspace configuration (shikumi pattern)

Configuration flows through Nix evaluation, not shell scripts:

```nix
pangeaWorkspace = import "${substrate}/lib/infra/pangea-workspace.nix" {
  inherit pkgs;
};

workspaceConfig = pangeaWorkspace {
  name = "state-backend";
  architecture = "state_backend";
  awsProfile = "akeyless-development";
  namespace = "production";
  stateBackend = { type = "local"; };
  providers.aws = { region = "us-east-1"; version = "~> 5.0"; };
};
```

This generates a `pangea.yml` YAML file that the Pangea Ruby DSL reads at
runtime. No shell business logic between Nix and application.

## InSpec Auto-Generation from RSpec Assertions

For every RSpec synthesis assertion, create a corresponding InSpec control.
This ensures what you synthesize is what you verify.

### Mirroring table

| RSpec synthesis test | InSpec control |
|---------------------|----------------|
| `expect(resource[:versioning]).to eq(true)` | `it { should have_versioning_enabled }` |
| `expect(resource[:encryption]).to eq(:kms)` | `it { should have_default_encryption_enabled }` |
| `expect(resource[:billing_mode]).to eq("PAY_PER_REQUEST")` | `its("billing_mode") { should eq "PAY_PER_REQUEST" }` |
| `expect(resources).to include_resource_of_type(:kms_key)` | `describe aws_kms_key(...) { it { should exist } }` |

### InSpec controls

```ruby
# inspec/controls/state_backend.rb
control "state-backend-kms" do
  impact 1.0
  title "State backend KMS key exists and is enabled"

  describe aws_kms_key(key_id: input("kms_key_id")) do
    it { should exist }
    it { should be_enabled }
  end
end

control "state-backend-s3" do
  impact 1.0
  title "State backend S3 bucket is secure"

  describe aws_s3_bucket(bucket_name: input("bucket_name")) do
    it { should exist }
    it { should have_versioning_enabled }
    it { should have_default_encryption_enabled }
    it { should_not be_public }
  end
end

control "state-backend-dynamodb" do
  impact 1.0
  title "State backend DynamoDB table exists"

  describe aws_dynamodb_table(table_name: input("table_name")) do
    it { should exist }
    its("billing_mode_summary.billing_mode") { should eq "PAY_PER_REQUEST" }
  end
end
```

Use `inspec-akeyless` resource pack for Akeyless-specific verification.

## SDLC Nix Apps

The full infrastructure SDLC is exposed as nix apps:

| App | What it does |
|-----|-------------|
| `nix run .#test` | RSpec unit + synthesis tests (Layer 1 + 2) |
| `nix run .#validate` | Pangea config validation |
| `nix run .#plan` | Synthesize + diff (gated on test) |
| `nix run .#apply` | Apply changes to cloud (gated on test) |
| `nix run .#verify` | InSpec post-apply verification (Layer 3) |
| `nix run .#drift` | Detect config drift (plan in CI mode) |
| `nix run .#destroy` | Destroy resources (explicit confirmation) |
| `nix run .#regen` | Regenerate Gemfile.lock + gemset.nix |

## Creating a New Architecture -- Checklist

Full guide: `docs/adding-an-architecture.md`

1. Define architecture class in `pangea-architectures/lib/architectures/`
2. Write typed resource functions with all security fields
3. Write RSpec unit tests for each resource function (Layer 1)
4. Write RSpec synthesis tests for full architecture (Layer 2)
5. Create consumer flake with `pangea-infra-flake.nix`
6. Generate workspace config via `pangea-workspace.nix` (shikumi pattern)
7. Write InSpec controls mirroring RSpec assertions (Layer 3)
8. Verify test gate: `nix run .#test` must pass before `plan`/`apply`
9. Verify all resources have required tags
10. Verify `prevent_destroy` on all stateful resources
11. Verify KMS encryption on all storage

## Related Repos

| Repo | Purpose | Tests |
|------|---------|-------|
| `pangea-architectures` | Reusable infra compositions with RSpec synthesis tests | 118 |
| `inspec-akeyless` | InSpec resource pack for Akeyless verification | 62 |
| `iac-test-runner` | K8s bringup/verify/teardown orchestrator | 180 |
| `pangea-core` | Foundation DSL -- ResourceBuilder, types, validation | -- |
| `pangea-aws` | AWS provider (448 resources, auto-generated) | -- |
| `pangea-akeyless` | Akeyless provider (122 resources, auto-generated) | -- |
