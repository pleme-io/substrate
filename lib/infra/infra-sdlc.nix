# Infrastructure SDLC — complete lifecycle apps for gated Pangea workspaces.
#
# Encapsulates the full cycle: rspec → plan → apply → inspec → destroy
# as reusable nix apps. Consumers get the entire SDLC with a single call.
#
# This is the generalized abstraction over gated-pangea-workspace.nix.
# Every infrastructure project that uses Pangea architectures should use
# this pattern instead of building individual apps.
#
# Usage:
#   let mkInfraSdlc = import "${substrate}/lib/infra/infra-sdlc.nix" {
#     inherit pkgs;
#     pangea = inputs.pangea.packages.${system}.default;
#     ruby = pkgs.ruby_3_3;
#   };
#   in mkInfraSdlc {
#     name = "k3s-dev";
#     architecture = "k3s_cluster_iam";
#     architecturesSrc = inputs.pangea-architectures;
#     inspecProfile = ./inspec;
#     inspecTarget = "aws://us-east-1";
#     # ... pangea-workspace args ...
#   };
#
# Returns: {
#   # Full lifecycle
#   test, plan, apply, verify, destroy, deploy,
#   # Cycle commands (the primary use case)
#   cycle, cycle-destroy,
#   # Individual operations
#   plan-ungated, apply-ungated, show, status, migrate, list,
#   # Artifacts
#   pangeaYml
# }
{ pkgs, pangea ? null, ruby ? pkgs.ruby_3_3, bundler ? null }:

args @ {
  name,
  architecture,
  architecturesSrc,
  inspecProfile ? null,
  inspecTarget ? null,
  ...
}:

let
  lib = pkgs.lib;

  # Delegate to gated workspace for the core gated operations
  mkGatedPangeaWorkspace = import ./gated-pangea-workspace.nix {
    inherit pkgs pangea ruby bundler;
  };
  gated = mkGatedPangeaWorkspace args;

  mkApp = program: {
    type = "app";
    inherit program;
  };

  # ── Full Cycle: test → plan → apply → verify ─────────────────────
  # The primary workflow. Runs the complete lifecycle in one command.
  # Use this when you want to deploy infrastructure with full confidence.
  cycleScript = pkgs.writeShellScript "${name}-cycle" ''
    set -euo pipefail

    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  INFRASTRUCTURE SDLC: ${name}                               ║"
    echo "║  Cycle: test → plan → apply → verify                       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # Phase 1: Test gate
    echo "━━━ Phase 1/4: RSpec Test Suite ━━━"
    ${gated.test.program}
    echo ""

    # Phase 2: Plan (shows what will change)
    echo "━━━ Phase 2/4: Plan ━━━"
    ${gated.plan-ungated.program}
    echo ""

    # Phase 3: Apply (with confirmation)
    echo "━━━ Phase 3/4: Apply ━━━"
    read -rp "Proceed with apply? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
      echo "Aborted."
      exit 0
    fi
    ${gated.apply-ungated.program}
    echo ""

    # Phase 4: Verify (InSpec)
    echo "━━━ Phase 4/4: InSpec Verification ━━━"
    ${gated.verify.program}
    echo ""

    echo "✓ Full infrastructure lifecycle complete for ${name}."
  '';

  # ── Destroy Cycle: test → plan-destroy → confirm → destroy → verify-gone ──
  # Safe destruction workflow with multiple confirmation gates.
  cycleDestroyScript = pkgs.writeShellScript "${name}-cycle-destroy" ''
    set -euo pipefail

    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  INFRASTRUCTURE DESTROY: ${name}                            ║"
    echo "║  ⚠ This will DESTROY all infrastructure for ${name}         ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # Safety gate 1: Require explicit confirmation
    read -rp "Type '${name}' to confirm destruction: " confirm
    if [[ "$confirm" != "${name}" ]]; then
      echo "Confirmation failed. Aborted."
      exit 1
    fi

    # Phase 1: Test (ensure architecture is still valid before destroying)
    echo ""
    echo "━━━ Phase 1/3: RSpec Test Suite (pre-destroy validation) ━━━"
    ${gated.test.program}
    echo ""

    # Phase 2: Show current state
    echo "━━━ Phase 2/3: Current State ━━━"
    ${gated.show.program} || true
    echo ""

    # Safety gate 2: Final confirmation
    echo ""
    read -rp "FINAL CONFIRMATION: Destroy all resources for ${name}? [y/N] " final
    if [[ "$final" != "y" && "$final" != "Y" ]]; then
      echo "Aborted."
      exit 0
    fi

    # Phase 3: Destroy
    echo ""
    echo "━━━ Phase 3/3: Destroy ━━━"
    ${gated.destroy.program}
    echo ""

    echo "✓ Infrastructure destroyed for ${name}."
  '';

  # ── Drift Check: test → plan (no apply) ──────────────────────────
  # Detect configuration drift without making changes.
  driftScript = pkgs.writeShellScript "${name}-drift" ''
    set -euo pipefail
    echo "━━━ Drift Check: ${name} ━━━"
    ${gated.test.program}
    echo ""
    echo "Planning (detect drift)..."
    ${gated.plan-ungated.program}
    echo ""
    echo "Review the plan above for unexpected changes."
  '';

  # ── Validate Only: test + plan (non-destructive) ──────────────────
  validateScript = pkgs.writeShellScript "${name}-validate" ''
    set -euo pipefail
    echo "━━━ Validate: ${name} ━━━"
    ${gated.test.program}
    echo "✓ All tests passed. Architecture is valid."
  '';

in {
  # ── Primary Lifecycle Commands ──────────────────────────────────────
  # These are the commands you'll use most. All are fully gated.

  # Full deployment cycle: test → plan → confirm → apply → verify
  cycle         = mkApp (toString cycleScript);

  # Safe destruction: confirm → test → show → confirm → destroy
  cycle-destroy = mkApp (toString cycleDestroyScript);

  # Detect drift without changing anything: test → plan
  drift         = mkApp (toString driftScript);

  # Validate architecture only (no cloud interaction): test
  validate      = mkApp (toString validateScript);

  # ── Individual Gated Operations ─────────────────────────────────────
  # Each runs the full test suite before the cloud operation.
  inherit (gated) test plan apply verify deploy;

  # ── Ungated Operations ──────────────────────────────────────────────
  # For debugging and emergencies. Use with caution.
  plan-ungated  = gated.plan-ungated;
  apply-ungated = gated.apply-ungated;

  # ── Always-Available Operations ─────────────────────────────────────
  # These don't need test gates.
  inherit (gated) destroy show status migrate list;

  # ── Config Artifact ─────────────────────────────────────────────────
  inherit (gated) pangeaYml;
}
