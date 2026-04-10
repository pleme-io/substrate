# Hardened security preset.
#
# Applies strict security defaults to all services.
{ services, globals, ... }: {
  services = builtins.mapAttrs (name: svc: svc // {
    securityContext = (svc.securityContext or {}) // {
      allowPrivilegeEscalation = false;
      readOnlyRootFilesystem = true;
      capabilities.drop = [ "ALL" ];
      seccompProfile = { type = "RuntimeDefault"; };
    };
    podSecurityContext = (svc.podSecurityContext or {}) // {
      runAsNonRoot = true;
      runAsUser = 1000;
      runAsGroup = 1000;
      fsGroup = 1000;
    };
    networkPolicy = (svc.networkPolicy or {}) // { enabled = true; };
  }) services;
}
