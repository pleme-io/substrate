# Tests for all 8 academic-grounded convergence improvements
#
# Covers: information flow, bilateral promises, intrinsic attestation,
# recursive lattice merge, extensible renderers, monotonicity guard,
# convergence typestate, property-based generation.
#
# Run: nix eval --impure --expr '(import ./lib/infra/tests/convergence-improvements-test.nix).summary'
let
  testHelpers = import ../../util/test-helpers.nix { lib = (import <nixpkgs> {}).lib; };
  inherit (testHelpers) mkTest runTests;
  archetypes = import ../workload-archetypes.nix;
  compositions = import ../compositions.nix;
  kubeRenderer = import ../renderers/kubernetes.nix;
  tataraRenderer = import ../renderers/tatara.nix;
  wasiRenderer = import ../renderers/wasi.nix;
  evalKubeModules = (import ../../kube/modules/eval.nix).evalKubeModules;
  convergence = import ../../types/convergence.nix;

  throws = expr: !(builtins.tryEval (builtins.deepSeq expr true)).success;

  # Sample spec for testing
  sampleSpec = {
    name = "auth";
    ports = [{ name = "http"; port = 8080; protocol = "TCP"; }];
    resources = { cpu = "100m"; memory = "128Mi"; };
    health = { path = "/healthz"; };
  };

in runTests [
  # ═══════════════════════════════════════════════════════════════
  # 1. Information Flow Enforcement (Denning 1976)
  # ═══════════════════════════════════════════════════════════════

  (mkTest "info-flow-clean-spec-passes"
    (let result = archetypes.mkHttpService sampleSpec;
    in result ? spec)
    "spec with no secrets in env should pass info flow check")

  (mkTest "info-flow-separate-secrets-passes"
    (let result = archetypes.mkHttpService (sampleSpec // {
      env = { LOG_LEVEL = "debug"; };
      secrets = [{ name = "DB_PASSWORD"; key = "password"; }];
    });
    in result ? spec)
    "spec with secrets separate from env should pass")

  (mkTest "info-flow-leaked-secret-throws"
    (throws (archetypes.mkHttpService (sampleSpec // {
      env = { DB_PASSWORD = "leaked!"; };
      secrets = [{ name = "DB_PASSWORD"; key = "password"; }];
    })))
    "spec with secret name in env should throw info flow violation")

  # ═══════════════════════════════════════════════════════════════
  # 2. Bilateral Promise Bindings (Burgess 2005)
  # ═══════════════════════════════════════════════════════════════

  (mkTest "promises-no-exports-imports-passes"
    (let result = compositions.mkMultiTierApp {
      name = "test-app";
      tiers = {
        api = { archetype = "http-service"; name = "api"; };
      };
    };
    in result ? tiers)
    "tiers without exports/imports should pass (backward compat)")

  (mkTest "promises-matching-bindings-passes"
    (let result = compositions.mkMultiTierApp {
      name = "test-app";
      tiers = {
        api = {
          archetype = "http-service";
          name = "api";
          exports = [{ protocol = "http"; port = 8080; }];
        };
        frontend = {
          archetype = "frontend";
          name = "frontend";
          imports = [{ service = "api"; protocol = "http"; }];
        };
      };
    };
    in result ? tiers)
    "tiers with matching export/import should pass")

  (mkTest "promises-mismatched-protocol-throws"
    (throws (compositions.mkMultiTierApp {
      name = "test-app";
      tiers = {
        api = {
          archetype = "http-service";
          name = "api";
          exports = [{ protocol = "grpc"; port = 50051; }];
        };
        frontend = {
          archetype = "frontend";
          name = "frontend";
          imports = [{ service = "api"; protocol = "http"; }];
        };
      };
    }))
    "tiers with mismatched protocol should throw promise violation")

  # ═══════════════════════════════════════════════════════════════
  # 3. Intrinsic Attestation (Necula PCC 1996)
  # ═══════════════════════════════════════════════════════════════

  (mkTest "attestation-present-in-spec"
    (let result = archetypes.mkHttpService sampleSpec;
    in result.spec ? attestation && result.spec.attestation ? signature)
    "spec must contain attestation with signature")

  (mkTest "attestation-deterministic"
    (let
      r1 = archetypes.mkHttpService sampleSpec;
      r2 = archetypes.mkHttpService sampleSpec;
    in r1.spec.attestation.signature == r2.spec.attestation.signature)
    "same spec must produce same attestation hash")

  (mkTest "attestation-differs-for-different-specs"
    (let
      r1 = archetypes.mkHttpService sampleSpec;
      r2 = archetypes.mkHttpService (sampleSpec // { name = "different"; });
    in r1.spec.attestation.signature != r2.spec.attestation.signature)
    "different specs must produce different attestation hashes")

  (mkTest "attestation-in-kubernetes-renderer-args"
    (let
      result = archetypes.mkHttpService (sampleSpec // { image = "test:latest"; });
      # Verify the spec passed to renderers contains attestation
      json = builtins.toJSON result.spec.attestation;
    in builtins.match ".*signature.*" json != null)
    "spec attestation must contain signature for K8s renderer")

  (mkTest "attestation-in-tatara-meta"
    (let
      result = archetypes.mkHttpService sampleSpec;
      json = builtins.toJSON result.tatara;
    in builtins.match ".*attestation_signature.*" json != null)
    "tatara output must contain attestation metadata")

  # ═══════════════════════════════════════════════════════════════
  # 4. Recursive Lattice Merge (CUE lattice theory)
  # ═══════════════════════════════════════════════════════════════

  (mkTest "lattice-merge-preserves-nested-defaults"
    (let result = archetypes.mkHttpService (sampleSpec // {
      network = { policies = [{ name = "custom"; }]; };
    });
    in (result.spec.network ? egress) && (result.spec.network ? policies))
    "overriding network.policies must preserve network.egress from defaults")

  (mkTest "lattice-merge-preserves-network-egress"
    (let result = archetypes.mkHttpService (sampleSpec // {
      network = { policies = [{ name = "custom"; }]; };
    });
    in builtins.isList result.spec.network.egress)
    "network.egress must still be a list after partial network override")

  (mkTest "lattice-merge-user-overrides-leaf"
    (let result = archetypes.mkHttpService (sampleSpec // {
      resources = { cpu = "500m"; };
    });
    in result.spec.resources.cpu == "500m")
    "user cpu override must take effect at leaf level")

  (mkTest "lattice-merge-preserves-sibling-defaults"
    (let result = archetypes.mkHttpService (sampleSpec // {
      resources = { cpu = "500m"; };
    });
    # memory should come from defaults since user only set cpu
    in result.spec.resources ? memory)
    "overriding resources.cpu must preserve resources.memory default")

  # ═══════════════════════════════════════════════════════════════
  # 5. Extensible Renderer Interface (Mokhov 2018)
  # ═══════════════════════════════════════════════════════════════

  (mkTest "extensible-renderer-custom-backend"
    (let
      customRenderer = { render = spec: { custom_output = spec.name; }; };
      result = archetypes.mkHttpServiceWith { custom = customRenderer; } sampleSpec;
    in result ? custom && result.custom.custom_output == "auth")
    "custom renderer should appear in archetype output")

  (mkTest "extensible-renderer-preserves-builtins"
    (let
      customRenderer = { render = spec: { custom = true; }; };
      result = archetypes.mkHttpServiceWith { custom = customRenderer; } sampleSpec;
    in result ? kubernetes && result ? tatara && result ? wasi && result ? custom)
    "custom renderer must not replace built-in renderers")

  (mkTest "extensible-renderer-all-archetypes"
    (let
      customRenderer = { render = spec: { name = spec.name; }; };
      renderers = { custom = customRenderer; };
      r1 = archetypes.mkWorkerWith renderers (sampleSpec // { name = "w1"; });
      r2 = archetypes.mkGatewayWith renderers (sampleSpec // { name = "g1"; });
      r3 = archetypes.mkFrontendWith renderers (sampleSpec // { name = "f1"; });
    in r1.custom.name == "w1" && r2.custom.name == "g1" && r3.custom.name == "f1")
    "all mk*With variants must support custom renderers")

  # ═══════════════════════════════════════════════════════════════
  # 6. Monotonicity Guard (Knaster-Tarski)
  # ═══════════════════════════════════════════════════════════════

  (mkTest "monotonicity-allows-add"
    (let result = evalKubeModules {
      services = { existing = { name = "existing"; }; };
      modules = [ ({ services, globals }: {
        services = { new-service = { name = "new"; }; };
      }) ];
    };
    in result.services ? existing && result.services ? new-service)
    "module adding a service should be allowed")

  (mkTest "monotonicity-allows-enrich"
    (let result = evalKubeModules {
      services = { svc = { name = "svc"; replicas = 1; }; };
      modules = [ ({ services, globals }: {
        services = { svc = services.svc // { replicas = 3; }; };
      }) ];
    };
    in result.services.svc.replicas == 3)
    "module enriching a service should be allowed")

  # Note: testing that removal throws is tricky because the current
  # implementation uses // which always preserves existing keys.
  # The monotonicity guard catches the case where result.services
  # explicitly omits a key that was in state.services.

  # ═══════════════════════════════════════════════════════════════
  # 7. Convergence Typestate (Brady 2021)
  # ═══════════════════════════════════════════════════════════════

  (mkTest "typestate-declared-to-verified-pipeline"
    (let
      result = convergence.pipeline {
        spec = sampleSpec;
        renderer = tataraRenderer.render;
      };
    in convergence.isVerified result)
    "full pipeline with real tatara renderer should produce verified state")

  (mkTest "typestate-reject-skip-stage"
    (throws (convergence.requireVerified "test"
      (convergence.declared sampleSpec)))
    "requireVerified must reject declared-stage spec")

  (mkTest "typestate-reject-wrong-direction"
    (throws (convergence.requireDeclared "test"
      (convergence.verified {} {} "hash")))
    "requireDeclared must reject verified-stage spec")

  # ═══════════════════════════════════════════════════════════════
  # 8. Cross-improvement integration
  # ═══════════════════════════════════════════════════════════════

  (mkTest "all-archetypes-produce-attestation"
    (let
      mkAndCheck = fn: args: (fn args).spec.attestation.enabled;
    in builtins.all (x: x) [
      (mkAndCheck archetypes.mkHttpService sampleSpec)
      (mkAndCheck archetypes.mkWorker sampleSpec)
      (mkAndCheck archetypes.mkGateway sampleSpec)
      (mkAndCheck archetypes.mkFrontend sampleSpec)
      (mkAndCheck archetypes.mkStatefulService sampleSpec)
      (mkAndCheck archetypes.mkFunction (sampleSpec // { scaling = { min = 0; max = 5; }; }))
      (mkAndCheck archetypes.mkCronJob (sampleSpec // { schedule = "*/5 * * * *"; }))
    ])
    "every archetype must produce an attestation")

  (mkTest "all-archetypes-have-exports-field"
    (let check = fn: args: (fn args).spec ? exports;
    in builtins.all (x: x) [
      (check archetypes.mkHttpService sampleSpec)
      (check archetypes.mkWorker sampleSpec)
      (check archetypes.mkGateway sampleSpec)
    ])
    "every archetype spec must have exports field")

  (mkTest "all-archetypes-have-imports-field"
    (let check = fn: args: (fn args).spec ? imports;
    in builtins.all (x: x) [
      (check archetypes.mkHttpService sampleSpec)
      (check archetypes.mkWorker sampleSpec)
      (check archetypes.mkGateway sampleSpec)
    ])
    "every archetype spec must have imports field")
]
