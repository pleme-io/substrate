# Testing

RSpec at ALL abstraction levels. Every typed resource function, every
architecture composition, every live cloud resource -- tested, verified,
gated. Infrastructure is ONLY instantiated after the full RSpec suite passes.

---

## Three-Layer Test Pyramid

Substrate infrastructure follows a three-layer testing strategy that catches
errors early and cheaply before touching real cloud resources.

```
                    ┌───────────────┐
                    │   Layer 3     │  InSpec live verification
                    │  Post-apply   │  (real resources, real cost)
                    ├───────────────┤
                    │   Layer 2     │  RSpec architecture synthesis
                    │  Zero-cost    │  (full config generation, no cloud)
                    ├───────────────┤
                    │   Layer 1     │  RSpec resource unit tests
                    │  Instant      │  (individual functions, pure Ruby)
                    └───────────────┘
```

Each layer catches different classes of defects:

| Layer | What it catches | Cost | Speed |
|-------|----------------|------|-------|
| 1 | Logic errors in resource functions, wrong defaults, missing validations, type enforcement failures | Zero | Milliseconds |
| 2 | Composition errors, missing dependencies, wrong wiring, config drift, security invariant violations across resources | Zero | Seconds |
| 3 | Provider bugs, API incompatibilities, permission errors, real cloud behavior, drift from synthesized state | Cloud cost | Minutes |

**Hard rule:** No layer is optional. All three layers must be present for
every architecture. The test gate (`nix run .#plan`) enforces Layer 1 + 2
before any cloud interaction.

---

## Layer 1: Typed Pangea Resource Function Specs (Deep Dive)

Each `Pangea::Aws::S3Bucket.build(synth, config)` is a typed function.
Its spec tests that:

- **Required parameters are enforced**: missing `kms_key_id` raises
- **Defaults are applied**: `versioning: true`, `public_access_block: true`
- **Tags are propagated**: required tags present on the synthesized resource
- **Encryption is forced**: KMS encryption is not optional
- **Versioning is forced**: cannot create unversioned buckets
- **Public access is blocked**: all four public access block flags default true
- **`sensitive` fields are excluded**: from outputs and state

```ruby
# spec/resources/s3_bucket_spec.rb
require 'spec_helper'

RSpec.describe Pangea::Aws::S3Bucket do
  let(:synth) { Pangea::Synthesizer.new }
  let(:required_tags) do
    { 'ManagedBy' => 'pangea', 'Purpose' => 'test', 'Environment' => 'test', 'Team' => 'platform' }
  end

  describe '.build with valid config' do
    let(:resource) do
      described_class.build(synth, {
        bucket_name: 'test-bucket',
        kms_key_id: 'arn:aws:kms:us-east-1:123:key/abc',
        tags: required_tags,
      })
    end

    it 'creates the resource in the synthesizer' do
      expect(synth.resources).to include_resource_of_type('aws_s3_bucket')
    end

    it 'enables versioning by default' do
      expect(resource[:versioning][:enabled]).to eq(true)
    end

    it 'configures KMS encryption' do
      enc = resource[:server_side_encryption_configuration]
      expect(enc[:rule][:apply_server_side_encryption_by_default][:sse_algorithm]).to eq('aws:kms')
      expect(enc[:rule][:apply_server_side_encryption_by_default][:kms_master_key_id])
        .to eq('arn:aws:kms:us-east-1:123:key/abc')
    end

    it 'blocks all public access' do
      block = resource[:public_access_block]
      expect(block[:block_public_acls]).to eq(true)
      expect(block[:block_public_policy]).to eq(true)
      expect(block[:ignore_public_acls]).to eq(true)
      expect(block[:restrict_public_buckets]).to eq(true)
    end

    it 'sets prevent_destroy lifecycle' do
      expect(resource[:lifecycle][:prevent_destroy]).to eq(true)
    end

    it 'enforces TLS-only bucket policy' do
      policy = resource[:bucket_policy]
      expect(policy[:Statement]).to include(
        hash_including(
          'Effect' => 'Deny',
          'Condition' => hash_including('Bool' => { 'aws:SecureTransport' => 'false' })
        )
      )
    end

    it 'carries all required tags' do
      %w[ManagedBy Purpose Environment Team].each do |tag|
        expect(resource[:tags]).to have_key(tag)
      end
    end
  end

  describe '.build with missing required fields' do
    it 'raises when kms_key_id is missing' do
      expect {
        described_class.build(synth, { bucket_name: 'test', tags: required_tags })
      }.to raise_error(Pangea::ValidationError, /kms_key_id/)
    end

    it 'raises when tags are missing' do
      expect {
        described_class.build(synth, { bucket_name: 'test', kms_key_id: 'arn:...' })
      }.to raise_error(Pangea::ValidationError, /tags/)
    end

    it 'raises when bucket_name is missing' do
      expect {
        described_class.build(synth, { kms_key_id: 'arn:...', tags: required_tags })
      }.to raise_error(Pangea::ValidationError, /bucket_name/)
    end
  end

  describe '.build with edge cases' do
    it 'raises on empty bucket_name' do
      expect {
        described_class.build(synth, { bucket_name: '', kms_key_id: 'arn:...', tags: required_tags })
      }.to raise_error(Pangea::ValidationError, /bucket_name/)
    end

    it 'raises on nil kms_key_id' do
      expect {
        described_class.build(synth, { bucket_name: 'test', kms_key_id: nil, tags: required_tags })
      }.to raise_error(Pangea::ValidationError, /kms_key_id/)
    end

    it 'raises when required tags are incomplete' do
      expect {
        described_class.build(synth, {
          bucket_name: 'test',
          kms_key_id: 'arn:...',
          tags: { 'ManagedBy' => 'pangea' },  # missing Purpose, Environment, Team
        })
      }.to raise_error(Pangea::ValidationError, /tags/)
    end
  end
end
```

### IAM Policy Resource Spec Example

```ruby
# spec/resources/iam_policy_spec.rb
RSpec.describe Pangea::Aws::IamPolicy do
  let(:synth) { Pangea::Synthesizer.new }

  it 'rejects action wildcards' do
    expect {
      described_class.build(synth, {
        name: 'bad-policy',
        statements: [{
          effect: 'Allow',
          actions: ['s3:*'],  # VIOLATION
          resources: ['arn:aws:s3:::bucket'],
        }],
        tags: required_tags,
      })
    }.to raise_error(Pangea::LeastPrivilegeViolation, /s3:\*/)
  end

  it 'rejects resource wildcards' do
    expect {
      described_class.build(synth, {
        name: 'bad-policy',
        statements: [{
          effect: 'Allow',
          actions: ['s3:GetObject'],
          resources: ['*'],  # VIOLATION
        }],
        tags: required_tags,
      })
    }.to raise_error(Pangea::LeastPrivilegeViolation, /\*/)
  end

  it 'accepts explicit actions and resources' do
    expect {
      described_class.build(synth, {
        name: 'good-policy',
        statements: [{
          effect: 'Allow',
          actions: ['s3:GetObject', 's3:PutObject'],
          resources: ['arn:aws:s3:::bucket', 'arn:aws:s3:::bucket/*'],
        }],
        tags: required_tags,
      })
    }.not_to raise_error
  end
end
```

### Rules

- Every resource function gets at least one spec file
- Test security constraints (encryption, access blocks, lifecycle, least-privilege)
- Test default values and required parameters
- Test that required fields raise `ValidationError` when missing
- Test edge cases (empty strings, nil values, missing optional params)
- Test that `sensitive: true` fields are excluded from outputs
- Run with `nix run .#test` or `bundle exec rspec`
- Target: <1 second per resource spec file (pure Ruby, no IO)

---

## Layer 2: Architecture Synthesis Specs (Deep Dive)

An architecture like `Pangea::Architectures::StateBackend.build(synth, config)`
composes typed resource functions (`S3Bucket`, `DynamodbTable`, `IamPolicy`).
Its spec tests that:

- **All resources are created**: every resource the architecture promises exists
- **Cross-references are valid**: bucket ARN appears in IAM policy, KMS key
  wired to both S3 and DynamoDB
- **Security invariants are maintained across composition**: no `*` in any
  IAM policy across the entire architecture, all resources encrypted with
  the same KMS key, no open security groups
- **Output is deterministic**: same config produces same resources every time
- **Tag propagation**: architecture-level tags flow to all child resources

```ruby
# spec/architectures/state_backend_spec.rb
require 'spec_helper'

RSpec.describe Pangea::Architectures::StateBackend do
  let(:synth) { Pangea::Synthesizer.new }
  let(:config) do
    {
      name: 'prod-state',
      bucket: 'pleme-prod-state',
      lock_table: 'pleme-prod-locks',
      kms_key: 'arn:aws:kms:us-east-1:123:key/abc',
      tags: {
        'ManagedBy' => 'pangea',
        'Purpose' => 'state-backend',
        'Environment' => 'production',
        'Team' => 'platform',
      },
    }
  end
  let(:result) { described_class.build(synth, config) }

  describe 'resource presence' do
    it 'creates an S3 bucket' do
      expect(synth.resources).to include_resource_of_type('aws_s3_bucket')
    end

    it 'creates a DynamoDB table' do
      expect(synth.resources).to include_resource_of_type('aws_dynamodb_table')
    end

    it 'creates an IAM policy' do
      expect(synth.resources).to include_resource_of_type('aws_iam_policy')
    end

    it 'returns all three resources' do
      expect(result.keys).to contain_exactly(:bucket, :table, :policy)
    end
  end

  describe 'cross-reference wiring' do
    it 'wires bucket ARN into IAM policy' do
      policy_doc = result[:policy][:policy_document]
      bucket_arn = result[:bucket][:arn]
      resource_arns = policy_doc[:Statement].flat_map { |s| s[:Resource] }
      expect(resource_arns).to include(bucket_arn)
      expect(resource_arns).to include("#{bucket_arn}/*")
    end

    it 'wires table ARN into IAM policy' do
      policy_doc = result[:policy][:policy_document]
      table_arn = result[:table][:arn]
      resource_arns = policy_doc[:Statement].flat_map { |s| s[:Resource] }
      expect(resource_arns).to include(table_arn)
    end

    it 'wires KMS key to S3 bucket' do
      enc = result[:bucket][:server_side_encryption_configuration]
      expect(enc[:rule][:apply_server_side_encryption_by_default][:kms_master_key_id])
        .to eq(config[:kms_key])
    end

    it 'wires KMS key to DynamoDB table' do
      expect(result[:table][:server_side_encryption][:kms_key_arn])
        .to eq(config[:kms_key])
    end
  end

  describe 'security invariants' do
    it 'has no wildcard actions in any IAM policy' do
      synth.resources_of_type('aws_iam_policy').each do |policy|
        policy[:policy_document][:Statement].each do |stmt|
          stmt[:Action].each do |action|
            expect(action).not_to include('*'),
              "IAM policy '#{policy[:name]}' has wildcard action '#{action}'"
          end
        end
      end
    end

    it 'has no wildcard resources in any IAM policy' do
      synth.resources_of_type('aws_iam_policy').each do |policy|
        policy[:policy_document][:Statement].each do |stmt|
          Array(stmt[:Resource]).each do |resource|
            expect(resource).not_to eq('*'),
              "IAM policy '#{policy[:name]}' has wildcard resource"
          end
        end
      end
    end

    it 'has versioning enabled on S3 bucket' do
      expect(result[:bucket][:versioning][:enabled]).to eq(true)
    end

    it 'blocks all public access on S3 bucket' do
      block = result[:bucket][:public_access_block]
      expect(block.values).to all(eq(true))
    end

    it 'sets prevent_destroy on all stateful resources' do
      [result[:bucket], result[:table]].each do |resource|
        expect(resource[:lifecycle][:prevent_destroy]).to eq(true),
          "Resource missing prevent_destroy"
      end
    end

    it 'uses PAY_PER_REQUEST billing for DynamoDB' do
      expect(result[:table][:billing_mode]).to eq('PAY_PER_REQUEST')
    end
  end

  describe 'tag propagation' do
    it 'propagates tags to all resources' do
      synth.resources.each do |resource|
        %w[ManagedBy Purpose Environment Team].each do |tag|
          expect(resource[:tags]).to have_key(tag),
            "#{resource[:type]} '#{resource[:name]}' missing tag '#{tag}'"
        end
      end
    end

    it 'sets correct environment tag' do
      synth.resources.each do |resource|
        expect(resource[:tags]['Environment']).to eq('production')
      end
    end
  end

  describe 'deterministic output' do
    it 'produces identical resources on repeated synthesis' do
      synth2 = Pangea::Synthesizer.new
      result2 = described_class.build(synth2, config)
      expect(result2[:bucket]).to eq(result[:bucket])
      expect(result2[:table]).to eq(result[:table])
      expect(result2[:policy]).to eq(result[:policy])
    end
  end
end
```

### What synthesis tests verify

- All expected resources are present
- Cross-resource references are correct (bucket/table ARNs in IAM policy)
- Security constraints are satisfied across the full architecture
  - No wildcards in IAM (absolute least-privilege)
  - All storage encrypted with correct KMS key
  - All stateful resources have `prevent_destroy`
  - No open security groups
- Tag requirements are met on every resource
- No orphaned resources
- Environment-specific overrides work correctly
- Output is deterministic (same input = same output)

### Key advantage

Synthesis tests run in pure Ruby -- no cloud API calls, no credentials needed,
no cost. They verify the complete resource graph that would be generated for a
real deployment. Architecture composition is lazy -- only resolved when
`.build()` is called, so test setup is instant.

---

## Layer 3: InSpec Live Verification (Deep Dive)

Post-apply verification of real cloud resources using InSpec. These controls
are auto-generated from Layer 2 RSpec assertions -- every `expect(...)` in
synthesis has a corresponding `describe ... do` in InSpec.

### Auto-Generation from RSpec Assertions

The mapping pattern:

| RSpec synthesis assertion | Auto-generated InSpec control |
|--------------------------|-------------------------------|
| `expect(synth.resources).to include_resource_of_type('aws_s3_bucket')` | `describe aws_s3_bucket(bucket_name: input('bucket_name')) { it { should exist } }` |
| `expect(resource[:versioning][:enabled]).to eq(true)` | `it { should have_versioning_enabled }` |
| `expect(enc[:sse_algorithm]).to eq('aws:kms')` | `it { should have_default_encryption_enabled }` |
| `expect(block.values).to all(eq(true))` | `it { should_not be_public }` |
| `expect(resource[:billing_mode]).to eq('PAY_PER_REQUEST')` | `its('billing_mode_summary.billing_mode') { should eq 'PAY_PER_REQUEST' }` |
| `expect(action).not_to include('*')` | `describe aws_iam_policy(...) { its('policy_document') { ... } }` |
| `expect(resource[:lifecycle][:prevent_destroy]).to eq(true)` | `describe aws_s3_bucket(...) { it { should have_versioning_enabled } }` (verified via API) |

### Full InSpec Profile Example

```ruby
# inspec/controls/state_backend.rb

control 'state-backend-s3-exists' do
  impact 1.0
  title 'State backend S3 bucket exists'
  desc 'Mirrors RSpec: expect(synth.resources).to include_resource_of_type(aws_s3_bucket)'

  describe aws_s3_bucket(bucket_name: input('bucket_name')) do
    it { should exist }
  end
end

control 'state-backend-s3-versioning' do
  impact 1.0
  title 'State backend S3 bucket has versioning enabled'
  desc 'Mirrors RSpec: expect(resource[:versioning][:enabled]).to eq(true)'

  describe aws_s3_bucket(bucket_name: input('bucket_name')) do
    it { should have_versioning_enabled }
  end
end

control 'state-backend-s3-encryption' do
  impact 1.0
  title 'State backend S3 bucket uses KMS encryption'
  desc 'Mirrors RSpec: expect(enc[:sse_algorithm]).to eq(aws:kms)'

  describe aws_s3_bucket(bucket_name: input('bucket_name')) do
    it { should have_default_encryption_enabled }
  end
end

control 'state-backend-s3-no-public' do
  impact 1.0
  title 'State backend S3 bucket blocks public access'
  desc 'Mirrors RSpec: expect(block.values).to all(eq(true))'

  describe aws_s3_bucket(bucket_name: input('bucket_name')) do
    it { should_not be_public }
  end
end

control 'state-backend-dynamodb-exists' do
  impact 1.0
  title 'State backend DynamoDB table exists'
  desc 'Mirrors RSpec: expect(synth.resources).to include_resource_of_type(aws_dynamodb_table)'

  describe aws_dynamodb_table(table_name: input('table_name')) do
    it { should exist }
  end
end

control 'state-backend-dynamodb-billing' do
  impact 1.0
  title 'State backend DynamoDB table uses PAY_PER_REQUEST'
  desc 'Mirrors RSpec: expect(resource[:billing_mode]).to eq(PAY_PER_REQUEST)'

  describe aws_dynamodb_table(table_name: input('table_name')) do
    its('billing_mode_summary.billing_mode') { should eq 'PAY_PER_REQUEST' }
  end
end

control 'state-backend-dynamodb-encryption' do
  impact 1.0
  title 'State backend DynamoDB table uses KMS encryption'
  desc 'Mirrors RSpec: expect(resource[:kms_key_arn]).to eq(config[:kms_key])'

  describe aws_dynamodb_table(table_name: input('table_name')) do
    its('sse_description.status') { should eq 'ENABLED' }
    its('sse_description.sse_type') { should eq 'KMS' }
  end
end

control 'state-backend-iam-least-privilege' do
  impact 1.0
  title 'State backend IAM policy uses explicit actions and resources'
  desc 'Mirrors RSpec: expect(action).not_to include(*)'

  describe aws_iam_policy(policy_name: input('policy_name')) do
    it { should exist }
    it { should be_attached }
  end

  # Parse the policy document and verify no wildcards
  policy = aws_iam_policy(policy_name: input('policy_name'))
  policy_doc = JSON.parse(URI.decode_www_form_component(policy.document))

  policy_doc['Statement'].each do |stmt|
    Array(stmt['Action']).each do |action|
      describe "IAM action: #{action}" do
        it 'should not contain wildcards' do
          expect(action).not_to include('*')
        end
      end
    end
    Array(stmt['Resource']).each do |resource|
      describe "IAM resource: #{resource}" do
        it 'should not be a wildcard' do
          expect(resource).not_to eq('*')
        end
      end
    end
  end
end
```

### The `InSpecMirrorable` Trait

Architecture classes that include `InSpecMirrorable` can auto-generate
their InSpec profile from their RSpec assertions:

```ruby
module Pangea::Architectures
  class StateBackend
    include InSpecMirrorable

    # After synthesis, generate InSpec controls:
    def self.to_inspec_profile(synth, config)
      controls = []

      synth.resources.each do |resource|
        controls << inspec_existence_control(resource)
        controls << inspec_encryption_control(resource) if resource[:encrypted]
        controls << inspec_tags_control(resource) if resource[:tags]
      end

      synth.resources_of_type('aws_iam_policy').each do |policy|
        controls << inspec_least_privilege_control(policy)
      end

      InSpecProfile.new(controls)
    end
  end
end
```

### Rules

- InSpec controls mirror RSpec synthesis test assertions
- Every synthesis test that checks a resource property MUST have
  a corresponding InSpec control
- Run post-apply only (never before `plan` or `apply`)
- Use `inspec-akeyless` resource pack for Akeyless-specific verification
- Store InSpec profiles alongside architecture code
- Each InSpec control `desc` field references the RSpec assertion it mirrors
- InSpec controls never read or log secret values -- only verify accessibility

---

## Gated Workspace Pattern (Deep Dive)

Infrastructure workspaces enforce a test gate: the full RSpec suite
MUST pass before `plan` or `apply` can execute. This is not advisory --
it is enforced at the Nix level. There is no way to skip the gate
through normal commands.

```
nix run .#test      # Layer 1 + Layer 2 (must pass)
nix run .#plan      # ALWAYS runs full RSpec suite first, then plan
nix run .#apply     # ALWAYS runs full RSpec suite first, then apply
nix run .#verify    # Layer 3 (post-apply InSpec)
nix run .#deploy    # test -> apply -> verify (full lifecycle)
```

### How the Gate Works

The `gated-pangea-workspace.nix` wraps `pangea-workspace.nix`. The gated
apps are shell scripts that execute the test suite inline before proceeding:

```nix
# Conceptual implementation (simplified):
plan = pkgs.writeShellApplication {
  name = "${name}-plan";
  text = ''
    echo "Running test gate..."
    ${test}/bin/${name}-test || {
      echo "TEST GATE FAILED -- plan aborted"
      exit 1
    }
    echo "Test gate passed. Running plan..."
    ${planUngated}/bin/${name}-plan-ungated "$@"
  '';
};
```

### Available Apps

```nix
# Generated apps from pangea-infra.nix:
apps = {
  test           = ...;  # Full RSpec suite (Layer 1 + Layer 2)
  validate       = ...;  # Pangea config schema validation
  plan           = ...;  # GATED: test -> synthesize -> diff
  apply          = ...;  # GATED: test -> apply changes
  destroy        = ...;  # Destroy (requires explicit confirmation + flag)
  verify         = ...;  # InSpec post-apply verification (Layer 3)
  deploy         = ...;  # GATED: test -> apply -> verify (full lifecycle)
  drift          = ...;  # Detect configuration drift
  regen          = ...;  # Regenerate gemset.nix
  plan-ungated   = ...;  # EMERGENCY ONLY: plan without test gate
};
```

### The Emergency Bypass

`nix run .#plan-ungated` exists for emergencies only. It skips the test gate.
Its use is logged and should trigger an incident review. It exists because
sometimes you need to run a plan during an outage when tests are broken
for unrelated reasons. It should never be used in normal operations.

### SDLC Integration

The test gate integrates with the full infrastructure SDLC:

```
nix run .#test      # Run full RSpec suite (Layer 1 + 2)
nix run .#plan      # Test gate -> terraform plan
nix run .#apply     # Test gate -> terraform apply
nix run .#verify    # InSpec live verification (Layer 3)
nix run .#deploy    # test -> apply -> verify (full lifecycle)
nix run .#drift     # Compare synth vs actual cloud state
```

Every command that touches cloud resources is gated. The gate adds <10 seconds
to plan/apply (pure Ruby RSpec execution). This overhead guarantees
zero-broken-infra deployments.

### Gate Overhead

| Operation | Time | Why |
|-----------|------|-----|
| Test gate (Layer 1) | <1s | Pure Ruby evaluation, no IO |
| Test gate (Layer 2) | <5s | Composition + cross-ref validation |
| Total gate overhead | <10s | Worth it for zero-broken-infra guarantee |
| InSpec verification | 1-5min | Real API calls, run post-apply only |

---

## RSpec-to-InSpec Mirroring

For every RSpec synthesis assertion, create a corresponding InSpec control.
This is the central contract between synthesis (what you intend) and
verification (what actually exists).

### Mapping Table

| RSpec synthesis test | InSpec control |
|---------------------|----------------|
| `expect(synth.resources).to include_resource_of_type('aws_s3_bucket')` | `describe aws_s3_bucket(...) { it { should exist } }` |
| `expect(resource[:versioning][:enabled]).to eq(true)` | `it { should have_versioning_enabled }` |
| `expect(enc[:sse_algorithm]).to eq('aws:kms')` | `it { should have_default_encryption_enabled }` |
| `expect(block.values).to all(eq(true))` | `it { should_not be_public }` |
| `expect(resource[:billing_mode]).to eq('PAY_PER_REQUEST')` | `its('billing_mode') { should eq 'PAY_PER_REQUEST' }` |
| `expect(synth.resources).to include_resource_of_type('aws_kms_key')` | `describe aws_kms_key(...) { it { should exist } }` |
| `expect(action).not_to include('*')` | Custom control parsing IAM policy document |
| `expect(resource[:lifecycle][:prevent_destroy]).to eq(true)` | Verified indirectly (resource exists post-apply) |
| `expect(resource[:tags]).to have_key('ManagedBy')` | `its('tags') { should include('ManagedBy' => expected_value) }` |

### Mirroring Guarantees

This mirroring ensures that:
1. What you synthesize is what you verify -- no drift between intent and reality
2. Drift between synthesis and cloud state is detected immediately
3. Security properties are verified at both layers independently
4. Every assertion has a paper trail (InSpec `desc` references the RSpec assertion)
5. Auto-generation via `InSpecMirrorable` keeps the mapping in sync

---

## Trait Boundaries for Testability

Ruby modules/mixins define the trait boundaries that make Pangea resource
functions and architectures testable, mockable, composable, and secure.

### Core Traits

| Trait (Module) | Methods | Purpose |
|----------------|---------|---------|
| `Synthesizable` | `#build(synth, config)` | Can be rendered to HCL resources via a synthesizer |
| `Validatable` | `#validate!(config)` | Schema-checked before synthesis; raises on invalid |
| `Composable` | `#compose(synth, children)` | Can be nested inside architecture functions |
| `Mockable` | `#stub_dependencies`, `#with_mock(dep, mock)` | Supports dependency injection for unit testing |
| `SecurityEnforced` | `#enforce_required_tags`, `#enforce_encryption`, `#enforce_least_privilege` | Security constraints validated at type level |
| `InSpecMirrorable` | `#to_inspec_control`, `#to_inspec_profile` | Auto-generate InSpec controls from RSpec assertions |

### How Traits Enable Testing

```ruby
# Mockable trait enables isolated unit testing:
RSpec.describe Pangea::Architectures::StateBackend do
  let(:mock_synth) { Pangea::MockSynthesizer.new }
  let(:mock_s3) { instance_double(Pangea::Aws::S3Bucket) }

  before do
    allow(Pangea::Aws::S3Bucket).to receive(:build).and_return(mock_s3)
  end

  it 'calls S3Bucket.build with correct config' do
    expect(Pangea::Aws::S3Bucket).to receive(:build).with(
      mock_synth,
      hash_including(bucket_name: 'test-bucket')
    )
    described_class.build(mock_synth, config)
  end
end

# Validatable trait enables validation testing:
RSpec.describe Pangea::Aws::S3Bucket do
  include Pangea::Validatable

  it 'validates config schema before build' do
    expect { described_class.validate!({}) }
      .to raise_error(Pangea::ValidationError)
  end
end

# SecurityEnforced trait enables security testing:
RSpec.describe Pangea::Aws::IamPolicy do
  include Pangea::SecurityEnforced

  it 'enforces least privilege at the type level' do
    expect { described_class.enforce_least_privilege(wildcard_config) }
      .to raise_error(Pangea::LeastPrivilegeViolation)
  end
end
```

### Performance Implications

- `Synthesizable`: Pure Ruby evaluation -- <1ms per resource
- `Validatable`: Schema check -- <1ms per validation
- `Composable`: Lazy resolution -- only resolved when `.build()` is called
- `Mockable`: Dependency injection -- no IO, instant stubbing
- `SecurityEnforced`: Pure assertion -- <1ms per check
- `InSpecMirrorable`: Profile generation -- <100ms per architecture

Total: synthesis tests run in <1s for typical architectures (5-20 resources).
Architecture composition tests run in <5s for complex compositions (50+ resources).

---

## Nix Evaluation Tests

For Nix modules (NixOS, home-manager), substrate provides pure evaluation
tests via `util/test-helpers.nix`:

```nix
testHelpers = import "${substrate}/lib/util/test-helpers.nix" { lib = nixpkgs.lib; };

tests = testHelpers.runTests [
  (testHelpers.mkTest "service-enabled"
    (module.config.systemd.services.myapp.enable == true)
    "myapp service should be enabled")

  (testHelpers.mkTest "port-configured"
    (module.config.systemd.services.myapp.serviceConfig.ExecStart
      == "${pkg}/bin/myapp --port 8080")
    "myapp should listen on port 8080")
];
```

These tests run as pure Nix evaluation -- no VMs, no builds, instant results.
Use for:
- NixOS module option validation
- home-manager module configuration checks
- Profile evaluation (blackmatter profiles)

---

## Test Infrastructure Repos

| Repo | Purpose | Tests |
|------|---------|-------|
| `pangea-architectures` | Reusable infra compositions with RSpec synthesis tests | 118 |
| `inspec-akeyless` | InSpec resource pack for Akeyless verification | 62 |
| `iac-test-runner` | K8s bringup/verify/teardown orchestrator | 180 |

---

## CI Integration

Tests run automatically in CI via Nix:

```bash
# In GitHub Actions / forge pipeline:
nix run .#test              # All RSpec tests
nix run .#validate          # Pangea validation
nix flake check             # Nix evaluation checks
nix run .#test:unit         # Unit tests only
nix run .#test:integration  # Integration tests only
```

The `productSdlcApps` from `service/product-sdlc.nix` provides a standard
set of test commands for product repos:
- `test` -- all tests
- `test:unit` -- unit tests
- `test:integration` -- integration tests
- `test:e2e` -- end-to-end tests
- `test:ci` -- CI-optimized test suite
- `test:coverage` -- tests with coverage reporting
- `bench` -- benchmarks
