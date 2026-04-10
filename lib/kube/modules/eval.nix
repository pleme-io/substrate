# nix-kube module evaluator.
#
# Applies a chain of modules (overlays) to service definitions.
# Modules are functions: { services, globals } -> { services, globals }
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
      in {
        services = state.services // (result.services or {});
        globals = state.globals // (result.globals or {});
      })
      initial
      modules;
  in applied;
}
