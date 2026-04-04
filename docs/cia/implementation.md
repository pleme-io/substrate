# CIA v1.0 Implementation Plan

## Current State (Audit Summary)

### Helm (22 charts in helmworks)

| Slice | Charts with full coverage | Charts missing | Gap |
|-------|--------------------------|----------------|-----|
| Compute | 17/22 | 5 (cache, database, shinryu, sekiban, namespace) | No unified scaling pattern (HPA/KEDA) |
| Transport | 15/22 (Service only) | 7 | No mTLS default, no ingress pattern |
| Storage | 4/22 | 18 | No `_pvc.tpl`, no backup integration |
| Identity | 5/22 | 17 | No auth template, secrets not standardized |
| Network | 21/22 (NetworkPolicy) | 1 | No egress policy, no topology |
| Observe | 16/22 (metrics) | 6 | No tracing, no structured logs |
| Attest | 4/22 | 18 | No image signing, no provenance |
| Gate | 4/22 | 18 | No policy-as-code |

### Pangea (31 architectures in pangea-architectures)

| Slice | Architectures | Coverage |
|-------|--------------|----------|
| Compute | 13 | Strong — K3s, EKS, AMI, Hetzner |
| Transport | 11 | Strong — Vector layers, VPN, DNS |
| Storage | 11 | Strong — S3, RDS, ECR, PVC |
| Identity | 15 | Strongest — IAM, RBAC, Akeyless |
| Network | 10 | Good — VPC, subnets, firewalls |
| Observe | 11 | Good — Datadog, Splunk, Vector |
| Attest | 3 | Weak — only attested targets + monitoring |
| Gate | 1 | Weakest — only Cloudflare WAF |

---

## Implementation: pleme-lib v0.5 (New Slice Templates)

### Phase 1: Transport Slice (wire everything)

**New template:** `helmworks/charts/pleme-lib/templates/_transport.tpl`

Every workload that declares `transport.profile` gets:
- Vector sidecar injection OR pod annotation for DaemonSet collection
- NATS connection config (if guaranteed delivery)
- Structured log format enforcement

```yaml
# values.yaml pattern for any chart
transport:
  profile: production     # minimal | observability | production
  vector:
    enabled: true         # auto-inject Vector sidecar or rely on DaemonSet
    mode: daemonset       # daemonset (collect from stdout) | sidecar (direct)
  nats:
    enabled: false        # guaranteed delivery via NATS JetStream
    stream: ""            # NATS stream name
  structured_logs: true   # enforce JSON stdout
```

### Phase 2: Storage Slice

**New template:** `helmworks/charts/pleme-lib/templates/_storage.tpl`

```yaml
storage:
  workspace:
    enabled: false
    type: emptyDir        # emptyDir | pvc
    size: 2Gi
    storageClass: ""
  data:
    enabled: false
    type: pvc
    size: 10Gi
    storageClass: gp3
    backup:
      enabled: false
      schedule: "0 */6 * * *"
      retention: 7
```

### Phase 3: Identity Slice

**New template:** `helmworks/charts/pleme-lib/templates/_identity.tpl`

```yaml
identity:
  serviceAccount:
    create: true
    annotations: {}       # eks.amazonaws.com/role-arn for IRSA
  rbac:
    create: true
    clusterScoped: false
    rules: []
  secrets:
    provider: kubernetes  # kubernetes | akeyless | vault
    akeyless:
      authMethod: k8s
      gateway: akeyless-gateway.akeyless.svc
```

### Phase 4: Observe Slice (extend existing)

**Enhance:** `helmworks/charts/pleme-lib/templates/_servicemonitor.tpl`

Add tracing + structured log config:

```yaml
observe:
  metrics:
    enabled: true
    port: metrics
    path: /metrics
  tracing:
    enabled: false
    collector: otel-collector.observability.svc:4317
    sampleRate: 0.1
  logs:
    structured: true      # enforce JSON format
    level: info
```

### Phase 5: Attest + Gate Slices

**New templates:**
- `_attest.tpl` — Add tameshi/sekiban annotations
- `_gate.tpl` — Add policy enforcement annotations

```yaml
attest:
  enabled: false
  signatureGate: ""       # sekiban SignatureGate name
  certificationRef: ""    # sekiban Certification name

gate:
  enabled: false
  complianceBinding: ""   # pangea-operator ComplianceBinding name
  policies: []            # Kyverno/OPA policies
```

---

## Implementation: Pangea Architectures (New Slice Compositions)

### New Architecture: `transport_bus.rb`
Composes Vector + NATS + KEDA for any cluster:

```ruby
TransportBus.build(synth, {
  cluster_name: 'akeyless-dev',
  profile: :production,
  nats: { enabled: true, replicas: 3 },
  keda: { enabled: true },
})
```

### New Architecture: `storage_tier.rb`
Composes S3 + RDS + backup for any cluster:

```ruby
StorageTier.build(synth, {
  cluster_name: 'akeyless-dev',
  s3: { buckets: ['state', 'etcd-backup', 'analytics'] },
  rds: { engine: 'postgresql', instance_class: 'db.t3.micro' },
  backup: { enabled: true, retention_days: 7 },
})
```

### New Architecture: `identity_fabric.rb`
Composes IAM + Akeyless + RBAC for any cluster:

```ruby
IdentityFabric.build(synth, {
  cluster_name: 'akeyless-dev',
  account_id: '376129857990',
  akeyless: { gateway: true, auth_methods: [:k8s, :aws_iam] },
  iam_roles: [:node, :ami_builder, :pipeline],
})
```

### New Architecture: `attest_chain.rb`
Composes tameshi + sekiban + kensa for any cluster:

```ruby
AttestChain.build(synth, {
  cluster_name: 'akeyless-dev',
  frameworks: [:nist_800_53, :cis_k8s],
  heartbeat: { s3_uri: 's3://attestations/akeyless-dev' },
  admission: { enabled: true },
})
```

---

## Slice Metadata Convention

Every Helm chart and Pangea architecture declares its slice composition
in metadata, enabling automated auditing:

**Helm (Chart.yaml annotations):**
```yaml
annotations:
  cia.pleme.io/slices: "compute,transport,identity,observe"
  cia.pleme.io/version: "1.0"
```

**Pangea (module doc):**
```ruby
# @cia_slices compute, network, identity, storage, observe
# @cia_version 1.0
module K3sDevCluster
```

---

## Priority Order

1. **Transport** — highest ROI, connects everything, already built (Vector/NATS)
2. **Identity** — security baseline, IRSA for AWS, Akeyless for secrets
3. **Storage** — PVC standardization, backup integration
4. **Observe** — extend existing metrics to include tracing + structured logs
5. **Attest + Gate** — integrity chain, compliance enforcement
6. **Compute** — unify HPA/KEDA scaling patterns
7. **Network** — egress policies, service mesh defaults
