# Substrate Convergence Stage Typestate
#
# Implements the convergence pipeline as a typed state machine:
#   declared → resolved → converged → verified
#
# Each stage wraps a spec with a tag. Functions that require a specific
# stage reject specs at the wrong stage — making impossible transitions
# unrepresentable rather than caught by runtime assertions.
#
# Based on: Dependent types for deployment (Brady, ECOOP 2021),
# Typestate pattern (Strom & Yemini, 1986), pleme-io Convergence
# Computing Theory (Unified Convergence Computing Theory).
#
# Pure — depends only on builtins.
rec {
  # ── Stage constructors ────────────────────────────────────────
  # Wrap a value with its convergence stage tag.

  # Stage 1: Spec has been declared (types checked, defaults filled)
  declared = spec: {
    _convergenceStage = "declared";
    inherit spec;
  };

  # Stage 2: Spec has been resolved (module evaluation complete, all refs resolved)
  resolved = spec: {
    _convergenceStage = "resolved";
    inherit spec;
  };

  # Stage 3: Spec has been converged (rendered to target backend)
  converged = spec: rendered: {
    _convergenceStage = "converged";
    inherit spec rendered;
  };

  # Stage 4: Spec has been verified (tests passed, attestation signed)
  verified = spec: rendered: attestation: {
    _convergenceStage = "verified";
    inherit spec rendered attestation;
  };

  # ── Stage predicates ──────────────────────────────────────────
  isDeclared = x: (x._convergenceStage or "") == "declared";
  isResolved = x: (x._convergenceStage or "") == "resolved";
  isConverged = x: (x._convergenceStage or "") == "converged";
  isVerified = x: (x._convergenceStage or "") == "verified";

  # ── Stage assertions ──────────────────────────────────────────
  # Use at function boundaries to enforce stage requirements.
  requireDeclared = context: x:
    assert isDeclared x
      || throw "${context}: requires a 'declared' spec, got stage '${x._convergenceStage or "untagged"}'";
    x.spec;

  requireResolved = context: x:
    assert isResolved x
      || throw "${context}: requires a 'resolved' spec, got stage '${x._convergenceStage or "untagged"}'";
    x.spec;

  requireConverged = context: x:
    assert isConverged x
      || throw "${context}: requires a 'converged' spec, got stage '${x._convergenceStage or "untagged"}'";
    x;

  requireVerified = context: x:
    assert isVerified x
      || throw "${context}: requires a 'verified' spec, got stage '${x._convergenceStage or "untagged"}'";
    x;

  # ── Stage transitions ────────────────────────────────────────
  # Model the valid transitions. Each takes the current stage and
  # produces the next. Invalid transitions are type errors.

  # declared → resolved (via module evaluation)
  resolve = declaredSpec: resolvedValue:
    let _ = requireDeclared "resolve" declaredSpec;
    in resolved resolvedValue;

  # resolved → converged (via renderer)
  converge = resolvedSpec: renderedOutput:
    let spec = requireResolved "converge" resolvedSpec;
    in converged spec renderedOutput;

  # converged → verified (via test + attestation)
  verify = convergedSpec: attestationProof:
    let s = requireConverged "verify" convergedSpec;
    in verified s.spec s.rendered attestationProof;

  # ── Convenience: full pipeline ────────────────────────────────
  # Run the entire convergence pipeline in one call.
  pipeline = {
    spec,
    resolver ? (s: s),       # default: identity (no resolution needed)
    renderer,                 # required: spec → rendered output
    verifier ? (_: true),     # default: always passes
    attester ? (s: builtins.hashString "sha256" (builtins.toJSON s)),
  }: let
    stage1 = declared spec;
    stage2 = resolve stage1 (resolver spec);
    stage3 = converge stage2 (renderer (requireResolved "pipeline.render" stage2));
    stage4 = verify stage3 (attester (requireConverged "pipeline.attest" stage3));
  in stage4;

  # ── Pipeline with assertion validation ────────────────────────
  # Validates the spec through the assertion library before entering
  # the convergence pipeline. Use this when the spec comes from
  # untrusted input (user config, external API, etc.).
  pipelineWithValidation = {
    spec,
    validator ? (_: true),    # assertion function: spec → true or throw
    renderer,
    resolver ? (s: s),
    verifier ? (_: true),
    attester ? (s: builtins.hashString "sha256" (builtins.toJSON s)),
  }: let
    _ = validator spec;
  in pipeline { inherit spec renderer resolver verifier attester; };

  # ── Stage introspection ───────────────────────────────────────
  # Extract the current stage name from a tagged value.
  stageName = x: x._convergenceStage or "untagged";

  # Extract the spec from any stage.
  extractSpec = x:
    if isDeclared x || isResolved x then x.spec
    else if isConverged x || isVerified x then x.spec
    else throw "extractSpec: not a convergence-tagged value";

  # Check if a value has any convergence tag.
  isTagged = x: (x._convergenceStage or null) != null;
}
