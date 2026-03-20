# Testing

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
| 1 | Logic errors in resource functions, wrong defaults, missing validations | Zero | Milliseconds |
| 2 | Composition errors, missing dependencies, wrong wiring, config drift | Zero | Seconds |
| 3 | Provider bugs, API incompatibilities, permission errors, real behavior | Cloud cost | Minutes |

---

## Layer 1: RSpec Resource Unit Tests

Test individual Pangea resource functions in isolation.

```ruby
# spec/resources/s3_bucket_spec.rb
RSpec.describe "s3_bucket resource" do
  let(:resource) { StateBackend::Resources.s3_bucket("test-bucket", "us-east-1") }

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

### Rules

- Every resource function gets at least one spec file
- Test security constraints (encryption, access blocks, lifecycle)
- Test default values and required parameters
- Test edge cases (empty strings, nil values, missing optional params)
- Run with `nix run .#test` or `bundle exec rspec`

---

## Layer 2: RSpec Architecture Synthesis Tests

Test full architecture compositions without touching cloud providers.
The Pangea DSL synthesizes the complete resource graph in-memory.

```ruby
# spec/architectures/state_backend_spec.rb
RSpec.describe "state_backend architecture" do
  let(:arch) { StateBackend.new(workspace: "test", region: "us-east-1") }
  let(:resources) { arch.synthesize }

  it "creates an S3 bucket" do
    expect(resources).to include_resource_of_type(:s3_bucket)
  end

  it "creates a DynamoDB table" do
    expect(resources).to include_resource_of_type(:dynamodb_table)
  end

  it "creates a KMS key" do
    expect(resources).to include_resource_of_type(:kms_key)
  end

  it "wires KMS key to S3 bucket" do
    bucket = resources.find_by_type(:s3_bucket)
    kms = resources.find_by_type(:kms_key)
    expect(bucket[:kms_key_id]).to eq(kms[:arn])
  end

  it "wires KMS key to DynamoDB table" do
    table = resources.find_by_type(:dynamodb_table)
    kms = resources.find_by_type(:kms_key)
    expect(table[:kms_key_id]).to eq(kms[:arn])
  end

  it "has required tags on all resources" do
    resources.each do |r|
      expect(r[:tags]).to include("ManagedBy", "Purpose", "Environment", "Team")
    end
  end
end
```

### What synthesis tests verify

- All expected resources are present
- Cross-resource references are correct (KMS key wired to S3 and DynamoDB)
- Security constraints are satisfied across the full architecture
- Tag requirements are met
- No orphaned resources
- Environment-specific overrides work correctly

### Key advantage

Synthesis tests run in pure Ruby -- no cloud API calls, no credentials needed,
no cost. They verify the complete resource graph that would be generated for a
real deployment.

---

## Layer 3: InSpec Live Verification

Post-apply verification of real cloud resources using InSpec.

```ruby
# controls/state_backend.rb
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

### Rules

- InSpec controls mirror RSpec synthesis test assertions
- Every synthesis test that checks a resource property should have
  a corresponding InSpec control
- Run post-apply only (never before `plan` or `apply`)
- Use `inspec-akeyless` resource pack for Akeyless-specific verification
- Store InSpec profiles alongside architecture code

---

## Gated Workspace Pattern

Infrastructure workspaces enforce a test gate: tests must pass before
`plan` or `apply` can execute.

```
nix run .#test      # Layer 1 + Layer 2 (must pass)
nix run .#plan      # Only runs if test passed
nix run .#apply     # Only runs if test passed
nix run .#verify    # Layer 3 (post-apply)
```

### Implementation

The `pangea-workspace.nix` and `pangea-infra.nix` builders produce apps
that enforce this ordering:

```nix
# Generated apps from pangea-infra.nix:
apps = {
  test     = ...;  # RSpec unit + synthesis
  validate = ...;  # Pangea config validation
  plan     = ...;  # Synthesize + diff (gated on test)
  apply    = ...;  # Apply changes (gated on test)
  destroy  = ...;  # Destroy (requires explicit confirmation)
  verify   = ...;  # InSpec post-apply verification
  drift    = ...;  # Detect configuration drift
  regen    = ...;  # Regenerate gemset.nix
};
```

---

## RSpec-to-InSpec Mirroring

For every RSpec synthesis assertion, create a corresponding InSpec control:

| RSpec synthesis test | InSpec control |
|---------------------|----------------|
| `expect(resource[:versioning]).to eq(true)` | `it { should have_versioning_enabled }` |
| `expect(resource[:encryption]).to eq(:kms)` | `it { should have_default_encryption_enabled }` |
| `expect(resource[:billing_mode]).to eq("PAY_PER_REQUEST")` | `its("billing_mode") { should eq "PAY_PER_REQUEST" }` |
| `expect(resources).to include_resource_of_type(:kms_key)` | `describe aws_kms_key(...) { it { should exist } }` |

This mirroring ensures that:
1. What you synthesize is what you verify
2. Drift between synthesis and reality is detected
3. Security properties are verified at both layers

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
