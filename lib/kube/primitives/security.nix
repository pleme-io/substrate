# Kubernetes security context builders.
#
# Pure functions — no pkgs dependency.
let
  defs = import ../defaults.nix;
in rec {
  defaults = {
    pod = defs.podSecurityContext;
    container = defs.containerSecurityContext;
  };

  mkPodSecurityContext = {
    runAsNonRoot ? true,
    runAsUser ? 1000,
    runAsGroup ? null,
    fsGroup ? 1000,
    seccompProfile ? null,
  }: {
    inherit runAsNonRoot runAsUser fsGroup;
  } // (if runAsGroup != null then { inherit runAsGroup; } else {})
    // (if seccompProfile != null then { inherit seccompProfile; } else {});

  mkContainerSecurityContext = {
    allowPrivilegeEscalation ? false,
    readOnlyRootFilesystem ? true,
    capabilitiesDrop ? [ "ALL" ],
    capabilitiesAdd ? [],
    seccompProfile ? null,
  }: {
    inherit allowPrivilegeEscalation readOnlyRootFilesystem;
    capabilities = { drop = capabilitiesDrop; }
      // (if capabilitiesAdd != [] then { add = capabilitiesAdd; } else {});
  } // (if seccompProfile != null then { inherit seccompProfile; } else {});
}
