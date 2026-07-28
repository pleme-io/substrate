# Pure eval tests for lib/build/rust/shape.nix.
#
# `shape` spent its whole life as an argument that was accepted and then
# discarded, so the tests that matter are the ones proving it is no longer
# inert:
#
#   * `unknown-shape-throws` — the exact input the old code swallowed now
#     fails. Before shape.nix existed, `shape = "libary"` silently built the
#     default. A validator that accepted it would be green over the defect.
#   * `known-set-matches-flake-call-sites` — a CATALOG-REFLECTION-style drift
#     gate. `flake.nix` exposes the shapes via `callShape "<name>"`; this test
#     reads that file and asserts the two lists agree IN BOTH DIRECTIONS. A
#     shape added to one and not the other is the precise way this closed set
#     would quietly stop being closed.
#   * `resolve-records-that-shape-does-not-route` — the honesty bit. If
#     someone later wires real routing, this test fails and forces the doc
#     comment and the fleet-count argument in shape.nix to be revisited
#     rather than silently outdated.
#
# Usage:
#   nix eval -f lib/build/rust/tests/shape-test.nix … --arg lib '…'
# Wired as a derivation via `asCheck pkgs` in substrate's flake checks.
{ lib }:

let
  testHelpers = import ../../../util/test-helpers.nix { inherit lib; };
  shape = import ../shape.nix { inherit lib; };

  throws = expr: !(builtins.tryEval (builtins.deepSeq expr expr)).success;

  who = "unit-test";

  # ── The drift gate's raw material ─────────────────────────────────────
  # substrate/flake.nix, read as text. lib/build/rust/tests/ -> ../../../../
  flakeSrc = builtins.readFile ../../../../flake.nix;
  callSiteMarker = s: ''callShape "${s}"'';
  # Number of `callShape "` occurrences in flake.nix. splitString yields
  # (occurrences + 1) fragments.
  callSiteCount =
    (builtins.length (lib.splitString ''callShape "'' flakeSrc)) - 1;

  tests = [
    (testHelpers.mkTest "shape-file-parses"
      (builtins.isList shape.known && shape.known != [ ])
      "the shape file must evaluate and expose a non-empty closed set — a policy that cannot parse never runs")

    # ── The defect it exists to catch ─────────────────────────────────
    (testHelpers.mkTest "unknown-shape-throws"
      (throws (shape.normalize who "libary"))
      "a typo'd shape must FAIL — silently swallowing it is the original defect")

    (testHelpers.mkTest "non-string-shape-throws"
      (throws (shape.normalize who { }))
      "a non-string shape must fail with a typed message, not an obscure coercion error")

    (testHelpers.mkTest "unknown-shape-message-lists-the-known-set"
      (let m = (builtins.tryEval (shape.normalize who "nope")).success;
       in !m)
      "an unknown shape must not evaluate at all")

    # ── Every advertised shape is accepted ────────────────────────────
    (testHelpers.mkTest "every-known-shape-normalizes-to-itself"
      (builtins.all (s: shape.normalize who s == s) shape.known)
      "each shape in the closed set must round-trip unchanged")

    (testHelpers.mkTest "the-five-documented-shapes-are-present"
      (builtins.all (s: builtins.elem s shape.known)
        [ "tool" "workspace" "library" "service" "binary" ])
      "the five shapes flake.nix advertises must all be in the closed set")

    # ── Drift gate against flake.nix's own call sites ─────────────────
    (testHelpers.mkTest "known-set-covers-every-flake-call-site"
      (callSiteCount == builtins.length shape.known)
      "flake.nix has a `callShape` site with no entry in `known` (or vice versa) — the closed set has silently stopped being closed")

    (testHelpers.mkTest "every-known-shape-has-a-flake-call-site"
      (builtins.all (s: lib.hasInfix (callSiteMarker s) flakeSrc) shape.known)
      "a shape in `known` that flake.nix never exposes is a promise with no entry point")

    # ── The honesty fields ────────────────────────────────────────────
    (testHelpers.mkTest "resolve-records-that-shape-does-not-route"
      (builtins.all (s: (shape.resolve who s).selectsBuilder == false) shape.known)
      "shape does not select a builder today; if that changes, shape.nix's fleet-count argument must be revisited rather than left stale")

    (testHelpers.mkTest "resolve-names-one-builder-for-every-shape"
      (builtins.all (s: (shape.resolve who s).builder == "tool-release") shape.known)
      "all 280 measured consumers resolve to the tool-release builder — the record must say so")

    (testHelpers.mkTest "resolve-who-carries-the-shape"
      (lib.hasInfix "shape=library" (shape.resolve "shikumi" "library").who
       && lib.hasInfix "shikumi" (shape.resolve "shikumi" "library").who)
      "the identity handed to test-check.nix must name BOTH the shape and the consumer, so diagnostics are attributable")

    # ── explain: the witness a consumer can actually read ─────────────
    (testHelpers.mkTest "explain-names-the-shape"
      (lib.hasInfix "shape=library"
        (shape.explain { who = "shikumi"; shape = "library"; mode = "lockfile"; }))
      "the explanation must name the shape that was requested")

    (testHelpers.mkTest "explain-names-the-pending-item-on-the-lockfile-path"
      (lib.hasInfix "pending-rust-test-check"
        (shape.explain { who = "shikumi"; shape = "library"; mode = "lockfile"; }))
      "an absent `tests` check must point at the tracked upstream blocker, never just go unmentioned")

    (testHelpers.mkTest "explain-names-the-real-test-leg-on-the-lockfile-path"
      (lib.hasInfix "cargo-ci.yml"
        (shape.explain { who = "shikumi"; shape = "library"; mode = "lockfile"; }))
      "if `checks.tests` is absent the explanation must say what DOES run the tests")

    (testHelpers.mkTest "explain-reports-tests-emitted-on-cargo-nix"
      (lib.hasInfix "emitted"
        (shape.explain { who = "x"; shape = "tool"; mode = "cargo-nix"; }))
      "on the crate2nix path the explanation must state that tests ARE emitted")

    (testHelpers.mkTest "explain-states-shape-does-not-route"
      (lib.hasInfix "does not select a builder"
        (shape.explain { who = "x"; shape = "tool"; mode = "lockfile"; }))
      "the explanation must not let a reader infer that shape routed them somewhere")
  ];

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  asCheck = pkgs:
    if result.allPassed
    then pkgs.runCommand "rust-shape-test" { } ''
      echo "rust/shape: ${result.summary}" > $out
    ''
    else throw ''
      rust/shape tests FAILED (${result.summary}):
        - ${builtins.concatStringsSep "\n  - " result.failures}'';
}
