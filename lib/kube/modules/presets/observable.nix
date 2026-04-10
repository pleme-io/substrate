# Full observability preset.
#
# Enables monitoring, alerts, and PDB for all services.
{ services, globals, ... }: {
  services = builtins.mapAttrs (name: svc: svc // {
    monitoring = (svc.monitoring or {}) // { enabled = true; };
    alerts = (svc.alerts or {}) // { enabled = true; };
    pdb = (svc.pdb or {}) // { enabled = true; minAvailable = 1; };
  }) services;
}
