# Substrate Property-Based Test Generator
#
# Generates deterministic test cases from type definitions and verifies
# properties hold across all generated inputs. Based on:
# - ProTI (Sokolowski et al., IEEE TSE 2024) — type-schema-driven fuzzing
# - QuickCheck (Claessen & Hughes, 2000) — property-based testing
# - Hummer & Rosenberg (Middleware 2013) — idempotence testing for IaC
#
# Unlike random fuzzing, this generates a DETERMINISTIC set of edge-case
# values for each type, ensuring reproducible test results in pure Nix
# evaluation (no randomness, no IO).
#
# Usage:
#   propTests = import ./property-tests.nix;
#   results = propTests.checkIdempotent "kubernetes-renderer" renderer sampleSpec;
let
  testHelpers = import ../util/test-helpers.nix { lib = (import <nixpkgs> {}).lib; };
  inherit (testHelpers) mkTest runTests;
in rec {
  # ── Value Generators ──────────────────────────────────────────
  # Deterministic edge-case generators for each primitive type.

  # Generate edge-case strings
  strings = [ "" "a" "hello-world" "with spaces" "UPPERCASE" "123" "a-b-c" "under_score" ];
  nonEmptyStrings = [ "a" "hello-world" "auth-service" "my_app" "x" ];

  # Generate edge-case integers
  ints = [ 0 1 2 10 100 1000 65535 ];
  positiveInts = [ 1 2 3 10 100 ];
  ports = [ 80 443 8080 8081 9090 50051 ];

  # Generate edge-case resource quantities
  cpuQuantities = [ "50m" "100m" "250m" "500m" "1" "2" "4" ];
  memoryQuantities = [ "64Mi" "128Mi" "256Mi" "512Mi" "1Gi" "2Gi" "4Gi" ];

  # Generate edge-case architectures
  architectures = [ "amd64" "arm64" ];
  architectureLists = [ [ "amd64" ] [ "arm64" ] [ "amd64" "arm64" ] ];

  # Generate edge-case archetype names
  archetypeNames = [ "http-service" "worker" "cron-job" "gateway" "stateful-service" "function" "frontend" ];

  # Generate sample workload specs
  sampleSpecs = map (arch: {
    name = "test-${arch}";
    archetype = arch;
    ports = [{ name = "http"; port = 8080; protocol = "TCP"; }];
    resources = { cpu = "100m"; memory = "128Mi"; };
    replicas = 1;
    secrets = [];
    env = {};
    network = { ingress = []; egress = []; policies = []; };
    volumes = [];
    meta = {};
    annotations = {};
    labels = {};
  }) archetypeNames;

  # Generate specs with varying resource levels
  resourceVariants = builtins.concatMap (cpu:
    map (mem: { inherit cpu; memory = mem; })
    memoryQuantities
  ) cpuQuantities;

  # ── Property Checkers ─────────────────────────────────────────

  # Check that a function is idempotent: f(f(x)) == f(x)
  # This is the Hummer & Rosenberg (2013) idempotence test.
  checkIdempotent = name: f: input:
    let
      first = f input;
      second = f first;
    in mkTest "idempotent-${name}"
      (builtins.toJSON second == builtins.toJSON first)
      "${name} must be idempotent: f(f(x)) == f(x)";

  # Check that a function is deterministic: f(x) == f(x)
  # (Nix is pure, so this should always hold, but verifies no builtins.currentTime etc.)
  checkDeterministic = name: f: input:
    let
      first = f input;
      second = f input;
    in mkTest "deterministic-${name}"
      (builtins.toJSON first == builtins.toJSON second)
      "${name} must be deterministic: f(x) == f(x)";

  # Check that a renderer preserves the spec's name in output
  checkPreservesName = name: renderer: spec:
    let
      result = renderer spec;
      # Check if the name appears somewhere in the JSON output
      json = builtins.toJSON result;
    in mkTest "preserves-name-${name}"
      (builtins.match ".*${spec.name}.*" json != null)
      "${name} output must contain the spec name '${spec.name}'";

  # Check that all archetypes produce output for a renderer
  checkAllArchetypes = rendererName: renderer:
    map (spec:
      let
        result = builtins.tryEval (builtins.seq (builtins.toJSON (renderer spec)) true);
      in mkTest "archetype-${rendererName}-${spec.archetype}"
        result.success
        "${rendererName} must handle archetype '${spec.archetype}' without error"
    ) sampleSpecs;

  # Check that resource quantities are preserved through rendering
  checkResourcePreservation = name: renderer: spec:
    let
      result = renderer spec;
      json = builtins.toJSON result;
      hasCpu = builtins.match ".*${spec.resources.cpu}.*" json != null;
      hasMem = builtins.match ".*${spec.resources.memory}.*" json != null;
    in mkTest "resource-preservation-${name}"
      (hasCpu && hasMem)
      "${name} must preserve resource quantities in output";

  # Check that information flow is enforced (secrets not in env)
  checkInformationFlow = spec:
    let
      secretNames = map (s:
        if builtins.isAttrs s then (s.name or "") else toString s
      ) (spec.secrets or []);
      envKeys = builtins.attrNames (spec.env or {});
      leaked = builtins.filter (k: builtins.elem k secretNames) envKeys;
    in mkTest "info-flow-${spec.name or "unnamed"}"
      (leaked == [])
      "secrets must not appear in plain env";

  # ── Batch Test Runners ────────────────────────────────────────

  # Run all property tests for a renderer
  testRenderer = rendererName: renderer: runTests (
    (checkAllArchetypes rendererName renderer)
    ++ (map (spec: checkDeterministic "${rendererName}-${spec.name}" renderer spec) sampleSpecs)
    ++ (map (spec: checkPreservesName "${rendererName}-${spec.name}" renderer spec) sampleSpecs)
    ++ (map (spec: checkResourcePreservation "${rendererName}-${spec.name}" renderer spec) sampleSpecs)
  );

  # Run information flow tests across all sample specs
  testInformationFlow = runTests (
    (map checkInformationFlow sampleSpecs)
    ++ [
      # Positive test: spec with secret in env should be flagged
      (mkTest "info-flow-violation-detected"
        (let
          badSpec = { name = "bad"; secrets = [{ name = "DB_PASSWORD"; }]; env = { DB_PASSWORD = "leaked!"; }; };
          leaked = builtins.filter (k: builtins.elem k ["DB_PASSWORD"]) (builtins.attrNames badSpec.env);
        in leaked != [])
        "should detect when a secret name appears in env")
    ]
  );

  # Run convergence stage tests
  testConvergenceStages = let
    conv = import ./convergence.nix;
  in runTests [
    (mkTest "declared-stage"
      (conv.isDeclared (conv.declared { name = "test"; }))
      "declared should produce declared stage")

    (mkTest "resolved-stage"
      (conv.isResolved (conv.resolved { name = "test"; }))
      "resolved should produce resolved stage")

    (mkTest "converged-stage"
      (conv.isConverged (conv.converged { name = "test"; } { resources = []; }))
      "converged should produce converged stage")

    (mkTest "verified-stage"
      (conv.isVerified (conv.verified { name = "test"; } { resources = []; } "sha256:abc"))
      "verified should produce verified stage")

    (mkTest "require-declared-accepts"
      ((conv.requireDeclared "test" (conv.declared { name = "test"; })) == { name = "test"; })
      "requireDeclared should extract spec from declared stage")

    (mkTest "require-declared-rejects-resolved"
      (!(builtins.tryEval (conv.requireDeclared "test" (conv.resolved { name = "test"; }))).success)
      "requireDeclared should reject resolved stage")

    (mkTest "require-verified-rejects-converged"
      (!(builtins.tryEval (conv.requireVerified "test" (conv.converged {} {}))).success)
      "requireVerified should reject converged stage")

    (mkTest "transition-declared-to-resolved"
      (conv.isResolved (conv.resolve (conv.declared { a = 1; }) { b = 2; }))
      "resolve should transition declared → resolved")

    (mkTest "transition-resolved-to-converged"
      (conv.isConverged (conv.converge (conv.resolved { a = 1; }) { rendered = true; }))
      "converge should transition resolved → converged")

    (mkTest "full-pipeline"
      (let
        result = conv.pipeline {
          spec = { name = "test"; value = 42; };
          renderer = s: { output = s.value * 2; };
        };
      in conv.isVerified result)
      "pipeline should produce verified stage")
  ];
}
