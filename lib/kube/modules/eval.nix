# nix-kube module evaluator.
#
# Applies a chain of modules (overlays) to service definitions.
# Modules are functions: { services, globals } -> { services, globals }
#
# Monotonicity guard (Knaster-Tarski theorem): modules can only ADD
# or ENRICH services, never remove them. This is the precondition
# for convergence — the fold reaches a fixed point because the
# service set grows monotonically.
#
# Pure function — no pkgs dependency.
rec {
  evalKubeModules = {
    services ? {},
    modules ? [],
    globals ? {},
  }: let
    initial = { inherit services globals; };
    applied = builtins.foldl'
      (state: mod: let
        m = if builtins.isFunction mod then mod else import mod;
        result = m state;
        newServices = state.services // (result.services or {});
        # Monotonicity guard: modules cannot remove services
        removedServices = builtins.filter
          (name: !(builtins.hasAttr name newServices))
          (builtins.attrNames state.services);
        _monotonicity = assert removedServices == []
          || throw "evalKubeModules: monotonicity violation — module removed service(s): [${builtins.concatStringsSep ", " removedServices}]. Modules may only add or enrich services, never remove them.";
          true;
      in {
        services = newServices;
        globals = state.globals // (result.globals or {});
      })
      initial
      modules;
  in applied;
}
