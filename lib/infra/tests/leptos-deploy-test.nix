# Test: Verify Leptos PWA archetype renders to all backends.
#
# Run:
#   nix eval --impure --expr '(import ./lib/infra/tests/leptos-deploy-test.nix { lib = (import <nixpkgs> {}).lib; }).allPassed'
#   nix eval --json --impure --expr '(import ./lib/infra/tests/leptos-deploy-test.nix { lib = (import <nixpkgs> {}).lib; }).summary'
{ lib }:

let
  archetypes = import ../workload-archetypes.nix;
  testHelpers = import ../../util/test-helpers.nix { inherit lib; };

  # Create a test Leptos service
  svc = archetypes.mkHttpService {
    name = "test-leptos";
    image = "ghcr.io/test/leptos:latest";
    ports = [{ name = "http"; port = 3000; protocol = "http"; }];
    health = { path = "/healthz"; port = 3000; };
    resources = { cpu = "200m"; memory = "256Mi"; };
    scaling = { min = 2; max = 10; };
    env = { LEPTOS_SITE_ADDR = "0.0.0.0:3000"; };
    network = { egress = [{ to = "hanabi"; port = 8080; }]; };
    meta = { namespace = "test"; };
    labels = { "app.pleme.io/component" = "web"; };
  };

  tests = [
    # ── Spec fields ─────────────────────────────────────────────
    (testHelpers.mkTest "spec-name"
      (svc.spec.name == "test-leptos")
      "spec.name should be test-leptos")

    (testHelpers.mkTest "spec-archetype"
      (svc.spec.archetype == "http-service")
      "spec.archetype should be http-service")

    (testHelpers.mkTest "spec-port"
      ((builtins.head svc.spec.ports).port == 3000)
      "spec.ports[0].port should be 3000")

    (testHelpers.mkTest "spec-health-path"
      (svc.spec.health.path == "/healthz")
      "spec.health.path should be /healthz")

    (testHelpers.mkTest "spec-scaling-min"
      (svc.spec.scaling.min == 2)
      "spec.scaling.min should be 2")

    (testHelpers.mkTest "spec-scaling-max"
      (svc.spec.scaling.max == 10)
      "spec.scaling.max should be 10")

    (testHelpers.mkTest "spec-env"
      (svc.spec.env.LEPTOS_SITE_ADDR == "0.0.0.0:3000")
      "spec.env.LEPTOS_SITE_ADDR should be 0.0.0.0:3000")

    (testHelpers.mkTest "spec-image"
      (svc.spec.image == "ghcr.io/test/leptos:latest")
      "spec.image should be set")

    (testHelpers.mkTest "spec-labels"
      (svc.spec.labels."app.pleme.io/component" == "web")
      "spec.labels should contain component label")

    # ── Backend presence ────────────────────────────────────────
    (testHelpers.mkTest "has-spec"
      (svc ? spec)
      "result should have spec")

    (testHelpers.mkTest "has-tatara"
      (svc ? tatara)
      "result should have tatara")

    (testHelpers.mkTest "has-wasi"
      (svc ? wasi)
      "result should have wasi")

    (testHelpers.mkTest "has-kubernetes"
      (svc ? kubernetes)
      "result should have kubernetes")

    # ── Tatara rendering ────────────────────────────────────────
    (testHelpers.mkTest "tatara-job-type"
      (svc.tatara.job_type == "service")
      "tatara.job_type should be service")

    (testHelpers.mkTest "tatara-id"
      (svc.tatara.id == "test-leptos")
      "tatara.id should match spec name")

    (testHelpers.mkTest "tatara-has-groups"
      (builtins.length svc.tatara.groups > 0)
      "tatara should have at least one group")

    (testHelpers.mkTest "tatara-driver-oci"
      ((builtins.head (builtins.head svc.tatara.groups).tasks).driver == "oci")
      "tatara driver should be oci when image is set")

    (testHelpers.mkTest "tatara-env"
      ((builtins.head (builtins.head svc.tatara.groups).tasks).env.LEPTOS_SITE_ADDR == "0.0.0.0:3000")
      "tatara task env should contain LEPTOS_SITE_ADDR")

    (testHelpers.mkTest "tatara-resources-cpu"
      ((builtins.head (builtins.head svc.tatara.groups).tasks).resources.cpu_mhz == 200)
      "tatara resources cpu_mhz should be 200")

    (testHelpers.mkTest "tatara-resources-mem"
      ((builtins.head (builtins.head svc.tatara.groups).tasks).resources.memory_mb == 256)
      "tatara resources memory_mb should be 256")

    (testHelpers.mkTest "tatara-health-check"
      (builtins.length (builtins.head (builtins.head svc.tatara.groups).tasks).health_checks > 0)
      "tatara should have health checks")

    # ── WASI rendering ──────────────────────────────────────────
    # wasmPath is null so WASI renders a stub config
    (testHelpers.mkTest "wasi-has-name"
      (svc.wasi ? name)
      "wasi should have name field")

    (testHelpers.mkTest "wasi-has-capabilities"
      (svc.wasi ? capabilities)
      "wasi should have capabilities field")

    # ── WASI with wasmPath (full rendering) ─────────────────────
    (let
      wasmSvc = archetypes.mkHttpService {
        name = "test-leptos-wasm";
        wasmPath = "/path/to/lilitu-web.wasm";
        ports = [{ name = "http"; port = 3000; protocol = "http"; }];
        health = { path = "/healthz"; port = 3000; };
        resources = { cpu = "200m"; memory = "256Mi"; };
        network = { egress = [{ to = "hanabi"; port = 8080; }]; };
      };
    in testHelpers.mkTest "wasi-full-world"
      (wasmSvc.wasi.world == "tatara-service")
      "wasi world should be tatara-service for HTTP services")

    (let
      wasmSvc = archetypes.mkHttpService {
        name = "test-leptos-wasm";
        wasmPath = "/path/to/lilitu-web.wasm";
        ports = [{ name = "http"; port = 3000; protocol = "http"; }];
        resources = { cpu = "200m"; memory = "256Mi"; };
        network = { egress = [{ to = "hanabi"; port = 8080; }]; };
      };
    in testHelpers.mkTest "wasi-full-network"
      (wasmSvc.wasi.capabilities.network == true)
      "wasi network capability should be true when ports/egress exist")

    (let
      wasmSvc = archetypes.mkHttpService {
        name = "test-leptos-wasm";
        wasmPath = "/path/to/lilitu-web.wasm";
        ports = [{ name = "http"; port = 3000; protocol = "http"; }];
        resources = { cpu = "200m"; memory = "256Mi"; };
      };
    in testHelpers.mkTest "wasi-full-exports"
      (builtins.elem "wasi:http/incoming-handler@0.2.0" wasmSvc.wasi.exports)
      "wasi should export http incoming-handler for HTTP services")

    (let
      wasmSvc = archetypes.mkHttpService {
        name = "test-leptos-wasm";
        wasmPath = "/path/to/lilitu-web.wasm";
        ports = [{ name = "http"; port = 3000; protocol = "http"; }];
        resources = { cpu = "200m"; memory = "256Mi"; };
      };
    in testHelpers.mkTest "wasi-full-fuel"
      (wasmSvc.wasi.fuel == 200000000)
      "wasi fuel should be 200m * 1000000 = 200000000")

    (let
      wasmSvc = archetypes.mkHttpService {
        name = "test-leptos-wasm";
        wasmPath = "/path/to/lilitu-web.wasm";
        ports = [{ name = "http"; port = 3000; protocol = "http"; }];
        resources = { cpu = "200m"; memory = "256Mi"; };
      };
    in testHelpers.mkTest "wasi-full-memory"
      (wasmSvc.wasi.max_memory_bytes == 256 * 1024 * 1024)
      "wasi max_memory_bytes should be 256Mi in bytes")

    # ── Kubernetes rendering ────────────────────────────────────
    (testHelpers.mkTest "kubernetes-is-list"
      (builtins.isList svc.kubernetes)
      "kubernetes output should be an ordered resource list")

    (testHelpers.mkTest "kubernetes-has-resources"
      (builtins.length svc.kubernetes > 0)
      "kubernetes should produce at least one resource")
  ];

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  # Re-export for convenience
  inherit tests result;
}
