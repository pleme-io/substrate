# mkCache — Cache (Redis/Valkey/Dragonfly) composition.
#
# Produces: StatefulSet + headless Service + regular Service + PodMonitor + NetworkPolicy
#
# Pure function — no pkgs dependency.
let
  ssLib = import ../primitives/statefulset.nix;
  svcLib = import ../primitives/service.nix;
  pmLib = import ../primitives/pod-monitor.nix;
  np = import ../primitives/network-policy.nix;
  sa = import ../primitives/service-account.nix;
  meta = import ../primitives/metadata.nix;
  defs = import ../defaults.nix;
in rec {
  mkCache = {
    name,
    namespace,
    image,
    instance ? name,
    replicas ? 1,
    storage ? "1Gi",
    ports ? [{ name = "redis"; containerPort = 6379; protocol = "TCP"; }],
    service ? { ports = [{ name = "redis"; port = 6379; targetPort = "redis"; }]; },
    resources ? { requests = { cpu = "50m"; memory = "64Mi"; }; limits = { cpu = "500m"; memory = "512Mi"; }; },
    monitoring ? { enabled = true; port = "metrics"; },
    networkPolicy ? { enabled = true; },
    env ? [],
    command ? [],
    args ? [],
    additionalLabels ? {},
    nodeSelector ? {},
    tolerations ? [],
  }: let
    fullname = meta.mkFullname { inherit name instance; };
    labels = meta.mkLabels { name = name; inherit instance additionalLabels; };
    selectorLabels = meta.mkSelectorLabels { name = name; inherit instance; };
    o = x: if x == null then [] else if builtins.isList x then x else [ x ];

    _statefulSet = ssLib.mkStatefulSet {
      name = fullname; inherit namespace labels selectorLabels replicas image
              ports env command args resources nodeSelector tolerations;
      serviceName = "${fullname}-headless";
      volumeClaimTemplates = [{
        metadata.name = "data";
        spec = {
          accessModes = [ "ReadWriteOnce" ];
          resources.requests.storage = storage;
        };
      }];
      volumeMounts = [{ name = "data"; mountPath = "/data"; }];
    };

    _headlessService = svcLib.mkHeadlessService {
      name = "${fullname}-headless"; inherit namespace labels selectorLabels;
      ports = service.ports or [];
    };

    _service = svcLib.mkService {
      name = fullname; inherit namespace labels selectorLabels;
      ports = service.ports or [];
    };

    _serviceAccount = sa.mkServiceAccount { name = fullname; inherit namespace labels; };

    _podMonitor = if (monitoring.enabled or true)
      then pmLib.mkPodMonitor { name = fullname; inherit namespace labels selectorLabels; }
      else null;

    _networkPolicies = np.mkNetworkPolicySet {
      name = fullname; inherit namespace labels selectorLabels;
      enabled = networkPolicy.enabled or true;
    };

  in {
    statefulSet = _statefulSet;
    headlessService = _headlessService;
    service = _service;
    serviceAccount = _serviceAccount;
    podMonitor = _podMonitor;
    networkPolicies = _networkPolicies;
    allResources = o _serviceAccount ++ o _statefulSet ++ o _headlessService ++ o _service
                   ++ o _podMonitor ++ _networkPolicies;
  };
}
