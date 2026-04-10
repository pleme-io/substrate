# mkDatabase — Stateful database composition.
#
# Produces: StatefulSet + headless Service + PodMonitor + NetworkPolicy
#
# Pure function — no pkgs dependency.
let
  ssLib = import ../primitives/statefulset.nix;
  svcLib = import ../primitives/service.nix;
  pmLib = import ../primitives/pod-monitor.nix;
  np = import ../primitives/network-policy.nix;
  sa = import ../primitives/service-account.nix;
  meta = import ../primitives/metadata.nix;
  probes = import ../primitives/probes.nix;
  defs = import ../defaults.nix;
in rec {
  mkDatabase = {
    name,
    namespace,
    image,
    instance ? name,
    replicas ? 1,
    storage ? "10Gi",
    storageClassName ? null,
    ports ? [{ name = "db"; containerPort = 5432; protocol = "TCP"; }],
    service ? { ports = [{ name = "db"; port = 5432; targetPort = "db"; }]; },
    health ? { path = "/healthz"; port = "db"; },
    resources ? { requests = { cpu = "100m"; memory = "256Mi"; }; limits = { cpu = "1"; memory = "1Gi"; }; },
    monitoring ? { enabled = true; port = "metrics"; },
    networkPolicy ? { enabled = true; },
    env ? [],
    envFrom ? [],
    volumeMounts ? [],
    volumes ? [],
    command ? [],
    args ? [],
    additionalLabels ? {},
    priorityClassName ? null,
    nodeSelector ? {},
    tolerations ? [],
  }: let
    fullname = meta.mkFullname { inherit name instance; };
    labels = meta.mkLabels { name = name; inherit instance additionalLabels; };
    selectorLabels = meta.mkSelectorLabels { name = name; inherit instance; };
    o = x: if x == null then [] else if builtins.isList x then x else [ x ];

    _statefulSet = ssLib.mkStatefulSet {
      name = fullname; inherit namespace labels selectorLabels replicas image
              ports env envFrom resources command args volumeMounts volumes
              priorityClassName nodeSelector tolerations;
      serviceName = fullname;
      volumeClaimTemplates = [{
        metadata.name = "data";
        spec = {
          accessModes = [ "ReadWriteOnce" ];
          resources.requests.storage = storage;
        } // (if storageClassName != null then { inherit storageClassName; } else {});
      }];
    };

    _service = svcLib.mkHeadlessService {
      name = fullname; inherit namespace labels selectorLabels;
      ports = service.ports or [];
    };

    _serviceAccount = sa.mkServiceAccount { name = fullname; inherit namespace labels; };

    _podMonitor = if (monitoring.enabled or true)
      then pmLib.mkPodMonitor { name = fullname; inherit namespace labels selectorLabels; port = monitoring.port or "metrics"; }
      else null;

    _networkPolicies = np.mkNetworkPolicySet {
      name = fullname; inherit namespace labels selectorLabels;
      enabled = networkPolicy.enabled or true;
    };

  in {
    statefulSet = _statefulSet;
    service = _service;
    serviceAccount = _serviceAccount;
    podMonitor = _podMonitor;
    networkPolicies = _networkPolicies;
    allResources = o _serviceAccount ++ o _statefulSet ++ o _service ++ o _podMonitor ++ _networkPolicies;
  };
}
