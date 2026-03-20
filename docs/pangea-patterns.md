# Pangea Infrastructure Patterns

The definitive reference for typed Pangea infrastructure patterns.
Every infrastructure composition in the pleme-io ecosystem follows
these patterns. This document is the source of truth.

---

## Core Philosophy

1. **Architectures are typed Ruby functions** that compose typed resource functions.
2. **Security is enforced at the type level** -- insecure configurations
   cannot be expressed.
3. **RSpec at ALL abstraction levels** -- resource functions, architectures,
   compositions.
4. **Auto-generated InSpec suites** mirror RSpec assertions for live verification.
5. **SDLC Nix apps gate on tests** -- infrastructure ONLY instantiated after
   full RSpec passes.
6. **Optimize for trait boundaries, mockability, testability, re-usability,
   abstraction, performance** -- applied to both Ruby (Pangea) and Nix patterns.

---

## Typed Resource Functions

Every resource function is typed, validated, and security-enforced.
Resource functions are the atoms of infrastructure -- they produce a single
cloud resource with all security constraints baked in.

### Anatomy of a Resource Function

```ruby
module Pangea
  module Aws
    class S3Bucket
      include Synthesizable
      include Validatable
      include SecurityEnforced
      include Mockable
      include InSpecMirrorable

      # Required fields -- not optional. Security is not a parameter you can skip.
      REQUIRED = [:bucket_name, :kms_key_id, :tags].freeze

      # Secure defaults -- always applied. You get security for free.
      DEFAULTS = {
        versioning: true,            # always on -- protects against accidental deletes
        public_access_block: true,   # always blocked -- no public buckets ever
        prevent_destroy: true,       # stateful = protected -- no accidental deletion
        force_ssl: true,             # bucket policy denies non-TLS
        access_logging: true,        # audit trail
      }.freeze

      # Build: validate -> synthesize -> return resource reference
      def self.build(synth, config)
        validate!(config)

        merged = DEFAULTS.merge(config)

        synth.resource('aws_s3_bucket', merged[:bucket_name], {
          bucket: merged[:bucket_name],

          versioning: {
            enabled: merged[:versioning],
          },

          server_side_encryption_configuration: {
            rule: {
              apply_server_side_encryption_by_default: {
                sse_algorithm: 'aws:kms',
                kms_master_key_id: merged[:kms_key_id],
              },
            },
          },

          public_access_block: merged[:public_access_block] ? {
            block_public_acls: true,
            block_public_policy: true,
            ignore_public_acls: true,
            restrict_public_buckets: true,
          } : nil,

          bucket_policy: merged[:force_ssl] ? {
            Statement: [{
              'Effect' => 'Deny',
              'Principal' => '*',
              'Action' => 's3:*',
              'Resource' => ["arn:aws:s3:::#{merged[:bucket_name]}/*"],
              'Condition' => { 'Bool' => { 'aws:SecureTransport' => 'false' } },
            }],
          } : nil,

          lifecycle: {
            prevent_destroy: merged[:prevent_destroy],
          },

          tags: enforce_required_tags(merged[:tags]),
        })
      end

      # Validation: fail fast before synthesis
      def self.validate!(config)
        REQUIRED.each do |key|
          value = config[key]
          raise Pangea::ValidationError, "Required field :#{key} missing for S3Bucket" if value.nil?
          raise Pangea::ValidationError, "Required field :#{key} cannot be empty for S3Bucket" if value.respond_to?(:empty?) && value.empty?
        end
        validate_required_tags!(config[:tags])
      end

      private

      def self.validate_required_tags!(tags)
        %w[ManagedBy Purpose Environment Team].each do |tag|
          raise Pangea::ValidationError, "Missing required tag '#{tag}' in tags" unless tags&.key?(tag)
        end
      end

      def self.enforce_required_tags(tags)
        validate_required_tags!(tags)
        tags
      end
    end
  end
end
```

### What Makes This Different

1. **`kms_key_id` is REQUIRED** -- you cannot create an unencrypted bucket.
   There is no `encryption: false` option. The type system prevents it.
2. **Secure defaults are always applied** -- `versioning: true`,
   `public_access_block: true`, `prevent_destroy: true`. You opt OUT of
   security, never opt in.
3. **`validate!` runs before synthesis** -- fast-fail on missing fields,
   empty strings, incomplete tags. No half-synthesized resources.
4. **Tags are enforced** -- the function refuses to produce a resource
   without `ManagedBy`, `Purpose`, `Environment`, `Team`.

### Other Resource Function Examples

```ruby
# DynamoDB table -- same pattern
module Pangea::Aws
  class DynamodbTable
    include Synthesizable, Validatable, SecurityEnforced, Mockable, InSpecMirrorable

    REQUIRED = [:name, :hash_key, :kms_key_id, :tags].freeze
    DEFAULTS = {
      billing_mode: 'PAY_PER_REQUEST',
      point_in_time_recovery: true,
      prevent_destroy: true,
    }.freeze

    def self.build(synth, config)
      validate!(config)
      merged = DEFAULTS.merge(config)
      synth.resource('aws_dynamodb_table', merged[:name], {
        name: merged[:name],
        hash_key: merged[:hash_key],
        billing_mode: merged[:billing_mode],
        point_in_time_recovery: { enabled: merged[:point_in_time_recovery] },
        server_side_encryption: { enabled: true, kms_key_arn: merged[:kms_key_id] },
        lifecycle: { prevent_destroy: merged[:prevent_destroy] },
        tags: enforce_required_tags(merged[:tags]),
      })
    end
  end
end

# IAM Policy -- least-privilege enforced at type level
module Pangea::Aws
  class IamPolicy
    include Synthesizable, Validatable, SecurityEnforced, Mockable, InSpecMirrorable

    REQUIRED = [:name, :statements, :tags].freeze

    def self.build(synth, config)
      validate!(config)
      enforce_least_privilege!(config[:statements])
      synth.resource('aws_iam_policy', config[:name], {
        name: config[:name],
        policy_document: {
          Version: '2012-10-17',
          Statement: config[:statements].map { |s| normalize_statement(s) },
        },
        tags: enforce_required_tags(config[:tags]),
      })
    end

    def self.enforce_least_privilege!(statements)
      statements.each do |stmt|
        stmt[:actions].each do |action|
          if action.include?('*')
            raise Pangea::LeastPrivilegeViolation,
              "Action wildcard '#{action}' violates least-privilege policy. " \
              "List each action individually."
          end
        end
        stmt[:resources].each do |resource|
          if resource == '*'
            raise Pangea::LeastPrivilegeViolation,
              "Resource wildcard '*' violates least-privilege policy. " \
              "Use explicit resource ARNs."
          end
        end
      end
    end
  end
end

# Security Group -- default-deny enforced at type level
module Pangea::Aws
  class SecurityGroup
    include Synthesizable, Validatable, SecurityEnforced, Mockable, InSpecMirrorable

    REQUIRED = [:name, :tags].freeze
    DEFAULTS = {
      ingress_rules: [],   # default: deny all ingress
      egress_rules: [],    # default: deny all egress
    }.freeze

    def self.build(synth, config)
      validate!(config)
      enforce_network_isolation!(config)
      merged = DEFAULTS.merge(config)
      synth.resource('aws_security_group', merged[:name], {
        name: merged[:name],
        ingress: merged[:ingress_rules],
        egress: merged[:egress_rules],
        tags: enforce_required_tags(merged[:tags]),
      })
    end

    def self.enforce_network_isolation!(config)
      (config[:ingress_rules] || []).each do |rule|
        if rule[:cidr_blocks]&.include?('0.0.0.0/0') && rule[:port] == 0
          raise Pangea::NetworkIsolationViolation,
            "Open ingress (0.0.0.0/0 on all ports) violates network isolation policy"
        end
      end
    end
  end
end
```

---

## Typed Architecture Functions

Architectures are typed Ruby functions that compose typed resource functions.
Each architecture:

- Validates its configuration before synthesis
- Composes child resource functions (each enforcing its own invariants)
- Adds cross-resource invariants (wiring, tag propagation)
- Returns a hash of resource references for further composition

### Full Architecture Example

```ruby
module Pangea
  module Architectures
    class StateBackend
      include Synthesizable
      include Composable
      include SecurityEnforced
      include InSpecMirrorable

      REQUIRED_CONFIG = [:name, :bucket, :lock_table, :kms_key, :tags].freeze

      def self.build(synth, config)
        validate_config!(config)

        # Compose typed resource functions -- each enforces its own invariants
        bucket = Pangea::Aws::S3Bucket.build(synth, {
          bucket_name: config[:bucket],
          kms_key_id: config[:kms_key],
          tags: config[:tags],
        })

        table = Pangea::Aws::DynamodbTable.build(synth, {
          name: config[:lock_table],
          hash_key: 'LockID',
          billing_mode: 'PAY_PER_REQUEST',
          kms_key_id: config[:kms_key],
          tags: config[:tags],
        })

        # IAM policy with EXPLICIT actions and EXPLICIT resource ARNs
        # ARNs come from resource outputs -- never hardcoded
        policy = Pangea::Aws::IamPolicy.build(synth, {
          name: "#{config[:name]}-access",
          statements: [{
            effect: 'Allow',
            actions: ['s3:GetObject', 's3:PutObject', 's3:ListBucket'],
            resources: [bucket.arn, "#{bucket.arn}/*"],  # explicit ARNs, never *
          }, {
            effect: 'Allow',
            actions: ['dynamodb:GetItem', 'dynamodb:PutItem', 'dynamodb:DeleteItem'],
            resources: [table.arn],  # explicit ARN, never *
          }],
          tags: config[:tags],
        })

        { bucket: bucket, table: table, policy: policy }
      end

      private

      def self.validate_config!(config)
        REQUIRED_CONFIG.each do |key|
          raise Pangea::ValidationError, "Missing required config: #{key}" unless config.key?(key)
        end
        validate_required_tags!(config[:tags])
      end

      def self.validate_required_tags!(tags)
        %w[ManagedBy Purpose Environment Team].each do |tag|
          raise Pangea::ValidationError, "Missing required tag: #{tag}" unless tags&.key?(tag)
        end
      end
    end
  end
end
```

### Architecture Composition (Architectures Composing Architectures)

Architectures can compose other architectures for higher-level abstractions:

```ruby
module Pangea
  module Architectures
    class ProductInfrastructure
      include Synthesizable, Composable, SecurityEnforced, InSpecMirrorable

      def self.build(synth, config)
        validate_config!(config)

        # Compose the state backend architecture
        state = StateBackend.build(synth, {
          name: "#{config[:product]}-state",
          bucket: "#{config[:product]}-tf-state",
          lock_table: "#{config[:product]}-tf-locks",
          kms_key: config[:kms_key],
          tags: config[:tags],
        })

        # Compose a database architecture
        database = DatabaseCluster.build(synth, {
          name: "#{config[:product]}-db",
          engine: 'aurora-postgresql',
          kms_key: config[:kms_key],
          tags: config[:tags],
        })

        # Compose networking
        network = VpcArchitecture.build(synth, {
          name: "#{config[:product]}-vpc",
          cidr: config[:vpc_cidr],
          tags: config[:tags],
        })

        { state: state, database: database, network: network }
      end
    end
  end
end
```

---

## RSpec at Every Level

### Level 1: Resource Function Specs

Test individual resource functions in isolation. Each function has its own
spec file. Tests verify:

- Required parameters enforced (missing raises `ValidationError`)
- Defaults applied (versioning, encryption, access blocks)
- Tags propagated
- Security constraints enforced at type level
- Edge cases (empty strings, nil values)

```ruby
# spec/resources/s3_bucket_spec.rb
RSpec.describe Pangea::Aws::S3Bucket do
  let(:synth) { Pangea::Synthesizer.new }
  let(:valid_config) do
    { bucket_name: 'test', kms_key_id: 'arn:...', tags: required_tags }
  end

  it 'creates a resource with secure defaults' do
    resource = described_class.build(synth, valid_config)
    expect(resource[:versioning][:enabled]).to eq(true)
    expect(resource[:public_access_block].values).to all(eq(true))
    expect(resource[:lifecycle][:prevent_destroy]).to eq(true)
  end

  it 'raises on missing kms_key_id' do
    expect { described_class.build(synth, valid_config.except(:kms_key_id)) }
      .to raise_error(Pangea::ValidationError, /kms_key_id/)
  end

  it 'raises on missing tags' do
    expect { described_class.build(synth, valid_config.except(:tags)) }
      .to raise_error(Pangea::ValidationError, /tags/)
  end
end
```

### Level 2: Architecture Synthesis Specs

Test architecture composition. Tests verify:

- All expected resources created
- Cross-references valid (ARNs flow correctly between resources)
- Security invariants maintained across the entire composition
- Deterministic output
- Tag propagation to all children

```ruby
# spec/architectures/state_backend_spec.rb
RSpec.describe Pangea::Architectures::StateBackend do
  let(:synth) { Pangea::Synthesizer.new }
  let(:result) { described_class.build(synth, config) }

  it 'creates S3 bucket, DynamoDB table, and IAM policy' do
    result
    expect(synth.resources.map { |r| r[:type] })
      .to contain_exactly('aws_s3_bucket', 'aws_dynamodb_table', 'aws_iam_policy')
  end

  it 'wires bucket ARN into IAM policy' do
    arns = result[:policy][:policy_document][:Statement].flat_map { |s| Array(s[:Resource]) }
    expect(arns).to include(result[:bucket].arn)
  end

  it 'has no wildcards in any IAM policy' do
    synth.resources_of_type('aws_iam_policy').each do |p|
      p[:policy_document][:Statement].each do |s|
        s[:Action].each { |a| expect(a).not_to include('*') }
      end
    end
  end
end
```

### Level 3: Integration Specs (Multiple Architectures)

Test that multiple architectures compose correctly at a higher level:

```ruby
# spec/compositions/product_infra_spec.rb
RSpec.describe Pangea::Architectures::ProductInfrastructure do
  let(:synth) { Pangea::Synthesizer.new }
  let(:result) { described_class.build(synth, product_config) }

  it 'creates state backend resources' do
    expect(result[:state].keys).to contain_exactly(:bucket, :table, :policy)
  end

  it 'creates database resources' do
    expect(result[:database]).to be_a(Hash)
  end

  it 'uses the same KMS key across all sub-architectures' do
    kms_refs = synth.resources
      .select { |r| r[:kms_key_id] || r.dig(:server_side_encryption, :kms_key_arn) }
      .map { |r| r[:kms_key_id] || r.dig(:server_side_encryption, :kms_key_arn) }
      .uniq
    expect(kms_refs.length).to eq(1), "Expected single KMS key, got: #{kms_refs}"
  end

  it 'has no wildcards in any IAM policy across all sub-architectures' do
    synth.resources_of_type('aws_iam_policy').each do |p|
      p[:policy_document][:Statement].each do |s|
        s[:Action].each { |a| expect(a).not_to include('*') }
        Array(s[:Resource]).each { |r| expect(r).not_to eq('*') }
      end
    end
  end
end
```

---

## Trait Boundaries (Ruby Modules)

Traits define the contract that resource functions and architectures must
satisfy. They enable testability, mockability, composability, and security
enforcement.

### `Synthesizable`

Can produce HCL resources via a synthesizer.

```ruby
module Pangea
  module Synthesizable
    # Contract: self.build(synth, config) -> resource reference
    # The synth accumulates resources; the return value is a reference.
  end
end
```

### `Validatable`

Schema-checked before synthesis. Fails fast on invalid input.

```ruby
module Pangea
  module Validatable
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def validate!(config)
        self::REQUIRED.each do |key|
          raise ValidationError, "Required field :#{key} missing" unless config.key?(key)
        end
      end
    end
  end
end
```

### `Composable`

Can be nested inside architecture functions. Architectures compose
resource functions; higher-level architectures compose lower-level ones.

```ruby
module Pangea
  module Composable
    # Contract: self.build(synth, config) returns a composable result
    # (hash of resource references) that can be consumed by parent architectures.
  end
end
```

### `Mockable`

Supports dependency injection for unit testing. Resource functions can
be stubbed in architecture tests.

```ruby
module Pangea
  module Mockable
    # Enables: allow(Pangea::Aws::S3Bucket).to receive(:build).and_return(mock)
    # No special implementation needed -- Ruby's open classes + RSpec mocking
    # provide this naturally. The trait documents the contract.
  end
end
```

### `SecurityEnforced`

Security constraints validated at the type level. No insecure configurations
can pass validation.

```ruby
module Pangea
  module SecurityEnforced
    def enforce_required_tags(tags)
      %w[ManagedBy Purpose Environment Team].each do |tag|
        raise ValidationError, "Missing required tag '#{tag}'" unless tags&.key?(tag)
      end
      tags
    end

    def enforce_encryption(config)
      raise ValidationError, "kms_key_id is required" unless config[:kms_key_id]
    end

    def enforce_least_privilege(statements)
      statements.each do |stmt|
        stmt[:actions].each do |a|
          raise LeastPrivilegeViolation, "Wildcard action: #{a}" if a.include?('*')
        end
        stmt[:resources].each do |r|
          raise LeastPrivilegeViolation, "Wildcard resource" if r == '*'
        end
      end
    end
  end
end
```

### `InSpecMirrorable`

Auto-generate InSpec controls from RSpec assertions.

```ruby
module Pangea
  module InSpecMirrorable
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def to_inspec_profile(synth, config)
        controls = []
        synth.resources.each do |resource|
          controls << inspec_existence_control(resource)
          controls << inspec_encryption_control(resource) if encrypted?(resource)
          controls << inspec_tags_control(resource)
        end
        synth.resources_of_type('aws_iam_policy').each do |policy|
          controls << inspec_least_privilege_control(policy)
        end
        InSpecProfile.new(controls)
      end

      private

      def inspec_existence_control(resource)
        InSpecControl.new(
          id: "#{resource[:name]}-exists",
          impact: 1.0,
          title: "#{resource[:type]} #{resource[:name]} exists",
          desc: "Mirrors: expect(synth.resources).to include_resource_of_type(#{resource[:type]})",
          resource_type: resource[:type],
          resource_id: resource[:name],
          assertions: [{ method: :exist }],
        )
      end
    end
  end
end
```

---

## Performance Characteristics

| Operation | Time | IO | Notes |
|-----------|------|----|-------|
| Resource function `build()` | <1ms | None | Pure Ruby hash construction |
| Resource function `validate!()` | <1ms | None | Schema check, no IO |
| Architecture `build()` | <5ms | None | Composes 3-20 resource functions |
| Full RSpec suite (Layer 1) | <1s | None | 50-200 resource specs |
| Full RSpec suite (Layer 2) | <5s | None | 10-50 architecture specs |
| Test gate overhead | <10s | None | Layer 1 + Layer 2, run before plan/apply |
| InSpec verification (Layer 3) | 1-5min | AWS API | Real cloud calls, post-apply only |
| InSpec profile generation | <100ms | None | From `InSpecMirrorable` trait |

### Why This Is Fast

- **Synthesis is pure Ruby evaluation** -- no cloud API calls, no file IO,
  no network. The synthesizer accumulates resource hashes in memory.
- **Architecture composition is lazy** -- child resource functions are only
  called when `build()` is invoked. No eager evaluation.
- **Validation is schema-only** -- checks field presence and type, not
  cloud provider compatibility. That is InSpec's job.
- **The test gate adds <10 seconds** to every `plan`/`apply`. This is the
  cost of guaranteeing zero broken infrastructure deployments.

---

## SDLC Integration

### Nix App Commands

Every Pangea workspace exposes these commands:

```bash
nix run .#test       # Run full RSpec suite (Layer 1 + Layer 2)
nix run .#plan       # Test gate -> terraform plan
nix run .#apply      # Test gate -> terraform apply
nix run .#verify     # InSpec live verification (Layer 3)
nix run .#deploy     # test -> apply -> verify (full lifecycle)
nix run .#drift      # Compare synthesized config vs actual cloud state
nix run .#validate   # Pangea config schema validation
nix run .#regen      # Regenerate gemset.nix
```

### The Gated Workflow

```
Developer writes architecture
        |
        v
nix run .#test  -----> RSpec Layer 1 (resource unit tests)
        |                   |
        |              RSpec Layer 2 (architecture synthesis tests)
        |                   |
        |              All pass? ──No──> STOP. Fix tests first.
        |                   |
        |                  Yes
        v                   |
nix run .#plan  <───────────┘
        |
        v
Review plan output
        |
        v
nix run .#apply -----> (test gate runs again, then apply)
        |
        v
nix run .#verify ----> InSpec Layer 3 (live cloud verification)
        |
        v
Done. Infrastructure matches synthesis.
```

### Key Properties

1. **No bypass**: `nix run .#plan` always runs tests first. There is no
   `--skip-tests` flag. The emergency `plan-ungated` exists but is logged.
2. **Idempotent**: Running `deploy` twice with no changes produces no diff.
3. **Deterministic**: Same config always produces same synthesis output.
4. **Auditable**: Every deployment has a test result, a plan diff, and
   an InSpec verification report.

---

## Complete Example: End-to-End

### 1. Define Resource Functions (if new ones needed)

```ruby
# lib/resources/rds_instance.rb
module Pangea::Aws
  class RdsInstance
    include Synthesizable, Validatable, SecurityEnforced, Mockable, InSpecMirrorable

    REQUIRED = [:identifier, :engine, :kms_key_id, :tags].freeze
    DEFAULTS = {
      deletion_protection: true,
      storage_encrypted: true,
      multi_az: true,
      backup_retention_period: 7,
      prevent_destroy: true,
    }.freeze

    def self.build(synth, config)
      validate!(config)
      merged = DEFAULTS.merge(config)
      synth.resource('aws_db_instance', merged[:identifier], { ... })
    end
  end
end
```

### 2. Write Resource Spec (Layer 1)

```ruby
# spec/resources/rds_instance_spec.rb
RSpec.describe Pangea::Aws::RdsInstance do
  it 'requires kms_key_id' do
    expect { described_class.build(synth, config.except(:kms_key_id)) }
      .to raise_error(Pangea::ValidationError)
  end

  it 'enables deletion protection by default' do
    resource = described_class.build(synth, config)
    expect(resource[:deletion_protection]).to eq(true)
  end

  it 'enables storage encryption by default' do
    resource = described_class.build(synth, config)
    expect(resource[:storage_encrypted]).to eq(true)
  end
end
```

### 3. Define Architecture

```ruby
# lib/architectures/database_cluster.rb
module Pangea::Architectures
  class DatabaseCluster
    include Synthesizable, Composable, SecurityEnforced, InSpecMirrorable

    def self.build(synth, config)
      validate_config!(config)

      db = Pangea::Aws::RdsInstance.build(synth, {
        identifier: config[:name],
        engine: config[:engine],
        kms_key_id: config[:kms_key],
        tags: config[:tags],
      })

      sg = Pangea::Aws::SecurityGroup.build(synth, {
        name: "#{config[:name]}-sg",
        ingress_rules: [{
          port: 5432,
          protocol: 'tcp',
          cidr_blocks: [config[:vpc_cidr]],
          description: 'PostgreSQL from VPC',
        }],
        tags: config[:tags],
      })

      { database: db, security_group: sg }
    end
  end
end
```

### 4. Write Architecture Spec (Layer 2)

```ruby
# spec/architectures/database_cluster_spec.rb
RSpec.describe Pangea::Architectures::DatabaseCluster do
  let(:synth) { Pangea::Synthesizer.new }
  let(:result) { described_class.build(synth, config) }

  it 'creates RDS instance and security group' do
    result
    types = synth.resources.map { |r| r[:type] }
    expect(types).to include('aws_db_instance', 'aws_security_group')
  end

  it 'restricts database access to VPC CIDR only' do
    sg = result[:security_group]
    cidrs = sg[:ingress].flat_map { |r| r[:cidr_blocks] }
    expect(cidrs).to eq([config[:vpc_cidr]])
    expect(cidrs).not_to include('0.0.0.0/0')
  end

  it 'enables deletion protection on RDS' do
    expect(result[:database][:deletion_protection]).to eq(true)
  end
end
```

### 5. Generate InSpec Controls (Layer 3)

```ruby
# inspec/controls/database_cluster.rb
control 'database-exists' do
  impact 1.0
  title 'Database instance exists'
  desc 'Mirrors: expect(synth.resources).to include_resource_of_type(aws_db_instance)'

  describe aws_rds_instance(db_instance_identifier: input('db_identifier')) do
    it { should exist }
    it { should have_encryption_enabled }
    it { should have_deletion_protection_enabled }
    its('db_instance_status') { should eq 'available' }
  end
end

control 'database-sg-restricted' do
  impact 1.0
  title 'Database security group restricts access to VPC'
  desc 'Mirrors: expect(cidrs).not_to include(0.0.0.0/0)'

  describe aws_security_group(group_name: input('sg_name')) do
    it { should exist }
    it { should_not allow_in(port: 5432, ipv4_range: '0.0.0.0/0') }
  end
end
```

### 6. Wire into Gated Nix Workspace

```nix
# consumer-repo/flake.nix
outputs = (import "${substrate}/lib/infra/pangea-infra-flake.nix" {
  inherit nixpkgs ruby-nix substrate;
}) {
  inherit self;
  name = "my-database";
};
```

### 7. Deploy

```bash
nix run .#test       # Layer 1 + 2: all pass
nix run .#plan       # Gate passes -> shows plan
nix run .#apply      # Gate passes -> creates resources
nix run .#verify     # Layer 3: InSpec verifies live resources
```

---

## Anti-Patterns

These patterns are NEVER acceptable in Pangea infrastructure:

| Anti-Pattern | Why It Is Wrong | Correct Pattern |
|-------------|-----------------|-----------------|
| `actions: ['s3:*']` | Wildcard action violates least-privilege | List each action: `['s3:GetObject', 's3:PutObject']` |
| `resources: ['*']` | Wildcard resource grants access to everything | Use explicit ARNs from resource outputs |
| `kms_key_id: nil` | Unencrypted storage | `kms_key_id` is REQUIRED, not optional |
| `versioning: false` | Data loss risk | Default is `true`; cannot be overridden without explicit justification |
| `public_access_block: false` | Public bucket | Default is `true`; cannot be overridden |
| `prevent_destroy: false` | Accidental deletion of stateful resources | Default is `true` on all stateful resources |
| Missing tags | Untracked, unauditable resources | Tags are REQUIRED fields, not optional |
| Hardcoded ARNs | Brittle, error-prone cross-references | Derive ARNs from resource outputs |
| `cidr_blocks: ['0.0.0.0/0']` on non-443 | Open network access | Specific CIDR blocks for specific ports |
| Secrets in state | Credential exposure | Use `sensitive: true` and Akeyless dynamic producers |
| Skipping Layer 2 tests | Untested compositions deployed to cloud | All architectures must have synthesis specs |
| Skipping Layer 3 controls | No verification of live state | InSpec controls mirror every RSpec assertion |
