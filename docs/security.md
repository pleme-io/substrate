# Security

Mandatory security patterns for all infrastructure built with substrate.
Every infrastructure module in `lib/infra/` enforces these constraints.

---

## Principles

1. **Least privilege**: Every IAM role, policy, and service account gets the
   minimum permissions required. No wildcards (`*`) in resource ARNs or actions.
2. **Encryption at rest**: All persistent storage uses KMS encryption --
   never platform-default keys.
3. **Encryption in transit**: TLS everywhere. No plaintext HTTP between services.
4. **Immutable infrastructure**: Stateful resources get `prevent_destroy`.
   Destroy operations require explicit override.
5. **No secrets in state**: Terraform/Pangea state never contains secret values.
   Use dynamic producers (Akeyless, Vault) with rotation.
6. **Auditability**: Every resource is tagged for ownership and purpose tracking.

---

## IAM

### Explicit Allow-List

```ruby
# CORRECT: specific actions, specific resources
iam_policy "s3-reader" do
  actions ["s3:GetObject", "s3:ListBucket"]
  resources ["arn:aws:s3:::my-bucket", "arn:aws:s3:::my-bucket/*"]
end

# WRONG: wildcards
iam_policy "admin" do
  actions ["s3:*"]
  resources ["*"]
end
```

### Rules

- Every service gets its own IAM role -- no shared roles between services
- Trust policies explicitly list allowed principals
- Condition keys constrain access (e.g., `aws:SourceVpc`, `aws:PrincipalTag`)
- Cross-account access requires explicit `sts:AssumeRole` with `ExternalId`
- Review IAM policies on every PR that touches infrastructure

---

## S3 Storage

Every S3 bucket must have:

```ruby
s3_bucket "state" do
  versioning true
  encryption :kms
  kms_key_id kms_key.arn
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

### Checklist

- [ ] Versioning enabled (recovery from accidental deletes)
- [ ] KMS encryption with dedicated key (not `aws/s3` default)
- [ ] All four public access block flags set to `true`
- [ ] `prevent_destroy` lifecycle rule
- [ ] Bucket policy denies `s3:*` over non-TLS (`aws:SecureTransport: false`)
- [ ] Access logging to a separate logging bucket

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

### Akeyless Integration

```ruby
# Reference secrets by path -- never inline values
akeyless_static_secret "db-password" do
  path "/pleme/production/database/password"
  # Value managed in Akeyless console, never in code
end
```

### Rules

- No secrets in environment variables at build time
- No secrets in Nix store (`/nix/store` is world-readable)
- Runtime secrets via mounted files or Akeyless SDK
- Secret rotation: automated via Akeyless rotated secrets
- Audit: all secret access logged via Akeyless audit

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

## Network Security

- All VPCs use private subnets for compute workloads
- Public subnets only for load balancers and NAT gateways
- Security groups follow least-privilege (specific ports, specific CIDR blocks)
- No `0.0.0.0/0` ingress except on load balancer HTTPS (443)
- VPC Flow Logs enabled for audit
- DNS resolution via internal DNS (no public DNS for internal services)

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
