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
    "fleet catalog has ≥ 10 entries (9 gen adapters + ≥ 1 non-adapter)"
    true
    (builtins.length catalog >= 10);

  # ★★ promotion criterion #1 check: at least two distinct
  # consumer-class roots in the label tree.
  rootLabelRoots = lib.unique (map
    (e: builtins.head (lib.splitString "." e.label))
    catalog);
  twoClassesTest = assertEq
    "catalog has ≥ 2 distinct consumer classes (★★ promotion)"
    true
    (builtins.length rootLabelRoots >= 2);
in
[ totalCountTest twoClassesTest ]
  ++ (map presenceTest production)
  ++ (map countTest production)
  ++ (map ecosystemDirTest production)
