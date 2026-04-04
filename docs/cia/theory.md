# Composable Infrastructure Architecture (CIA)

## Version 1.0

---

## 1. Definition

Composable Infrastructure Architecture (CIA) is a formal theory for building,
deploying, and operating software infrastructure through **typed composition
of declarative primitives** across four representation domains:

| Domain | Tool | Language | Repository | Composes |
|--------|------|----------|------------|----------|
| **Build** | Nix | Nix | substrate | Reproducible artifacts (binaries, images, shells) |
| **Deploy** | Helm | Go templates | helmworks/pleme-lib | Kubernetes workload configurations |
| **Infra** | Pangea | Ruby DSL | pangea-core + pangea-* | Cloud infrastructure (Terraform JSON) |
| **Lifecycle** | Forge | Rust | forge | Build, test, release, deploy pipelines |

Each domain defines its own **primitives** (the smallest composable unit),
**compositions** (how primitives combine), and **morphisms** (how outputs
from one domain become inputs to another).

---

## 2. Core Axioms

### Axiom 1: Everything is a Typed Composition

Every infrastructure artifact — a container image, a Helm chart, a Terraform
resource, a CI pipeline — is the result of composing typed primitives. There
are no ad-hoc scripts, no imperative steps, no untyped glue.

```
Primitive + Primitive → Composition → Artifact
```

**Nix:** `mkRustService { src, deps }` → Docker image
**Helm:** `pleme-lib.deployment` + `pleme-lib.crd-rbac` → Operator deployment
**Pangea:** `synth.aws_vpc(...)` + `synth.aws_subnet(...)` → VPC architecture
**Forge:** `build` → `test` → `release` → `deploy` → Running service

### Axiom 2: Morphisms Connect Domains

The output of one domain is the input of another. These connections are
**typed morphisms** — not ad-hoc handoffs:

```
Nix (image) ──morphism──▶ Helm (deployment.image)
Pangea (terraform JSON) ──morphism──▶ Nix (operator workspace)
Helm (CRD) ──morphism──▶ Pangea (InfrastructureTemplate)
Forge (release) ──morphism──▶ Helm (HelmRelease.spec.chart.version)
```

Each morphism has a defined input type, output type, and transformation.

### Axiom 3: Composition Preserves Properties

When two primitives compose, the result inherits the properties of both.
Security contexts compose (both enforced). Resource limits compose (both
applied). Monitoring compose (both scraped). Nothing is silently dropped.

### Axiom 4: Observation is Universal

Every primitive emits structured data through a universal observation layer.
Logs, metrics, traces, and events flow through the same pipeline regardless
of which domain produced them.

```
Any primitive ──emit──▶ Vector/NATS ──route──▶ Storage + Alerting
```

---

## 3. The Four Domains

### 3.1 Build Domain (Nix / substrate)

**Primitives:**
- `mkRustService` — Rust binary + Docker image + deploy.yaml
- `mkRustWorkspace` — Multi-crate workspace with member selection
- `mkRustTool` — Cross-platform CLI with GitHub releases
- `mkRustLibrary` — Crates.io library with CI
- `mkGoTool`, `mkZigTool`, `mkTypescriptTool` — Other languages
- `mkWebApp` — Vite/React web application
- `hm-service-helpers` — Home-manager service module

**Compositions:**
- Service + Database migration → `mkRustService` + `shinka`
- Tool + Shell completion → `mkRustTool` + `completion-forge`
- Library + Release → `mkRustLibrary` + `crate2nix` + CI

**Properties preserved:**
- Reproducibility (Nix guarantees bit-for-bit identical builds)
- Hermetic closure (no untracked dependencies)
- Cross-compilation (aarch64 + x86_64 from single source)

**Morphisms out:**
- → Helm: `image.repository` + `image.tag` (Docker image reference)
- → Forge: `deploy.yaml` (release configuration)
- → Pangea: Runtime tools in operator image (tofu, packer, git)

### 3.2 Deploy Domain (Helm / helmworks + pleme-lib)

**Primitives (pleme-lib templates):**
- `pleme-lib.deployment` — Standard K8s Deployment
- `pleme-lib.service` — ClusterIP Service
- `pleme-lib.serviceaccount` — RBAC identity
- `pleme-lib.servicemonitor` — Prometheus scrape target
- `pleme-lib.networkpolicy` — Network segmentation
- `pleme-lib.pdb` — Pod disruption budget
- `pleme-lib.prometheusrule` — Alert rules
- `pleme-lib.shinka` — Database migration CRD

**Operator-specific primitives (proposed for pleme-lib v0.5):**
- `pleme-lib.operator` — Operator deployment (Recreate strategy, leader election, workspace volume)
- `pleme-lib.crd-rbac` — Auto-generated RBAC from CRD list
- `pleme-lib.compiler-sidecar` — DSL compilation sidecar
- `pleme-lib.executor-env` — External tool environment variables
- `pleme-lib.phase-alerts` — Phase machine Prometheus alerts

**Compositions:**
- Operator + Sidecar + RBAC + Alerts → Full operator chart
- Microservice + Database + Migration → Full service chart
- CronJob + Monitoring → Scheduled workload chart

**Properties preserved:**
- Security (enforced baseline: runAsNonRoot, drop ALL, readOnlyRootFilesystem)
- Observability (ServiceMonitor auto-created when monitoring.enabled)
- Resilience (PDB, strategy, terminationGracePeriodSeconds)

**Morphisms out:**
- → Pangea: CRD instances (InfrastructureTemplate, PackerBuild, etc.)
- → Nix: Chart references in FluxCD GitOps (HelmRelease → HelmRepository)
- → Forge: Deployment target (helm upgrade via forge deploy)

### 3.3 Infra Domain (Pangea / Ruby DSL)

**Primitives:**
- Typed resource functions: `synth.aws_vpc(...)`, `synth.aws_iam_role(...)`, etc.
  - 1,526 AWS resources (pangea-aws)
  - 122 Akeyless resources (pangea-akeyless)
  - 448+ resources across Azure, GCP, Cloudflare, Hetzner, Datadog, Splunk
- Synthesizers: `TerraformSynthesizer`, `TypedArraySynthesizer`
- SynthesizerFormat CRD: Runtime-defined output formats

**Compositions (Architectures):**
- `K3sDevCluster` — VPC + IAM + ASG + NLB + CloudWatch
- `AmiProductionIam` — Role + 4 policies + instance profile + SSM
- `StateBackend` — S3 + DynamoDB + encryption
- `VectorDataPlatform` — Ingestion + Transform + Sink layers
- `EksScaleTest` — Full EKS cluster with node groups

**Properties preserved:**
- No wildcard IAM actions (enforced by architecture patterns)
- Required tags on all resources (ManagedBy, Purpose, Environment)
- Cryptographic fingerprinting (Pangea::Tagging::Fingerprint)

**Morphisms out:**
- → Helm: Terraform JSON written to InfrastructureTemplate CRD
- → Nix: AMI IDs promoted to SSM parameters → consumed by launch templates
- → Forge: IaC code generated from OpenAPI specs (iac-forge, terraform-forge)

### 3.4 Lifecycle Domain (Forge / Rust)

**Primitives:**
- `build` — Compile source to artifact
- `test` — Validate artifact against spec
- `release` — Version, tag, publish artifact
- `deploy` — Ship artifact to target environment
- `generate` — Transform spec to code (forge-gen)

**Compositions:**
- `forge-gen` — OpenAPI spec → SDKs + MCP servers + IaC + completions + schemas
- `iac-forge` — TOML specs → Terraform/Pulumi/Crossplane/Ansible/Pangea/Steampipe
- `mcp-forge` — OpenAPI spec → Rust MCP server
- `completion-forge` — OpenAPI spec → Shell completions (skim-tab YAML + fish)

**Properties preserved:**
- Deterministic generation (same spec → same output)
- Multi-platform targets (6 IaC backends from one spec)
- Attestation chain (tameshi BLAKE3 hashing at every stage)

**Morphisms out:**
- → Pangea: Generated Ruby DSL resource functions (pangea-forge)
- → Helm: Generated CRD schemas (from Rust derive macros)
- → Nix: Release artifacts pushed to GHCR/Attic (consumed by flake inputs)

---

## 4. The Transport Layer (Universal Data Bus)

The transport layer is not merely observability — it is the **universal data bus**
that connects any infrastructure composition to any other. Every architecture that
produces data (logs, metrics, events, state changes, compliance results, pipeline
phases) plugs into the bus through a typed **transport declaration**. The bus handles
routing, transformation, delivery guarantees, and auto-scaling.

### 4.1 Transport Primitives

| Primitive | What it does | Pangea | Helm |
|-----------|-------------|--------|------|
| **Source** | Collects data from a producer | `VectorIngestionLayer` | Vector DaemonSet source config |
| **Transform** | Enriches/normalizes data in-flight | `VectorTransformLayer` | VRL transform chain |
| **Sink** | Delivers data to a consumer | `VectorSinkLayer` | Vector sink config |
| **Route** | Conditional fan-out to multiple sinks | NATS subject routing | NATS JetStream consumers |
| **Faucet** | Tap into a live stream without disruption | Shinryu traffic ops | `vector tap` + NATS mirror |
| **Mirror** | Duplicate a stream to a secondary destination | NATS mirror config | HelmRelease sink duplication |
| **Sample** | Probabilistic sampling of high-volume streams | VRL `random(0.01)` | Transform config |
| **Filter** | Drop events matching criteria | VRL `if .level == "debug" { abort }` | Transform config |
| **Buffer** | Absorb burst traffic with backpressure | NATS JetStream + DLQ | Vector memory/disk buffer |
| **Breathe** | Auto-scale transport capacity to load | KEDA ScaledObject | HelmRelease + KEDA trigger |

### 4.2 Transport Profiles

Services declare transport needs through **profiles** — named presets that
compose source + transform + sink configurations:

```yaml
# Minimal: just logs to Loki
transport:
  profile: minimal

# Full observability: logs + metrics + traces
transport:
  profile: observability

# Scale test: HTTP ingest + analytics + guaranteed delivery
transport:
  profile: scale_test

# Production: everything + NATS guarantees + KEDA breathing
transport:
  profile: production
```

Each profile maps to a `VectorDataPlatform` Pangea architecture composition
(ingestion + transform + sink layers) and a Shinryu Helm chart values override.

### 4.3 The DAG of Data Movement

Infrastructure compositions form a **directed acyclic graph of data movement**:

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│ PackerBuild  │     │ K3s Cluster  │     │ Compliance   │
│ (AMI events) │     │ (pod logs)   │     │ (results)    │
└──────┬───────┘     └──────┬───────┘     └──────┬───────┘
       │                    │                    │
       ▼                    ▼                    ▼
┌─────────────────────────────────────────────────────────┐
│              Transport Bus (Vector + NATS)                │
│                                                           │
│  Sources ──▶ Transforms ──▶ Routes ──▶ Sinks             │
│                                                           │
│  Breathing: KEDA watches NATS lag, scales Vector pods     │
│  Guarantees: JetStream persistence, consumer acks, DLQ    │
└────┬──────────┬──────────┬──────────┬──────────┬─────────┘
     │          │          │          │          │
     ▼          ▼          ▼          ▼          ▼
  ┌──────┐  ┌──────┐  ┌────────┐  ┌──────┐  ┌────────┐
  │ Loki │  │ VM   │  │ Shinryu│  │ S3   │  │Grafana │
  │(logs)│  │(metr)│  │(analyt)│  │(arch)│  │(dash)  │
  └──────┘  └──────┘  └────────┘  └──────┘  └────────┘
```

**Key principle:** No infrastructure talks directly to another infrastructure.
All data flows through the transport bus. This means:

1. **Any producer can reach any consumer** — just declare source + sink
2. **Adding a new consumer never changes the producer** — add a sink, done
3. **Transport capacity adapts to load** — KEDA breathing, not manual scaling
4. **Delivery guarantees are configurable per-stream** — at-most-once, at-least-once, exactly-once
5. **The entire data flow is observable** — Vector emits metrics about itself

### 4.4 Expressing Transport in Pangea and Helm

**Pangea (typed Ruby DSL):**
```ruby
VectorDataPlatform.build(synth, {
  profile: :production,
  cluster_name: 'akeyless-dev',
  ingestion: { kubernetes_logs: true, statsd: true },
  sink: { loki: true, analytics: true },
})
```

**Helm (values override):**
```yaml
shinryu:
  vector:
    profile: production
  analytics:
    pvc:
      enabled: true
      size: 100Gi
  keda:
    enabled: true
    stream: VECTOR_DELIVERY
    lagThreshold: 100
```

Both produce the same operational result — a breathing data pipeline that
collects, transforms, routes, and delivers. The Pangea expression is for
provisioning the cloud infrastructure (NATS cluster, S3 buckets, IAM roles).
The Helm expression is for deploying the K8s workloads (Vector DaemonSets,
Shinryu pods, KEDA ScaledObjects).

---

---

## 5. The Eight Infrastructure Slices

Every infrastructure need maps to exactly one of eight universal slices.
Each slice has a Pangea expression (cloud provisioning) and a Helm expression
(K8s deployment). Compositions combine slices — a "database" is Storage +
Identity + Observe. A "service" is Compute + Transport + Identity + Observe.

### Slice 1: Compute — Where Code Runs

**Need:** Execute workloads (containers, functions, VMs, AMIs).

| Level | Pangea | Helm |
|-------|--------|------|
| VM | `K3sDevCluster`, `EksScaleTest`, `AmiProductionIam` | n/a (pre-K8s) |
| Container | (K8s manages) | `pleme-lib.deployment`, `pleme-lib.operator` |
| Job | (K8s manages) | `pleme-cronjob`, batch/v1 Job |
| Function | Lambda architecture (future) | Knative (future) |

**Pangea primitives:** `aws_launch_template`, `aws_autoscaling_group`, `aws_eks_cluster`
**Helm primitives:** `pleme-lib.deployment` (strategy, replicas, resources, probes)

### Slice 2: Transport — How Data Moves

**Need:** Route data between producers and consumers with guarantees.

Already formalized in Section 4. Summary:

| Level | Pangea | Helm |
|-------|--------|------|
| Stream | `VectorIngestionLayer` | Vector DaemonSet sources |
| Transform | `VectorTransformLayer` | VRL transform chain |
| Deliver | `VectorSinkLayer` | Vector sinks + NATS JetStream |
| Breathe | KEDA config | `pleme-shinryu` ScaledObject |

### Slice 3: Storage — Where Data Stays

**Need:** Persist state (databases, object stores, volumes, caches).

| Level | Pangea | Helm |
|-------|--------|------|
| Block | `aws_ebs_volume`, PVC | `pleme-statefulset` volumeClaimTemplates |
| Object | `StateBackend` (S3 + DynamoDB) | ConfigMap/Secret references |
| Relational | `PitrTestDatabase`, RDS architecture | `pleme-database` (CNPG PostgreSQL) |
| Cache | ElastiCache architecture (future) | Redis/Valkey StatefulSet |
| State | `PangeaNamespace` (PostgreSQL schema) | pangea-operator workspace volume |

**Pangea primitives:** `aws_s3_bucket`, `aws_dynamodb_table`, `aws_rds_cluster`
**Helm primitives:** `pleme-database`, `pleme-statefulset`, PVC templates

### Slice 4: Identity — Who You Are

**Need:** Authenticate, authorize, issue credentials.

| Level | Pangea | Helm |
|-------|--------|------|
| Cloud | `K3sClusterIam`, `AmiProductionIam` | n/a (pre-K8s) |
| Cluster | (RBAC via CRDs) | `pleme-lib.serviceaccount`, `pleme-lib.crd-rbac` |
| Service | Akeyless auth methods | `akeyless-k8s-secrets-injection` |
| User | `AkeylessDevWorkspace` (SSO trust) | OIDC provider config |

**Pangea primitives:** `aws_iam_role`, `aws_iam_policy`, `akeyless_auth_method`
**Helm primitives:** ServiceAccount + ClusterRole + ClusterRoleBinding

### Slice 5: Network — How Things Connect

**Need:** Route traffic, segment access, encrypt in transit.

| Level | Pangea | Helm |
|-------|--------|------|
| VPC | `AwsVpcNetwork` (3-tier subnets) | n/a (pre-K8s) |
| Mesh | WireGuard VPN (mamorigami) | `pleme-lib.networkpolicy` |
| DNS | Cloudflare DNS, Route53 | CoreDNS config |
| Ingress | NLB, ALB | `pleme-lib.service`, Ingress/VirtualService |
| Policy | Security groups | `pleme-lib.networkpolicy` (deny-all + allows) |

**Pangea primitives:** `aws_vpc`, `aws_subnet`, `aws_security_group`, `aws_lb`
**Helm primitives:** Service, NetworkPolicy, Istio PeerAuthentication

### Slice 6: Observe — What's Happening

**Need:** Metrics, logs, traces, dashboards, alerts.

Built on top of Transport (Slice 2) — Observe is the **consumption side**
of the transport bus.

| Level | Pangea | Helm |
|-------|--------|------|
| Collect | `VectorDataPlatform` | `pleme-shinryu` |
| Store | Loki, VictoriaMetrics, Tempo | `pleme-statefulset` for each |
| Alert | PrometheusRules | `pleme-lib.prometheusrule` |
| Dashboard | Grafana provisioning | Grafana Helm chart + ConfigMaps |
| Query | shinryu-mcp (Bronze/Silver/Gold) | shinryu deployment |

### Slice 7: Attest — Proof of Integrity

**Need:** Cryptographic proof that infrastructure is what it claims to be.

| Level | Pangea | Helm |
|-------|--------|------|
| Hash | tameshi LayerSignature (BLAKE3) | Annotation on Deployment |
| Certify | tameshi CertificationArtifact (3-leaf Merkle) | sekiban Certification CRD |
| Verify | kensa ComplianceRunner | ComplianceSchedule CRD |
| Audit | tameshi HeartbeatChain | S3 + Vector sink |

### Slice 8: Gate — Who Can Do What When

**Need:** Control flow — block, allow, react based on conditions.

| Level | Pangea | Helm |
|-------|--------|------|
| Admission | sekiban SignatureGate (K8s webhook) | sekiban HelmRelease |
| Compliance | ComplianceBinding (suspend/resume targets) | pangea-operator controller |
| Approval | ImagePipeline approval mode | Manual/webhook/auto |
| Policy | CompliancePolicy (NIST 800-53) | sekiban CompliancePolicy CRD |

---

### Composition Rules

Any infrastructure composition is a **subset of slices with typed connections**:

```
Service = Compute + Transport + Identity + Observe
Database = Storage + Identity + Observe + Gate
Pipeline = Compute + Transport + Storage + Attest + Gate
Cluster = Compute + Network + Identity + Storage + Observe + Attest
```

Each slice is independently configurable via Pangea (cloud) and Helm (K8s).
The Transport slice connects all others — any slice that produces data
declares a transport profile, and the bus handles the rest.

---

## 6. The Observation Layer (built on Transport)

All four domains emit events into a **universal observation pipeline**:

```
┌──────────────────────────────────────────────────────────┐
│                   Observation Layer                        │
│                                                            │
│  Source ──▶ Vector (collect) ──▶ NATS (route) ──▶ Sink    │
│                                                            │
│  Sources:                    Sinks:                        │
│  - K8s pod logs              - Loki (logs)                 │
│  - Prometheus metrics        - VictoriaMetrics (metrics)   │
│  - OpenTelemetry traces      - Tempo (traces)              │
│  - K8s events                - S3 (archive)                │
│  - Tameshi heartbeat chain   - Datadog/Splunk (external)   │
│  - Compliance results        - Grafana (dashboards)        │
│  - Pipeline phase changes    - PagerDuty (alerts)          │
└──────────────────────────────────────────────────────────┘
```

**CIA Principle:** Observation is not opt-in. Every primitive that runs in
production emits structured events. The `monitoring.enabled: true` default in
pleme-lib ensures this. The `ReportingConfig` in ComplianceSchedule routes
compliance events to the same pipeline. The `HeartbeatChain` in tameshi
records cryptographic audit trails to S3. All through Vector + NATS.

---

## 5. Cross-Domain Composition Patterns

### Pattern 1: Spec → Generate → Build → Deploy → Observe

The canonical lifecycle of any service:

```
OpenAPI spec (YAML)
  │ forge-gen --sdks --mcp --iac
  ▼
Generated code (Rust + Ruby + Go)
  │ substrate mkRustService
  ▼
Docker image (GHCR)
  │ helmworks chart + pleme-lib
  ▼
K8s deployment (FluxCD)
  │ Vector + NATS
  ▼
Observability (Grafana + Loki + VictoriaMetrics)
```

### Pattern 2: Declare → Synthesize → Plan → Apply → Verify

The canonical lifecycle of any infrastructure:

```
Ruby DSL (Pangea architecture)
  │ TerraformSynthesizer / TypedArraySynthesizer
  ▼
Terraform JSON / Packer JSON
  │ pangea-operator InfrastructureTemplate
  ▼
tofu plan / packer build
  │ pangea-operator controllers
  ▼
Applied infrastructure
  │ ComplianceSchedule (kensa + InSpec)
  ▼
Verified + attested (tameshi + sekiban)
```

### Pattern 3: Build AMI → Test → Deploy → Verify → Gate

The image pipeline composition:

```
SynthesizerFormat (CRD-defined Packer format)
  │ PackerBuild (Ruby DSL → JSON → packer build)
  ▼
AMI (EC2 image)
  │ AmiTest (boot + cluster + compliance DAG)
  ▼
Tested AMI
  │ ImagePipeline (patch template → plan → approve → apply)
  ▼
Running cluster
  │ ComplianceBinding (continuous verification → gate/react)
  ▼
Compliant infrastructure
```

### Pattern 4: Format → Compile → Execute → Extract

The synthesizer composition (universal for any tool output):

```
SynthesizerFormat CRD (array sections + map sections + key transform)
  │ TypedArraySynthesizer (Ruby, runtime materialization)
  ▼
Ruby DSL evaluation
  │ method_missing → add_typed_entry / add_map_entry
  ▼
Structured JSON (Packer / Ansible / GitHub Actions / custom)
  │ Tool-specific executor (PackerExecutor / TofuExecutor / etc.)
  ▼
Tool output (AMI ID / Terraform state / Ansible facts)
```

---

## 6. Version 1.0 Scope

### What v1.0 includes:

1. **Build domain** — substrate builders for Rust, Go, Zig, TypeScript, Ruby, WASM, Web
2. **Deploy domain** — pleme-lib v0.4 with 21 templates + proposed operator patterns
3. **Infra domain** — Pangea synthesizer framework with 9 operator CRDs
4. **Lifecycle domain** — forge-gen + iac-forge + mcp-forge + completion-forge
5. **Observation layer** — Vector + NATS + Loki + VictoriaMetrics (Shinryu)
6. **Attestation** — tameshi + sekiban + kensa (integrity gating)
7. **Cross-domain morphisms** — Nix→Helm, Pangea→Helm, Forge→Pangea documented

### What v1.0 does NOT include (v2.0):

1. **PipelineGraph CRD** — Reactive dependency chains across resource types
2. **SynthesizerFormat → forge-gen bridge** — Auto-generate synthesizers from OpenAPI
3. **pleme-lib v0.5 operator patterns** — `_operator.tpl`, `_crd-rbac.tpl`, etc.
4. **Cross-cluster federation** — Multi-cluster composition patterns
5. **Cost optimization layer** — Resource right-sizing from observation data

---

## 7. Invariants (must hold for all compositions)

1. **Reproducibility** — Same inputs always produce same outputs (Nix guarantees this for builds, Pangea for IaC, Helm for deploy manifests)
2. **Typed boundaries** — Every domain boundary has a typed morphism, never a string
3. **Security baseline** — Every workload runs non-root, drops all capabilities, readonly rootfs
4. **Observable by default** — Every primitive emits to the observation layer without opt-in
5. **No imperative escape hatches** — No shell scripts in Helm, no raw exec in Pangea, no manual kubectl
6. **Attestable** — Every artifact can be BLAKE3-hashed and included in a tameshi certification chain
7. **Pinned dependencies** — All flakes pin to stable nixpkgs (nixos-25.11), all Helm charts pin pleme-lib version
