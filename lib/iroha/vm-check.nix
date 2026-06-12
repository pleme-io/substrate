# iroha.vm-check — the integration tier: full NixOS VM tests.
#
# Where iroha.checks proves pure-eval properties (instant, runs anywhere)
# and mkModuleEvalCheck proves a module graph merges, this letter proves
# the composed system actually BOOTS AND SERVES — profile/host compositions
# driven through pkgs.testers.runNixOSTest (QEMU VMs + python test driver).
# This is the SELinux-M3-style gate tier: slow, Linux-only, scheduled onto
# pangea-jit-builders, and the only tier that can attest runtime promises
# ("the unit is active", "the port answers", "the policy denies").
#
# The spec stage is pure { lib } and validates eagerly — authoring mistakes
# (missing name/nodes/testScript, an empty machine set) throw at eval time
# on ANY platform, long before a Linux builder is involved. pkgs binds late:
# the returned function is what reaches for testers.runNixOSTest, and it
# refuses non-Linux pkgs with a typed throw instead of letting QEMU fail
# obscurely mid-build.
#
# Exports (pure { lib }, zero pkgs — pkgs is the argument of the returned
# function):
#
#   mkVmCheck :: {
#     name        :: str (required) — the test derivation name;
#     nodes       :: attrsOf module (required, NON-EMPTY — a VM test with
#                    zero machines proves nothing; typed throw otherwise).
#                    Each value is an ordinary NixOS module (function or
#                    attrs), passed verbatim to runNixOSTest;
#     testScript  :: str (required) — the python test driver
#                    (machine.start(), machine.wait_for_unit(...), ...);
#     extraConfig ? { } (attrs) — merged INTO the runNixOSTest invocation,
#                    right-biased: keys here win on collision (escape hatch
#                    for skipTypeCheck, interactive, defaults, meta, ...);
#   } -> pkgs -> drv
#
#   The returned (pkgs: ...) stage:
#     - throws when pkgs.stdenv.hostPlatform.isLinux is not true (missing
#       stdenv counts as non-Linux) — NixOS VM tests need a Linux builder;
#     - otherwise returns
#         pkgs.testers.runNixOSTest ({ inherit name nodes testScript; }
#                                    // extraConfig)
#
# Throws (every message prefixed "iroha.vm-check.mkVmCheck: "):
#   - `name` missing or not a string;
#   - `nodes` missing, not attrs, or empty;
#   - `testScript` missing or not a string;
#   - `extraConfig` not attrs;
#   - the pkgs stage applied to a non-Linux (or stdenv-less) pkgs.
{ lib }:
let
  mkVmCheck =
    spec:
    let
      name = spec.name or (throw "iroha.vm-check.mkVmCheck: `name` (str) is required.");
      nodes =
        spec.nodes
          or (throw "iroha.vm-check.mkVmCheck: `nodes` (attrsOf module — the machines under test) is required.");
      testScript =
        spec.testScript
          or (throw "iroha.vm-check.mkVmCheck: `testScript` (str — the python test driver) is required.");
      extraConfig = spec.extraConfig or { };

      # Eager validation: forced via seq before the pkgs stage is handed
      # back, so authoring mistakes throw at spec time on any platform.
      checked =
        if !(builtins.isString name) then
          throw "iroha.vm-check.mkVmCheck: `name` must be a string — got ${builtins.typeOf name}."
        else if !(builtins.isAttrs nodes) then
          throw "iroha.vm-check.mkVmCheck: `nodes` must be attrsOf module — got ${builtins.typeOf nodes}."
        else if nodes == { } then
          throw "iroha.vm-check.mkVmCheck: `nodes` must be non-empty — a VM test with zero machines proves nothing; declare at least one node."
        else if !(builtins.isString testScript) then
          throw "iroha.vm-check.mkVmCheck: `testScript` must be a string (python test driver) — got ${builtins.typeOf testScript}."
        else if !(builtins.isAttrs extraConfig) then
          throw "iroha.vm-check.mkVmCheck: `extraConfig` must be attrs (merged into the runNixOSTest invocation) — got ${builtins.typeOf extraConfig}."
        else
          true;
    in
    builtins.seq checked (
      pkgs:
      if !(pkgs.stdenv.hostPlatform.isLinux or false) then
        throw "iroha.vm-check.mkVmCheck: NixOS VM tests need a Linux builder (pangea-jit-builders) — evaluate this check on a linux system."
      else
        pkgs.testers.runNixOSTest ({ inherit name nodes testScript; } // extraConfig)
    );
in
{
  inherit mkVmCheck;
}
