# iroha.fleet-inventory — L4 composition: the typed machines × services ×
# instances placement primitive (clan-core inventory SHAPE adopted, the
# clan-core dependency skipped).
#
# One inventory declares WHAT exists (machines, with tags), WHAT can run
# (services — each role a module-producing function), and WHERE it runs
# (instances — per-role placement by explicit machine and/or by tag). The
# projections every hand-rolled registry+helper pair re-implements by hand
# — "which machines are in this thing?" (nix repo lib/vpn.nix
# linksForNode), "what config does this machine get?" (lib/clusters.nix
# per-node derivation), "which machines carry tag X?" — fall out of the
# single declaration mechanically, plus a throw-free invariants suite and
# a pure-data registry. A machine may hold SEVERAL roles of one instance
# (e.g. a hub that is `server` by explicit placement AND `client` by tag);
# each held role yields its own module.
#
# THROW POSTURE (manifest parity): membersOf/modulesFor read the VALIDATED
# view — unknown service / unknown role surface as typed throws, lazily,
# when the offending role's placement is forced (so modulesFor of ANY
# machine throws while the inventory holds a broken instance). The
# `invariants` suite reads a defaults-only raw view and NEVER throws — it
# is the reporting surface; feed it to checks.mkEvalChecks.
#
# Exports (pure { lib }, zero pkgs):
#
#   mkFleetInventory :: {
#     machines  :: attrsOf machineSpec   (required);
#     services  :: attrsOf serviceSpec   (required);
#     instances :: attrsOf instanceSpec  (required);
#   } -> inventory
#
# machineSpec = {
#   tags ? [ ]     — listOf str: free-form placement tags;
#   meta ? { }     — free-form data carried for consumers (never read here);
# }
#
# serviceSpec = { roles :: attrsOf roleFn }
#   roleFn :: {
#     instanceName :: str;
#     roleName     :: str;
#     machineName  :: str;
#     settings     :: attrs    — role-wide settings shallow-overlaid by the
#                                machine's explicit overlay (see modulesFor);
#     members      :: attrsOf (sorted [machineName]) — membership of EVERY
#                                role of THE instance (so a server module can
#                                enumerate its clients and vice versa);
#   } -> module
#
# instanceSpec = {
#   service :: str    (required — must name a `services` key; typed throw,
#                      lazy: surfaces when any role of the instance is
#                      forced via membersOf/modulesFor);
#   roles ? { }       attrsOf roleSpec — every key must exist in the
#                      service's roles (typed throw, lazy as above);
# }
#
# roleSpec = {
#   machines ? { }    — attrsOf attrs: EXPLICIT placement; each value is
#                       that machine's settings overlay;
#   tags     ? [ ]    — listOf str: every machine carrying ANY of these
#                       tags joins the role;
#   settings ? { }    — role-wide settings defaults;
# }
#
# inventory = {
#   membersOf :: instanceName -> attrsOf (roleName -> sorted [machineName])
#       Union of explicit placement and tag-matched machines, deduped,
#       sorted. Unknown instance is a typed throw. NOTE: an explicit
#       machine ABSENT from `machines` still lists here — the invariants
#       suite is what reports it (membersOf stays a pure projection).
#
#   modulesFor :: machineName -> [module]
#       For every instance+role the machine belongs to, the role's roleFn
#       applied with settings = role.settings // (role.machines.<machine>
#       or { }) — SHALLOW `//` by design: a per-machine overlay replaces a
#       nested attr WHOLESALE, so which layer owns a leaf stays legible
#       (deep merges hide provenance). Deterministic order: instances in
#       sorted attrName order, roles sorted within each instance. Unknown
#       machine is a typed throw.
#
#   machinesWithTag :: tag -> sorted [machineName]   (never throws).
#
#   invariants :: attrsOf { expr, expected }   — throw-free suite:
#       every-instance-service-exists           [instanceName] == [ ];
#       every-instance-role-exists-in-its-service
#                                               ["<inst>.<role>"] == [ ]
#                                               (skips instances already
#                                               reported by the service
#                                               invariant);
#       every-explicit-role-machine-exists      ["<inst>.<role>.<machine>"]
#                                               == [ ];
#       every-tag-reference-matches-a-machine   ["<inst>.<role>:<tag>"]
#                                               == [ ].
#
#   registry :: { machineCount :: int; instanceCount :: int;
#                 byService :: attrsOf (sorted [instanceName]) — keyed by
#                 EVERY declared service (zero-instance services key [ ]);
#                 instances naming an unknown service appear under no key —
#                 the invariants suite reports them; }   (never throws).
# }
#
# Throws:
#   iroha.fleet-inventory.mkFleetInventory: instance '<i>' is missing required `service` — …
#   iroha.fleet-inventory.mkFleetInventory: instance '<i>' names unknown service '<s>' — …
#   iroha.fleet-inventory.mkFleetInventory: instance '<i>' declares role '<r>' which does not exist in service '<s>' — …
#   iroha.fleet-inventory.membersOf: unknown instance '<i>' — …
#   iroha.fleet-inventory.modulesFor: unknown machine '<m>' — …
{ lib }:
let
  fn = "iroha.fleet-inventory.mkFleetInventory";

  machineDefaults = {
    tags = [ ];
    meta = { };
  };

  roleDefaults = {
    machines = { };
    tags = [ ];
    settings = { };
  };

  # Sorted + deduped by construction: attrNames of a genAttrs set.
  sortedUnique = names: builtins.attrNames (lib.genAttrs names (_: null));

  mkFleetInventory =
    {
      machines,
      services,
      instances,
    }:
    let
      machineNames = builtins.attrNames machines; # sorted
      instanceNames = builtins.attrNames instances; # sorted
      serviceList = lib.concatStringsSep ", " (builtins.attrNames services);
      machineList = lib.concatStringsSep ", " machineNames;
      instanceList = lib.concatStringsSep ", " instanceNames;

      resolvedMachines = lib.mapAttrs (_: m: machineDefaults // m) machines;

      # Defaults-only role view — never throws. The invariants suite (and
      # anything that must REPORT rather than abort) reads this view.
      rawRolesOf =
        instName: lib.mapAttrs (_: r: roleDefaults // r) ((instances.${instName}).roles or { });

      # Validated view — typed throws, lazy: forcing a role's value
      # surfaces the unknown-service / unknown-role throw.
      resolveInstance =
        instName: inst:
        let
          svc =
            if !(inst ? service) then
              throw "${fn}: instance '${instName}' is missing required `service` — expected one of ${serviceList}."
            else if !(services ? ${inst.service}) then
              throw "${fn}: instance '${instName}' names unknown service '${toString inst.service}' — expected one of ${serviceList}."
            else
              inst.service;
          serviceRoles = (services.${svc}).roles;
        in
        {
          service = svc;
          roles = lib.mapAttrs (
            roleName: r:
            if !(serviceRoles ? ${roleName}) then
              throw "${fn}: instance '${instName}' declares role '${roleName}' which does not exist in service '${svc}' — expected one of ${lib.concatStringsSep ", " (builtins.attrNames serviceRoles)}."
            else
              roleDefaults // r
          ) (inst.roles or { });
        };

      instancesV = lib.mapAttrs resolveInstance instances;

      # machineNames is sorted, filter preserves order — result is sorted.
      machinesWithTag =
        tag: builtins.filter (m: builtins.elem tag (resolvedMachines.${m}.tags)) machineNames;

      tagMembers =
        tags:
        builtins.filter (m: lib.any (t: builtins.elem t (resolvedMachines.${m}.tags)) tags) machineNames;

      membersOfRole = role: sortedUnique (builtins.attrNames role.machines ++ tagMembers role.tags);

      membersOf =
        instName:
        if !(instances ? ${instName}) then
          throw "iroha.fleet-inventory.membersOf: unknown instance '${toString instName}' — expected one of ${instanceList}."
        else
          lib.mapAttrs (_: membersOfRole) (instancesV.${instName}).roles;

      modulesFor =
        machineName:
        if !(machines ? ${machineName}) then
          throw "iroha.fleet-inventory.modulesFor: unknown machine '${toString machineName}' — expected one of ${machineList}."
        else
          lib.concatMap (
            instName:
            let
              inst = instancesV.${instName};
              members = membersOf instName;
            in
            lib.concatMap (
              roleName:
              let
                role = inst.roles.${roleName};
              in
              lib.optional (builtins.elem machineName members.${roleName}) (
                (services.${inst.service}).roles.${roleName} {
                  instanceName = instName;
                  inherit roleName machineName members;
                  # Shallow by design — see modulesFor in the header.
                  settings = role.settings // (role.machines.${machineName} or { });
                }
              )
            ) (builtins.attrNames inst.roles)
          ) instanceNames;

      invariants = {
        every-instance-service-exists = {
          expr = builtins.filter (
            i: !((instances.${i}) ? service) || !(services ? ${(instances.${i}).service})
          ) instanceNames;
          expected = [ ];
        };
        every-instance-role-exists-in-its-service = {
          expr = lib.concatMap (
            i:
            let
              inst = instances.${i};
            in
            # Instances with a missing/unknown service are reported by the
            # service invariant — don't double-report their roles.
            if !(inst ? service) || !(services ? ${inst.service}) then
              [ ]
            else
              map (r: "${i}.${r}") (
                builtins.filter (r: !((services.${inst.service}).roles ? ${r})) (
                  builtins.attrNames (inst.roles or { })
                )
              )
          ) instanceNames;
          expected = [ ];
        };
        every-explicit-role-machine-exists = {
          expr = lib.concatMap (
            i:
            lib.concatMap (
              r:
              map (m: "${i}.${r}.${m}") (
                builtins.filter (m: !(machines ? ${m})) (builtins.attrNames ((rawRolesOf i).${r}.machines))
              )
            ) (builtins.attrNames ((instances.${i}).roles or { }))
          ) instanceNames;
          expected = [ ];
        };
        every-tag-reference-matches-a-machine = {
          expr = lib.concatMap (
            i:
            lib.concatMap (
              r:
              map (t: "${i}.${r}:${t}") (builtins.filter (t: machinesWithTag t == [ ]) ((rawRolesOf i).${r}.tags))
            ) (builtins.attrNames ((instances.${i}).roles or { }))
          ) instanceNames;
          expected = [ ];
        };
      };

      registry = {
        machineCount = builtins.length machineNames;
        instanceCount = builtins.length instanceNames;
        byService = lib.mapAttrs (
          svcName: _: builtins.filter (i: ((instances.${i}).service or null) == svcName) instanceNames
        ) services;
      };
    in
    {
      inherit
        membersOf
        modulesFor
        machinesWithTag
        invariants
        registry
        ;
    };
in
{
  inherit mkFleetInventory;
}
