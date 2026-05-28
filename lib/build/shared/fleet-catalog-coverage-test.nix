# fleet-catalog-coverage-test.nix — substrate-side invariant on
# the fleet-wide dispatcher catalog snapshot
# (dispatcher-fleet-catalog.json).
#
# Catalog entries come from TWO consumer classes (★★ promoted, see
# theory/QUIRK-APPLIER.md §V.1):
#
#   - BUILD-TIME (Nix-dispatched): 9 gen.<eco>.<eco>-quirk entries
#     consumed by substrate/lib/build/<ecosystem>/quirk-apply.nix.
#   - RUNTIME (Rust-dispatched): caixa.upgrade-instruction (and
#     future non-adapter consumers) — no Nix dispatch dir required.
#
# Asserts:
#   1. All known production labels are present.
#   2. variant_count per label matches the typed Rust enum (catches
#      enum-add/-drop drift).
#   3. For build-time entries: substrate/lib/build/<dir>/quirk-apply.nix
#      exists (catches typo + naming-divergence drift). Rust-only
#      entries skip this check.
#
# Refresh the snapshot:
#   - For gen adapters: cargo run --release -p gen-cli -- \
#     --format json dispatchers --from-catalog > <snapshot>
#   - For non-adapter consumers (caixa etc.): merge by hand
#     (gen-cli doesn't link them; each consumer registers in its
#     own crate scope).
#
# Usage:
#   nix-instantiate --eval --strict --json -E \
#     'import ./substrate/lib/build/shared/fleet-catalog-coverage-test.nix {}'
{ lib ? (import <nixpkgs> {}).lib }:
let
  catalog = builtins.fromJSON
    (builtins.readFile ./dispatcher-fleet-catalog.json);

  assertEq = name: expected: actual:
    if expected == actual then "✓ ${name}"
    else throw "✗ ${name}: expected ${builtins.toJSON expected}, got ${builtins.toJSON actual}";

  # Production labels + expected variant counts. Build-time entries
  # carry an `ecosystem` field pointing at their substrate dispatch
  # dir; runtime-only entries set `ecosystem = null` and skip the
  # ecosystem-dir test.
  production = [
    { label = "gen.cargo.crate-quirk";      count = 3; ecosystem = "rust"; }
    { label = "gen.npm.npm-quirk";          count = 5; ecosystem = "npm"; }
    { label = "gen.bundler.bundler-quirk";  count = 5; ecosystem = "bundler"; }
    { label = "gen.helm.helm-quirk";        count = 4; ecosystem = "helm"; }
    { label = "gen.pip.pip-quirk";          count = 4; ecosystem = "pip"; }
    { label = "gen.poetry.poetry-quirk";    count = 4; ecosystem = "poetry"; }
    { label = "gen.gomod.gomod-quirk";      count = 5; ecosystem = "gomod"; }
    { label = "gen.ansible.ansible-quirk";  count = 4; ecosystem = "ansible"; }
    { label = "gen.swift.swift-quirk";      count = 4; ecosystem = "swift"; }
    # ★★ Second class of consumer (non-adapter, Rust-runtime
    # dispatch). caixa-core/src/upgrade.rs's UpgradeInstruction is
    # OTP-style hot-upgrade primitives — load_module / code_change /
    # soft_purge / purge / restart — directly mirroring Erlang's
    # appup.
    { label = "caixa.upgrade-instruction"; count = 5; ecosystem = null; }
    # ★★★ progression — third consumer class: wasm-platform's
    # runtime layer typed-cataloged. WASI capability surface +
    # WASM target triples. The "model side" of the unified
    # computing model (theory/TYPED-ABSORPTION.md): the model
    # provides resources to programs as typed dispatcher entries.
    { label = "wasm-platform.wasi-capability"; count = 8; ecosystem = null; }
    { label = "wasm-platform.wasm-target";     count = 3; ecosystem = null; }
    # Caixa OTP supervisor surface — two more typed shadows over
    # Erlang/OTP supervisor primitives.
    { label = "caixa.restart-strategy"; count = 4; ecosystem = null; }
    { label = "caixa.restart-policy";   count = 3; ecosystem = null; }
    # Fourth consumer class: cofre secret materialization.
    # Backend kind = where the materialized value lives (Sops on
    # disk / Akeyless API / Mock in-memory).
    { label = "cofre.backend-kind"; count = 3; ecosystem = null; }
    # Fifth consumer class: shigoto typed job-scheduler.
    # retry-outcome is the typed decision a RetryPolicy emits when
    # a job fails (retry-with-timestamp or deadletter).
    { label = "shigoto.retry-outcome"; count = 2; ecosystem = null; }
    # Sixth consumer class: engenho fabric (cluster placement +
    # distribution). placement-policy = where a workload may land
    # (zone-aware / rack-aware / latency-aware / spread / none).
    { label = "engenho.placement-policy"; count = 5; ecosystem = null; }
    # Seventh consumer class: magma (Rust-native OpenTofu-compatible
    # IaC executor). resource-kind = taxonomy of what a
    # ResourceAddress points at; action = every legal action a
    # magma plan walker can emit per resource.
    { label = "magma.resource-kind"; count = 5; ecosystem = null; }
    { label = "magma.action";        count = 9; ecosystem = null; }
    # Eighth consumer class: kura (typed agent runner). Four DAG-
    # model typed shadows — node taxonomy, retry backoff, output
    # verification, state-machine transition events.
    { label = "kura.node-kind";         count = 7; ecosystem = null; }
    { label = "kura.backoff-strategy";  count = 4; ecosystem = null; }
    { label = "kura.verification-kind"; count = 5; ecosystem = null; }
    { label = "kura.event";             count = 4; ecosystem = null; }
    # Ninth consumer class: pangea-operator (K8s controller for
    # architecture compliance bindings). target-kind = which CRD
    # kinds a compliance binding may target.
    { label = "pangea.target-kind"; count = 4; ecosystem = null; }
    # Tenth consumer class: tatara (foundational pleme-io crate —
    # Lisp + substrate + VM). hypervisor = available backends for
    # booting tatara-vm guests.
    { label = "tatara.hypervisor"; count = 4; ecosystem = null; }
  ];

  catalogByLabel = label:
    let m = builtins.filter (e: e.label == label) catalog;
    in
      if m == [] then null
      else builtins.head m;

  # Assert the label exists in the catalog snapshot.
  presenceTest = entry:
    let e = catalogByLabel entry.label;
    in
      assertEq
        "fleet catalog contains '${entry.label}'"
        true
        (e != null);

  # Assert variant_count matches the expected for the label.
  countTest = entry:
    let e = catalogByLabel entry.label;
    in
      if e == null then "(skipped count check for missing '${entry.label}')"
      else
        assertEq
          "'${entry.label}' has ${toString entry.count} variants"
          entry.count
          e.variant_count;

  # Assert the matching substrate ecosystem dir exists. Skipped for
  # runtime-only entries (entry.ecosystem == null).
  ecosystemDirTest = entry:
    if entry.ecosystem == null then
      "✓ '${entry.label}' is runtime-only (no Nix dispatch dir required)"
    else
      let
        ecosystemDir = ../. + "/${entry.ecosystem}/quirk-apply.nix";
      in
        assertEq
          "ecosystem '${entry.ecosystem}' has quirk-apply.nix (label: '${entry.label}')"
          true
          (builtins.pathExists ecosystemDir);

  totalCountTest = assertEq
    "fleet catalog has ≥ 25 entries (9 gen + 3 caixa + 2 wasm-platform + 1 cofre + 1 shigoto + 1 engenho + 2 magma + 4 kura + 1 pangea + 1 tatara)"
    true
    (builtins.length catalog >= 25);

  # ★★ promotion criterion #1 check: at least two distinct
  # consumer-class roots in the label tree.
  rootLabelRoots = lib.unique (map
    (e: builtins.head (lib.splitString "." e.label))
    catalog);
  twoClassesTest = assertEq
    "catalog has ≥ 2 distinct consumer classes (★★ promotion)"
    true
    (builtins.length rootLabelRoots >= 2);

  # ★★★ progression check: at least three distinct consumer
  # classes.
  threeClassesTest = assertEq
    "catalog has ≥ 3 distinct consumer classes (★★★ progression)"
    true
    (builtins.length rootLabelRoots >= 3);

  # Substrate has four classes today (gen + caixa + wasm-platform
  # + cofre). The four-class invariant guards against regression
  # — collapsing to ≤ 3 classes fails the substrate test.
  fourClassesTest = assertEq
    "catalog has ≥ 4 distinct consumer classes"
    true
    (builtins.length rootLabelRoots >= 4);

  # Five-class invariant. Substrate now spans gen + caixa +
  # wasm-platform + cofre + shigoto. Any future collapse fails CI.
  fiveClassesTest = assertEq
    "catalog has ≥ 5 distinct consumer classes"
    true
    (builtins.length rootLabelRoots >= 5);

  # Six-class invariant. Substrate adds engenho (cluster placement).
  sixClassesTest = assertEq
    "catalog has ≥ 6 distinct consumer classes"
    true
    (builtins.length rootLabelRoots >= 6);

  # Seven-class invariant. Substrate adds magma (IaC executor).
  sevenClassesTest = assertEq
    "catalog has ≥ 7 distinct consumer classes"
    true
    (builtins.length rootLabelRoots >= 7);

  # Eight-class invariant. Substrate adds kura (agent DAG runner).
  eightClassesTest = assertEq
    "catalog has ≥ 8 distinct consumer classes"
    true
    (builtins.length rootLabelRoots >= 8);

  # Nine-class invariant. Substrate adds pangea-operator
  # (K8s controller for architecture compliance bindings).
  nineClassesTest = assertEq
    "catalog has ≥ 9 distinct consumer classes"
    true
    (builtins.length rootLabelRoots >= 9);

  # Ten-class invariant. Substrate adds tatara (Lisp + VM
  # foundational layer).
  tenClassesTest = assertEq
    "catalog has ≥ 10 distinct consumer classes"
    true
    (builtins.length rootLabelRoots >= 10);
in
[ totalCountTest twoClassesTest threeClassesTest fourClassesTest
  fiveClassesTest sixClassesTest sevenClassesTest eightClassesTest
  nineClassesTest tenClassesTest ]
  ++ (map presenceTest production)
  ++ (map countTest production)
  ++ (map ecosystemDirTest production)
