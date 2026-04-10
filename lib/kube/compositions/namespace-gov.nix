# mkNamespaceGovernance — Namespace governance composition.
#
# Produces: Namespace + LimitRange + ResourceQuota + optional PriorityClasses
#
# Pure function — no pkgs dependency.
let
  nsLib = import ../primitives/namespace.nix;
  lrLib = import ../primitives/limit-range.nix;
  rqLib = import ../primitives/resource-quota.nix;
  pcLib = import ../primitives/priority-class.nix;
  meta = import ../primitives/metadata.nix;
in rec {
  mkNamespaceGovernance = {
    name,
    labels ? {},
    limitRange ? null,
    resourceQuota ? null,
    priorityClasses ? [],
  }: let
    o = x: if x == null then [] else if builtins.isList x then x else [ x ];

    _namespace = nsLib.mkNamespace { inherit name labels; };

    _limitRange = if limitRange != null
      then lrLib.mkLimitRange ({
        name = "${name}-limits"; namespace = name; inherit labels;
      } // limitRange)
      else null;

    _resourceQuota = if resourceQuota != null
      then rqLib.mkResourceQuota {
        name = "${name}-quota"; namespace = name; inherit labels;
        hard = resourceQuota;
      }
      else null;

    _priorityClasses = if priorityClasses != []
      then map (pc: pcLib.mkPriorityClass (pc // { inherit labels; })) priorityClasses
      else [];

  in {
    namespace = _namespace;
    limitRange = _limitRange;
    resourceQuota = _resourceQuota;
    priorityClasses = _priorityClasses;
    allResources = o _namespace ++ o _limitRange ++ o _resourceQuota ++ _priorityClasses;
  };
}
