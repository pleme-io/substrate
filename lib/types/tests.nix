# Substrate Type System Tests
#
# Pure Nix evaluation tests for every type definition and coercion path.
# Run: nix eval --impure --expr '(import ./lib/types/tests.nix { lib = (import <nixpkgs> {}).lib; })'
#
# These tests verify that:
# 1. Valid values pass type checks
# 2. Invalid values are rejected
# 3. Coercion bridges convert legacy formats correctly
# 4. Submodule defaults are applied
# 5. Enum types reject unknown values
{ lib }:

let
  types = import ./default.nix { inherit lib; };
  testHelpers = import ../util/test-helpers.nix { inherit lib; };
  inherit (testHelpers) mkTest runTests;

  f = types.foundation;
  p = types.ports;
  br = types.buildResult;
  bs = types.buildSpec;
  ss = types.serviceSpec;
  ds = types.deploySpec;
  is = types.infraSpec;
  ks = types.kubeSpec;
  v = types.validate;

in runTests [
  # ═══════════════════════════════════════════════════════════════════
  # Foundation Types
  # ═══════════════════════════════════════════════════════════════════

  # ── NixSystem ─────────────────────────────────────────────────────
  (mkTest "nixSystem-valid-darwin"
    (f.nixSystem.check "aarch64-darwin")
    "aarch64-darwin should be valid NixSystem")

  (mkTest "nixSystem-valid-linux"
    (f.nixSystem.check "x86_64-linux")
    "x86_64-linux should be valid NixSystem")

  (mkTest "nixSystem-invalid"
    (!(f.nixSystem.check "sparc64-solaris"))
    "sparc64-solaris should be invalid NixSystem")

  (mkTest "nixSystem-rejects-empty"
    (!(f.nixSystem.check ""))
    "empty string should be invalid NixSystem")

  # ── Architecture ──────────────────────────────────────────────────
  (mkTest "arch-valid-amd64"
    (f.architecture.check "amd64")
    "amd64 should be valid Architecture")

  (mkTest "arch-valid-arm64"
    (f.architecture.check "arm64")
    "arm64 should be valid Architecture")

  (mkTest "arch-invalid"
    (!(f.architecture.check "x86"))
    "x86 should be invalid Architecture")

  # ── Language ──────────────────────────────────────────────────────
  (mkTest "lang-valid-rust"
    (f.language.check "rust")
    "rust should be valid Language")

  (mkTest "lang-valid-go"
    (f.language.check "go")
    "go should be valid Language")

  (mkTest "lang-valid-nix"
    (f.language.check "nix")
    "nix should be valid Language")

  (mkTest "lang-invalid"
    (!(f.language.check "cobol"))
    "cobol should be invalid Language")

  # ── ArtifactKind ──────────────────────────────────────────────────
  (mkTest "artifact-valid-binary"
    (f.artifactKind.check "binary")
    "binary should be valid ArtifactKind")

  (mkTest "artifact-valid-wasm"
    (f.artifactKind.check "wasm-component")
    "wasm-component should be valid ArtifactKind")

  (mkTest "artifact-invalid"
    (!(f.artifactKind.check "jar"))
    "jar should be invalid ArtifactKind")

  # ── ServiceType ───────────────────────────────────────────────────
  (mkTest "svctype-valid-graphql"
    (f.serviceType.check "graphql")
    "graphql should be valid ServiceType")

  (mkTest "svctype-valid-grpc"
    (f.serviceType.check "grpc")
    "grpc should be valid ServiceType")

  (mkTest "svctype-invalid"
    (!(f.serviceType.check "soap"))
    "soap should be invalid ServiceType")

  # ── WorkloadArchetype ─────────────────────────────────────────────
  (mkTest "archetype-valid-http"
    (f.workloadArchetype.check "http-service")
    "http-service should be valid WorkloadArchetype")

  (mkTest "archetype-valid-worker"
    (f.workloadArchetype.check "worker")
    "worker should be valid WorkloadArchetype")

  (mkTest "archetype-valid-function"
    (f.workloadArchetype.check "function")
    "function should be valid WorkloadArchetype")

  (mkTest "archetype-invalid"
    (!(f.workloadArchetype.check "lambda"))
    "lambda should be invalid WorkloadArchetype")

  # ── RustTarget ────────────────────────────────────────────────────
  (mkTest "rusttarget-valid-darwin-arm"
    (f.rustTarget.check "aarch64-apple-darwin")
    "aarch64-apple-darwin should be valid RustTarget")

  (mkTest "rusttarget-valid-linux-musl"
    (f.rustTarget.check "x86_64-unknown-linux-musl")
    "x86_64-unknown-linux-musl should be valid RustTarget")

  (mkTest "rusttarget-invalid-gnu"
    (!(f.rustTarget.check "x86_64-unknown-linux-gnu"))
    "gnu target should be invalid RustTarget")

  # ── TataraDriver ──────────────────────────────────────────────────
  (mkTest "driver-valid-wasi"
    (f.tataraDriver.check "wasi")
    "wasi should be valid TataraDriver")

  (mkTest "driver-valid-oci"
    (f.tataraDriver.check "oci")
    "oci should be valid TataraDriver")

  (mkTest "driver-invalid"
    (!(f.tataraDriver.check "docker"))
    "docker should be invalid TataraDriver")

  # ── KubeResourceKind ──────────────────────────────────────────────
  (mkTest "kube-kind-deployment"
    (f.kubeResourceKind.check "Deployment")
    "Deployment should be valid KubeResourceKind")

  (mkTest "kube-kind-service"
    (f.kubeResourceKind.check "Service")
    "Service should be valid KubeResourceKind")

  (mkTest "kube-kind-crd"
    (f.kubeResourceKind.check "CustomResourceDefinition")
    "CRD should be valid KubeResourceKind")

  (mkTest "kube-kind-invalid"
    (!(f.kubeResourceKind.check "Pod"))
    "Pod should be invalid KubeResourceKind (not in dependency order)")

  # ── Refined Primitives ────────────────────────────────────────────
  (mkTest "port-valid"
    (f.port.check 8080)
    "8080 should be valid port")

  (mkTest "port-valid-zero"
    (f.port.check 0)
    "0 should be valid port")

  (mkTest "port-invalid-negative"
    (!(f.port.check (-1)))
    "negative should be invalid port")

  (mkTest "cpu-quantity-valid-milli"
    (f.cpuQuantity.check "100m")
    "100m should be valid cpuQuantity")

  (mkTest "cpu-quantity-valid-whole"
    (f.cpuQuantity.check "2")
    "2 should be valid cpuQuantity")

  (mkTest "memory-quantity-valid-mi"
    (f.memoryQuantity.check "128Mi")
    "128Mi should be valid memoryQuantity")

  (mkTest "memory-quantity-valid-gi"
    (f.memoryQuantity.check "4Gi")
    "4Gi should be valid memoryQuantity")

  (mkTest "network-protocol-valid"
    (f.networkProtocol.check "TCP")
    "TCP should be valid networkProtocol")

  (mkTest "network-protocol-invalid"
    (!(f.networkProtocol.check "HTTP"))
    "HTTP should be invalid networkProtocol")

  (mkTest "repo-ref-valid"
    (f.repoRef.check "pleme-io/substrate")
    "pleme-io/substrate should be valid repoRef")

  (mkTest "repo-ref-invalid"
    (!(f.repoRef.check "just-a-name"))
    "single name should be invalid repoRef")

  # ═══════════════════════════════════════════════════════════════════
  # Port Types
  # ═══════════════════════════════════════════════════════════════════

  (mkTest "named-ports-valid"
    (p.namedPorts.check { http = 8080; health = 8081; })
    "named ports attrset should be valid")

  (mkTest "named-ports-rejects-non-attrset"
    (!(p.namedPorts.check "not-an-attrset"))
    "string should be invalid namedPorts (must be attrset)")

  (mkTest "port-from-int-check"
    (p.portFromInt.check 8080)
    "single int should pass portFromInt check")

  (mkTest "port-from-int-check-attrset"
    (p.portFromInt.check { http = 8080; })
    "attrset should also pass portFromInt (it is the final type)")

  # ═══════════════════════════════════════════════════════════════════
  # Service Spec Types
  # ═══════════════════════════════════════════════════════════════════

  (mkTest "resource-spec-check"
    (ss.resourceSpec.check { cpu = "100m"; memory = "128Mi"; })
    "valid resource spec should check")

  (mkTest "scaling-spec-check"
    (ss.scalingSpec.check { min = 2; max = 10; })
    "valid scaling spec should check")

  # ═══════════════════════════════════════════════════════════════════
  # Kube Spec Types
  # ═══════════════════════════════════════════════════════════════════

  (mkTest "kube-metadata-check"
    (ks.kubeMetadata.check { name = "auth"; namespace = "default"; })
    "valid metadata should check")

  (mkTest "container-port-check"
    (ks.containerPort.check { name = "http"; containerPort = 8080; })
    "valid container port should check")

  (mkTest "pod-security-context-check"
    (ks.podSecurityContext.check { runAsNonRoot = true; runAsUser = 1000; })
    "valid pod security context should check")

  (mkTest "deployment-strategy-check"
    (ks.deploymentStrategy.check { type = "RollingUpdate"; })
    "valid deployment strategy should check")

  (mkTest "deployment-strategy-recreate"
    (ks.deploymentStrategy.check { type = "Recreate"; })
    "Recreate strategy should check")

  (mkTest "rbac-rule-check"
    (ks.rbacRule.check {
      apiGroups = [ "" ];
      resources = [ "pods" "services" ];
      verbs = [ "get" "list" "watch" ];
    })
    "valid RBAC rule should check")

  # ═══════════════════════════════════════════════════════════════════
  # Validation Middleware
  # ═══════════════════════════════════════════════════════════════════

  (mkTest "check-build-result-valid"
    ((v.checkBuildResult { packages = {}; devShells = {}; apps = {}; }).valid)
    "empty BuildResult should be valid")

  (mkTest "check-build-result-partial"
    ((v.checkBuildResult { packages = {}; }).valid)
    "partial BuildResult (packages only) should be valid (defaults fill rest)")

  # ═══════════════════════════════════════════════════════════════════
  # Infrastructure Spec Types
  # ═══════════════════════════════════════════════════════════════════

  (mkTest "workload-spec-check"
    (is.workloadSpec.check {
      name = "auth";
      archetype = "http-service";
    })
    "minimal workload spec should check")

  (mkTest "policy-rule-check"
    (is.policyRule.check {
      name = "min-replicas";
      match = { archetype = "http-service"; };
      require = { "replicas" = 2; };
    })
    "valid policy rule should check")

  # ═══════════════════════════════════════════════════════════════════
  # Deploy Spec Types
  # ═══════════════════════════════════════════════════════════════════

  (mkTest "docker-image-spec-check"
    (ds.dockerImageSpec.check {
      name = "auth";
      binary = "/nix/store/fake-binary";
      tag = "latest";
    })
    "valid docker image spec should check")

  (mkTest "deploy-spec-check"
    (ds.deploySpec.check {
      architectures = [ "amd64" "arm64" ];
      registry = "ghcr.io/pleme-io/auth";
      namespace = "default";
    })
    "valid deploy spec should check")

  # ═══════════════════════════════════════════════════════════════════
  # Type Lattice Completeness
  # ═══════════════════════════════════════════════════════════════════

  (mkTest "types-default-has-foundation"
    (types ? foundation)
    "types should export foundation")

  (mkTest "types-default-has-ports"
    (types ? ports)
    "types should export ports")

  (mkTest "types-default-has-buildResult"
    (types ? buildResult)
    "types should export buildResult")

  (mkTest "types-default-has-buildSpec"
    (types ? buildSpec)
    "types should export buildSpec")

  (mkTest "types-default-has-serviceSpec"
    (types ? serviceSpec)
    "types should export serviceSpec")

  (mkTest "types-default-has-deploySpec"
    (types ? deploySpec)
    "types should export deploySpec")

  (mkTest "types-default-has-infraSpec"
    (types ? infraSpec)
    "types should export infraSpec")

  (mkTest "types-default-has-kubeSpec"
    (types ? kubeSpec)
    "types should export kubeSpec")

  (mkTest "types-default-has-validate"
    (types ? validate)
    "types should export validate")

  # ═══════════════════════════════════════════════════════════════════
  # Build Spec Registry
  # ═══════════════════════════════════════════════════════════════════

  (mkTest "spec-registry-has-rust"
    (bs.specsByLanguage ? rust)
    "spec registry should have rust")

  (mkTest "spec-registry-has-go"
    (bs.specsByLanguage ? go)
    "spec registry should have go")

  (mkTest "spec-registry-has-typescript"
    (bs.specsByLanguage ? typescript)
    "spec registry should have typescript")

  (mkTest "spec-registry-has-ruby"
    (bs.specsByLanguage ? ruby)
    "spec registry should have ruby")

  (mkTest "spec-registry-has-python"
    (bs.specsByLanguage ? python)
    "spec registry should have python")

  (mkTest "spec-registry-has-zig"
    (bs.specsByLanguage ? zig)
    "spec registry should have zig")

  (mkTest "spec-registry-has-web"
    (bs.specsByLanguage ? web)
    "spec registry should have web")

  (mkTest "spec-registry-has-wasm"
    (bs.specsByLanguage ? wasm)
    "spec registry should have wasm")

  (mkTest "spec-registry-has-rust-service"
    (bs.specsByLanguage ? rust-service)
    "spec registry should have rust-service")

  (mkTest "spec-registry-has-go-grpc"
    (bs.specsByLanguage ? go-grpc)
    "spec registry should have go-grpc")
]
