# flake-checks-gate.nix — "did `nix flake check` actually have anything to
# build?" as a typed verdict rather than a shell branch.
#
# ── WHY ─────────────────────────────────────────────────────────────────
#
# `nix flake check` BUILDS `checks.<system>.*` and nothing else. Packages,
# devShells and apps are only EVALUATED — nix prints "(build skipped)".
# A flake declaring zero checks therefore turns that command into a pure
# evaluation check, and a repo in that state gets a green CI run over a
# crate that was never compiled, let alone tested. Measured on a
# consumer-shaped fixture at substrate 3f4dfb9: `checks.<system>` = [] and
# `nix flake check` exit 0 WITH a deliberately failing test in the crate.
#
# This is the classic vacuous guard: green because it never looked.
# The gate below makes "it never looked" LOUD instead of silent, and makes
# a passing run state what it actually verified.
#
# ── WHY IT LIVES HERE AND NOT IN THE WORKFLOW ──────────────────────────
#
# It was first written inline in `.github/workflows/cargo-ci.yml`. A Nix
# indented string (`''…''`) nested inside a YAML block scalar inside a
# shell single-quoted argument has three layers of quoting, and the first
# attempt silently lost its string delimiters — a gate that fails to PARSE
# is a gate that never runs, which is the exact failure mode it exists to
# catch. Moving the policy into a real Nix file makes it parseable,
# reviewable and — the point — testable by substrate's own
# `checks.<system>.flake-checks-gate`.
#
# ── CONSUMPTION ────────────────────────────────────────────────────────
#
# From a workflow, one command, no shell branching (the throw propagates
# as a non-zero exit):
#
#   nix eval --impure --raw --expr '
#     import (builtins.getFlake "github:pleme-io/substrate").flakeChecksGatePath {
#       system = builtins.currentSystem;
#       checks = (builtins.getFlake (toString ./.)).checks or {};
#     }'
#
# `checks` is the WHOLE per-system `checks` output (or `{}` when the flake
# has none) — the caller never has to classify a missing-attribute error.
{
  # The system whose check set is being gated, e.g. "x86_64-linux".
  system,
  # The flake's entire `checks` output: `{ <system> = { <name> = drv; }; }`.
  # A flake with no `checks` output at all passes `{}`.
  checks ? { },
  # Set false to get the verdict as data (`{ ok; names; message; }`) rather
  # than a throw. Used by the tests, so the failure path is exercised
  # without the test file itself having to die.
  strict ? true,
}:

let
  forSystem = checks.${system} or { };
  names = builtins.attrNames forSystem;
  ok = names != [ ];

  failure = ''
    This flake exposes NO checks for ${system}, so `nix flake check` just
    passed without building anything. That command evaluates packages,
    devShells and apps; it BUILDS only `checks.<system>.*`. A repo in this
    state gets a green CI run over a crate that was never compiled.

    Fix, in order of preference:

      1. Build the flake through a substrate Rust builder
         (`substrate.rust.{tool,workspace,library}`, or
         lib/build/rust/{library,tool-release}.nix directly). They emit
         `checks.build` — the crate compiles — and, on build paths that
         support it, `checks.tests`.

      2. If the flake is hand-assembled, forward the `checks` the builder
         returns into your own outputs. lib/util/flake-wrapper.nix already
         does that, passing an empty set through when the builder emits
         none.

      3. Otherwise declare your own `checks.${system}.<name>` derivations.

    Do not silence this by dropping cargo-ci.yml: that trades a loud red
    for the silent green this gate exists to remove.
  '';

  success = "checks built by `nix flake check` on ${system}: "
    + builtins.concatStringsSep ", " names;

in
  if !strict then { inherit ok names; message = if ok then success else failure; }
  else if ok then success
  else throw failure
