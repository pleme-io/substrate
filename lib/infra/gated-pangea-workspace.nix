# Test-gated Pangea infrastructure workspace.
#
# Wraps pangea-workspace.nix — runs full RSpec architecture suite before plan/apply.
# Infrastructure is NEVER instantiated without passing tests. This is a hard gate,
# not advisory.
#
# The test pyramid:
#   Layer 1: RSpec resource function unit tests (pangea-{provider} specs)
#   Layer 2: RSpec architecture synthesis tests (pangea-architectures specs)
#   Layer 3: InSpec live verification (post-apply, optional)
#
# Usage:
#   let mkGatedPangeaWorkspace = import "${substrate}/lib/infra/gated-pangea-workspace.nix" {
#     inherit pkgs;
#     pangea = inputs.pangea.packages.${system}.default;
#     ruby = pkgs.ruby_3_3;
#     bundler = pkgs.bundlerEnv { ... };  # or bundix
#   };
#   in mkGatedPangeaWorkspace {
#     name = "state-backend";
#     architecture = "state_backend";
#     architecturesSrc = inputs.pangea-architectures;
#     inspecProfile = inputs.inspec-aws;  # optional
#     # ... all pangea-workspace.nix args ...
#   };
#
# Returns: { test, plan, apply, verify, plan-ungated, apply-ungated, destroy, ... }
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

  # Delegate to the base workspace builder
  mkPangeaWorkspace = import ./pangea-workspace.nix { inherit pkgs pangea; };
  base = mkPangeaWorkspace (builtins.removeAttrs args [
    "architecturesSrc" "inspecProfile" "inspecTarget"
  ]);

  # RSpec test dependencies
  testDeps = [ ruby ]
    ++ lib.optional (bundler != null) bundler;

  # ── Test gate: full RSpec architecture suite ─────────────────────
  #
  # Runs all three layers:
  #   1. Resource function specs (if present in architecturesSrc)
  #   2. Architecture synthesis specs (MUST pass)
  #   3. Security policy assertions (least-privilege, encryption, tags)
  testScript = pkgs.writeShellScript "${name}-test-gate" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath testDeps}:$PATH"

    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  TEST GATE: ${name} (${architecture})                       ║"
    echo "║  Infrastructure will NOT be instantiated without passing.    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    cd "${architecturesSrc}"

    # Layer 1: Resource function unit tests (if spec dir exists)
    if [ -d "spec/resources" ]; then
      echo "── Layer 1: Resource function unit tests ──"
      bundle exec rspec spec/resources/ --format documentation --fail-fast || {
        echo ""
        echo "FATAL: Resource function tests failed. Fix before proceeding."
        exit 1
      }
      echo ""
    fi

    # Layer 2: Architecture synthesis tests (REQUIRED)
    ARCH_SPEC="spec/architectures/${architecture}_spec.rb"
    if [ ! -f "$ARCH_SPEC" ]; then
      echo "FATAL: Architecture spec not found: $ARCH_SPEC"
      echo "Every architecture MUST have a synthesis test suite."
      exit 1
    fi

    echo "── Layer 2: Architecture synthesis tests ──"
    bundle exec rspec "$ARCH_SPEC" --format documentation --fail-fast || {
      echo ""
      echo "FATAL: Architecture synthesis tests failed."
      echo "Infrastructure CANNOT be instantiated until all tests pass."
      exit 1
    }
    echo ""

    # Layer 2b: Security policy assertions (if present)
    SECURITY_SPEC="spec/security/${architecture}_security_spec.rb"
    if [ -f "$SECURITY_SPEC" ]; then
      echo "── Layer 2b: Security policy assertions ──"
      bundle exec rspec "$SECURITY_SPEC" --format documentation --fail-fast || {
        echo ""
        echo "FATAL: Security policy tests failed."
        echo "All infrastructure must meet least-privilege requirements."
        exit 1
      }
      echo ""
    fi

    echo "✓ All test gates passed. Infrastructure may proceed."
  '';

  # ── InSpec verification (post-apply) ─────────────────────────────
  verifyScript = if inspecProfile != null then
    pkgs.writeShellScript "${name}-verify" ''
      set -euo pipefail
      export PATH="${lib.makeBinPath [ pkgs.inspec ]}:$PATH"

      echo "── Layer 3: InSpec live verification ──"
      echo "Profile: ${inspecProfile}"
      ${lib.optionalString (inspecTarget != null) ''echo "Target: ${inspecTarget}"''}

      inspec exec "${inspecProfile}" \
        ${lib.optionalString (inspecTarget != null) "--target ${inspecTarget}"} \
        --reporter cli json:${name}-inspec-results.json || {
        echo ""
        echo "WARNING: InSpec verification found issues."
        echo "Review ${name}-inspec-results.json for details."
        exit 1
      }
      echo "✓ Live verification passed."
    ''
  else
    pkgs.writeShellScript "${name}-verify-stub" ''
      echo "No InSpec profile configured for ${name}."
      echo "Add inspecProfile to enable post-apply verification."
    '';

  mkApp = program: {
    type = "app";
    inherit program;
  };

in {
  # ── Test gate (standalone) ──────────────────────────────────────
  test = mkApp (toString testScript);

  # ── Gated operations: test → action ─────────────────────────────
  # These ALWAYS run the full test suite before the cloud operation.
  plan = mkApp (toString (pkgs.writeShellScript "${name}-gated-plan" ''
    set -euo pipefail
    ${testScript}
    exec ${base.plan.program}
  ''));

  apply = mkApp (toString (pkgs.writeShellScript "${name}-gated-apply" ''
    set -euo pipefail
    ${testScript}
    exec ${base.apply.program}
  ''));

  # ── Verify (post-apply InSpec) ──────────────────────────────────
  verify = mkApp (toString verifyScript);

  # ── Full lifecycle: test → apply → verify ───────────────────────
  deploy = mkApp (toString (pkgs.writeShellScript "${name}-deploy" ''
    set -euo pipefail
    ${testScript}
    ${base.apply.program}
    ${verifyScript}
  ''));

  # ── Ungated operations (for debugging/emergencies) ──────────────
  plan-ungated  = base.plan;
  apply-ungated = base.apply;

  # ── Operations that don't need test gates ───────────────────────
  destroy = base.destroy;
  show    = base.show;
  status  = base.status;
  migrate = base.migrate;
  list    = base.list;

  # ── Config artifact ─────────────────────────────────────────────
  inherit (base) pangeaYml;
}
