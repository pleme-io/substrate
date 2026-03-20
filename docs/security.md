# Security

Mandatory security patterns for all infrastructure built with substrate.
Every infrastructure module in `lib/infra/` enforces these constraints.
Every Pangea resource function enforces them at the type level.

**Core tenet: absolute least-privilege.** Security is not a layer you add
on top -- it is embedded in every typed resource function, validated by
RSpec at synthesis time, and verified by InSpec against live resources.

---

## Principles

1. **Absolute least-privilege**: Every IAM role, policy, and service account
   gets the minimum permissions required. No wildcards (`*`) in resource ARNs
   or actions -- ever. Every action MUST be listed individually. Every resource
   ARN MUST be explicit. `Action: ["s3:*"]` is a policy violation. `Resource: "*"`
   is a policy violation.
2. **Typed resource enforcement**: Pangea resource functions enforce security
   at the type level. Encryption, versioning, public access blocks, and tags
   are not optional parameters -- they are required fields. The type system
   makes insecure configurations impossible to express.
3. **Encryption at rest**: All persistent storage uses KMS encryption --
   never platform-default keys. The `kms_key_id` parameter is REQUIRED
   on every storage resource function, not optional.
4. **Encryption in transit**: TLS everywhere. No plaintext HTTP between services.
   Bucket policies deny non-TLS access (`aws:SecureTransport: false`).
5. **Immutable infrastructure**: Stateful resources get `prevent_destroy`.
   Destroy operations require explicit override in a separate commit.
6. **No secrets in state**: Terraform/Pangea state never contains secret values.
   Use dynamic producers (Akeyless, Vault) with rotation. Pangea `sensitive: true`
   fields are auto-excluded from outputs and state.
7. **Auditability**: Every resource is tagged for ownership and purpose tracking.
   Tags are enforced by the type system -- resources without required tags
   fail validation before synthesis.
8. **Defense in depth**: Security is enforced at three independent layers:
   - **Layer 1 (type system)**: Pangea resource functions require security
     parameters at the Ruby type level. You cannot construct an S3 bucket
     without `kms_key_id` and `tags`.
   - **Layer 2 (RSpec validation)**: Synthesis tests assert security invariants
     across composed architectures (no `*` in IAM, encryption wired correctly).
   - **Layer 3 (InSpec verification)**: Live verification confirms real cloud
     resources match the synthesized security posture.

---

## Absolute Least-Privilege IAM

### Explicit Allow-List

Every IAM policy MUST enumerate individual actions and explicit resource ARNs.
No exceptions. No shortcuts. No wildcards.

```ruby
# CORRECT: every action listed individually, explicit resource ARNs
Pangea::Aws::IamPolicy.build(synth, {
  name: 'state-backend-access',
  statements: [{
    effect: 'Allow',
    actions: ['s3:GetObject', 's3:PutObject', 's3:ListBucket'],
    resources: [
      'arn:aws:s3:::pleme-prod-state',
      'arn:aws:s3:::pleme-prod-state/*',
    ],
  }, {
    effect: 'Allow',
    actions: ['dynamodb:GetItem', 'dynamodb:PutItem', 'dynamodb:DeleteItem'],
    resources: ['arn:aws:dynamodb:us-east-1:123456789:table/pleme-prod-locks'],
  }],
  tags: config[:tags],
})
```

```ruby
# VIOLATION: action wildcard -- NEVER do this
actions: ['s3:*']
# -> Pangea::Aws::IamPolicy.validate! raises:
#    "Action wildcard 's3:*' violates least-privilege policy"

# VIOLATION: resource wildcard -- NEVER do this
resources: ['*']
# -> Pangea::Aws::IamPolicy.validate! raises:
#    "Resource wildcard '*' violates least-privilege policy"

# VIOLATION: service-level wildcard -- NEVER do this
actions: ['iam:*', 'ec2:*']
# -> Each action must be individually specified
```

### Validation at the Type Level

The `Pangea::Aws::IamPolicy` resource function validates at `build()` time:

```ruby
module Pangea::Aws
  class IamPolicy
    include Validatable
    include SecurityEnforced

    def self.validate!(config)
      config[:statements].each do |stmt|
        stmt[:actions].each do |action|
          raise LeastPrivilegeViolation, "Action wildcard '#{action}'" if action.include?('*')
        end
        stmt[:resources].each do |resource|
          raise LeastPrivilegeViolation, "Resource wildcard '#{resource}'" if resource == '*'
        end
      end
    end
  end
end
```

### Rules

- Every service gets its own IAM role -- no shared roles between services
- Trust policies explicitly list allowed principals
- Condition keys constrain access (e.g., `aws:SourceVpc`, `aws:PrincipalTag`)
- Cross-account access requires explicit `sts:AssumeRole` with `ExternalId`
- Review IAM policies on every PR that touches infrastructure
- RSpec tests MUST assert no wildcards in synthesized IAM policies
- InSpec controls MUST verify real IAM policies match synthesized ones
- Architecture functions MUST compose policy ARNs from resource outputs,
  never from string interpolation of account IDs

---

## Typed Resource Enforcement

Pangea resource functions enforce security at the type level. This means
insecure configurations cannot be expressed -- they fail at `validate!` time
before any synthesis occurs.

### What the type system enforces

| Property | Enforcement | Cannot bypass |
|----------|-------------|---------------|
| KMS encryption | `kms_key_id` is REQUIRED (not optional) | No unencrypted storage |
| Versioning | Default `true`, explicit `false` raises warning | No accidental data loss |
| Public access block | All four flags default `true` | No public buckets |
| `prevent_destroy` | Default `true` on stateful resources | No accidental deletion |
| Required tags | `validate!` fails without `ManagedBy`, `Purpose`, `Environment`, `Team` | No untracked resources |
| IAM wildcards | `validate!` rejects `*` in actions and resources | No over-permissioned policies |
| `sensitive` fields | Auto-excluded from state/output | No secrets in state |

### How it works

```ruby
# You CANNOT create a bucket without encryption -- kms_key_id is REQUIRED
Pangea::Aws::S3Bucket.build(synth, {
  bucket_name: 'my-bucket',
  # kms_key_id: OMITTED -- this will FAIL validation
  tags: { 'ManagedBy' => 'pangea' },
})
# -> raises: "Required field :kms_key_id missing for S3Bucket"
```

---

## S3 Storage

Every S3 bucket is created through `Pangea::Aws::S3Bucket`, which enforces
all security constraints through required fields and secure defaults:

```ruby
Pangea::Aws::S3Bucket.build(synth, {
  bucket_name: 'pleme-prod-state',
  kms_key_id: kms_key.arn,      # REQUIRED -- no unencrypted buckets
  tags: required_tags,           # REQUIRED -- no untracked resources
  # These are DEFAULTS (enforced by the type -- you get them for free):
  # versioning: true
  # public_access_block: true  (all four flags)
  # prevent_destroy: true
  # force_ssl: true            (bucket policy denies non-TLS)
  # access_logging: true       (to separate logging bucket)
})
```

### Checklist

- [ ] Versioning enabled (recovery from accidental deletes) -- default `true`
- [ ] KMS encryption with dedicated key (not `aws/s3` default) -- REQUIRED field
- [ ] All four public access block flags set to `true` -- default `true`
- [ ] `prevent_destroy` lifecycle rule -- default `true`
- [ ] Bucket policy denies `s3:*` over non-TLS (`aws:SecureTransport: false`) -- default
- [ ] Access logging to a separate logging bucket -- default

---

## DynamoDB

Every DynamoDB table must have:

```ruby
dynamodb_table "locks" do
  billing_mode "PAY_PER_REQUEST"
  encryption :kms
  kms_key_id kms_key.arn
  point_in_time_recovery true
  lifecycle_rule do
    prevent_destroy true
  end
end
```

### Checklist

- [ ] `PAY_PER_REQUEST` billing (no capacity planning drift)
- [ ] KMS encryption with dedicated key
- [ ] Point-in-time recovery enabled
- [ ] `prevent_destroy` lifecycle rule

---

## Secrets Management

### Never in State

Secrets must never appear in Terraform/Pangea state files. Instead:

1. **Dynamic producers**: Akeyless dynamic secrets with automatic rotation
2. **Secret references**: Store the secret *path*, not the secret *value*
3. **Attestation hashes**: tameshi hashes secret VALUES (BLAKE3) into the
   deployment chain without storing them
4. **Sensitive field exclusion**: Pangea `sensitive: true` fields are
   auto-excluded from outputs and state. The type system enforces this.

### Akeyless Integration

```ruby
# Reference secrets by path -- never inline values
Pangea::Akeyless::StaticSecret.build(synth, {
  path: '/pleme/production/database/password',
  # Value managed in Akeyless console, never in code
  # The path is stored; the VALUE is never in state
  sensitive: true,  # Auto-excluded from terraform output
})

# Dynamic producers -- rotated automatically
Pangea::Akeyless::DynamicSecret.build(synth, {
  path: '/pleme/production/database/dynamic',
  producer_type: 'aws',
  ttl: 3600,
  # Credentials generated on-demand, rotated automatically
})
```

### Pangea `sensitive: true` Enforcement

Any Pangea resource field marked `sensitive: true`:
- Is excluded from Terraform outputs
- Is excluded from state file diffs
- Is masked in plan output
- Triggers a warning if referenced in a non-sensitive context

```ruby
# In a resource function definition:
class DatabasePassword
  FIELDS = {
    password: { type: :string, sensitive: true },  # never in state
    username: { type: :string },
  }
end
```

### Rules

- No secrets in environment variables at build time
- No secrets in Nix store (`/nix/store` is world-readable)
- Runtime secrets via mounted files or Akeyless SDK
- Secret rotation: automated via Akeyless rotated secrets
- Audit: all secret access logged via Akeyless audit
- All secret references in Pangea use `sensitive: true`
- InSpec controls verify secrets are accessible (via Akeyless API) but
  never read or log secret values

---

## Resource Tagging

Every resource must carry these tags:

| Tag | Purpose | Example |
|-----|---------|---------|
| `ManagedBy` | Tool that manages the resource | `pangea`, `terraform`, `flux` |
| `Purpose` | What the resource is for | `state-backend`, `app-database` |
| `Environment` | Deployment environment | `production`, `staging`, `test` |
| `Team` | Owning team | `platform`, `product` |

### In Pangea

```ruby
default_tags do
  managed_by "pangea"
  purpose "state-backend"
  environment workspace_name
  team "platform"
end
```

### Tag enforcement

Infrastructure CI checks that all resources have required tags.
Resources without tags fail validation and cannot be applied.

---

## Lifecycle Protection

### `prevent_destroy`

All stateful resources (databases, S3 buckets, DynamoDB tables, KMS keys,
EBS volumes, EFS file systems) must have `prevent_destroy` set.

Destroying a protected resource requires:
1. Explicitly removing `prevent_destroy` in a separate commit
2. PR review from a platform team member
3. Documented justification in the PR description

### Deletion protection

AWS resources that support it (RDS, Aurora, ELB) must also enable
`deletion_protection` at the API level.

---

## Network Isolation

Default-deny posture. Every network resource starts closed and requires
explicit, documented ingress/egress rules.

### Security Groups

```ruby
# CORRECT: explicit ingress from specific CIDR, specific port
Pangea::Aws::SecurityGroup.build(synth, {
  name: 'api-server',
  ingress_rules: [{
    port: 8080,
    protocol: 'tcp',
    cidr_blocks: ['10.0.0.0/16'],  # VPC internal only
    description: 'API traffic from VPC',
  }],
  egress_rules: [{
    port: 443,
    protocol: 'tcp',
    cidr_blocks: ['0.0.0.0/0'],
    description: 'HTTPS to external APIs',
  }],
  tags: config[:tags],
})

# VIOLATION: open ingress -- NEVER do this
ingress_rules: [{ port: 0, protocol: '-1', cidr_blocks: ['0.0.0.0/0'] }]
# -> SecurityGroup.validate! raises:
#    "Open ingress (0.0.0.0/0 on all ports) violates network isolation policy"
```

### Rules

- All VPCs use private subnets for compute workloads
- Public subnets only for load balancers and NAT gateways
- Security groups: default-deny, explicit ingress/egress rules only
- No `0.0.0.0/0` ingress except on load balancer HTTPS (443)
- VPC Flow Logs enabled for audit
- DNS resolution via internal DNS (no public DNS for internal services)
- Pangea security group functions validate against open ingress/egress
- RSpec tests assert no open security groups in synthesized architectures
- InSpec controls verify real security group rules match synthesized rules

---

## Kubernetes Security

- Pod Security Standards: `restricted` baseline
- Network Policies: deny-all default, explicit allow per service
- SOPS-encrypted secrets in Git (FluxCD decryption)
- `encrypted_regex: "^(data|stringData)$"` in `.sops.yaml`
  (NOT `unencrypted_suffix` -- kustomize transformers run before decryption)
- Service accounts with minimal RBAC
- No `privileged` containers
- Read-only root filesystems where possible

---

## Supply Chain

- All container base images pinned by digest
- Nix builds are reproducible and hermetic
- tameshi attestation: BLAKE3 Merkle trees verify build integrity
- sekiban admission webhook gates K8s deploys on valid signatures
- inshou CLI gates Nix rebuilds on valid attestation chains

---

## NIST 800-53 Compliance Mapping

Security controls map to NIST 800-53 control families. The `tameshi`/`kensa`
repos implement full OSCAL compliance attestation. Here is how substrate's
security patterns align:

| Control Family | NIST ID | Substrate Enforcement |
|----------------|---------|----------------------|
| Access Control | AC-3 | Least-privilege IAM -- typed resource functions reject wildcards |
| Access Control | AC-6 | Per-service IAM roles -- no shared credentials |
| Audit & Accountability | AU-2 | VPC Flow Logs, Akeyless audit, CloudTrail |
| Audit & Accountability | AU-6 | Resource tagging for ownership tracking |
| Configuration Management | CM-2 | Deterministic Nix builds, `prevent_destroy` on stateful |
| Configuration Management | CM-6 | Typed Pangea config -- defaults enforce secure baselines |
| Identification & Auth | IA-5 | Akeyless dynamic secrets, no static credentials in state |
| System & Comms Protection | SC-8 | TLS everywhere, bucket policies deny non-TLS |
| System & Comms Protection | SC-12 | KMS key management, required `kms_key_id` fields |
| System & Comms Protection | SC-28 | Encryption at rest via KMS on all storage |
| System & Info Integrity | SI-2 | InSpec post-apply verification detects drift |
| System & Info Integrity | SI-7 | tameshi BLAKE3 Merkle trees, sekiban admission gates |
| Risk Assessment | RA-5 | Defense-in-depth: type system + RSpec + InSpec |

For full OSCAL attestation, see `kensa` (compliance engine) and `tameshi`
(core attestation library). The `kensa` orchestrator composes infrastructure
layer signatures with compliance injection for two-phase certification.

---

## Security Verification Chain

The complete security verification chain from code to cloud:

```
1. Pangea type system        -> insecure configs cannot be expressed
2. Pangea validate!()        -> schema violations caught at build time
3. RSpec Layer 1             -> resource function security tests (unit)
4. RSpec Layer 2             -> architecture security invariants (synthesis)
5. Nix test gate             -> plan/apply blocked until all RSpec passes
6. tameshi attestation       -> BLAKE3 Merkle tree of deployment chain
7. sekiban admission         -> K8s deploys gated on valid signatures
8. InSpec Layer 3            -> live cloud resources verified post-apply
9. kensa compliance          -> NIST 800-53 OSCAL attestation
```

Every layer is independent. Failure at any layer blocks deployment.
No bypass mechanism exists for layers 1-5. Layers 6-9 require explicit
`--skip-verification` flags that are logged and audited.
