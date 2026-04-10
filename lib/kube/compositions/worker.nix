# mkWorker — Background worker composition (no Service exposed).
#
# Produces: Deployment + PodMonitor + ServiceAccount + NetworkPolicySet +
#           optional PDB + Breathability + Delivery
#
# Pure function — no pkgs dependency.
let
  dep = import ../primitives/deployment.nix;
  sa = import ../primitives/service-account.nix;
  pmLib = import ../primitives/pod-monitor.nix;
  np = import ../primitives/network-policy.nix;
  pdbLib = import ../primitives/pdb.nix;
  brLib = import ../primitives/breathability.nix;
  delLib = import ../primitives/delivery.nix;
  meta = import ../primitives/metadata.nix;
  probes = import ../primitives/probes.nix;
  defs = import ../defaults.nix;
in rec {
  mkWorker = {
    name,
    namespace,
    image,
    instance ? name,
    replicas ? defs.replicas,
    ports ? [{ name = "metrics"; containerPort = 9090; protocol = "TCP"; }],
    health ? { path = "/health"; port = "metrics"; readyPath = "/health"; },
    startupProbe ? { enabled = true; },
    resources ? defs.resources,
    podSecurityContext ? defs.podSecurityContext,
    securityContext ? defs.containerSecurityContext,
    monitoring ? { enabled = true; port = "metrics"; },
    networkPolicy ? { enabled = true; },
    pdb ? { enabled = false; },
    env ? [],
    envFrom ? [],
    volumeMounts ? [],
    volumes ? [],
    command ? [],
    args ? [],
    initContainers ? [],
    lifecycle ? {},
    serviceAccount ? { create = true; },
    strategy ? defs.strategy,
    terminationGracePeriodSeconds ? 60,
    priorityClassName ? null,
    nodeSelector ? {},
    tolerations ? [],
    affinity ? {},
    additionalLabels ? {},
    podAnnotations ? {},
    downwardApi ? false,
    attestation ? {},
    delivery ? null,
    breathability ? null,
  }: let
    fullname = meta.mkFullname { inherit name instance; };
    labels = meta.mkLabels { name = name; inherit instance additionalLabels; };
    selectorLabels = meta.mkSelectorLabels { name = name; inherit instance; };
    saName = if (serviceAccount.create or true) then serviceAccount.name or fullname else "default";

    liveness = probes.mkLivenessProbe (health // {});
    readiness = probes.mkReadinessProbe ({ path = health.readyPath or "/health"; } // (builtins.removeAttrs health [ "readyPath" ]));
    startup = if (startupProbe.enabled or false) then probes.mkStartupProbe (builtins.removeAttrs startupProbe [ "enabled" ]) else null;

    o = x: if x == null then [] else if builtins.isList x then x else [ x ];

    _deployment = dep.mkDeployment {
      name = fullname; inherit namespace labels selectorLabels replicas strategy image ports
              env envFrom resources volumeMounts volumes command args lifecycle
              terminationGracePeriodSeconds priorityClassName nodeSelector tolerations
              affinity downwardApi initContainers;
      containerSecurityContext = securityContext;
      inherit podSecurityContext;
      serviceAccountName = saName;
      livenessProbe = liveness;
      readinessProbe = readiness;
      startupProbe = startup;
      podAnnotations = podAnnotations // meta.mkPrometheusAnnotations monitoring;
      podLabels = selectorLabels;
      inherit attestation;
    };

    _serviceAccount = if (serviceAccount.create or true)
      then sa.mkServiceAccount { name = saName; inherit namespace labels; }
      else null;

    _podMonitor = if (monitoring.enabled or true)
      then pmLib.mkPodMonitor {
        name = fullname; inherit namespace labels selectorLabels;
        port = monitoring.port or "metrics";
      }
      else null;

    _networkPolicies = np.mkNetworkPolicySet {
      name = fullname; inherit namespace labels selectorLabels;
      enabled = networkPolicy.enabled or true;
    };

    _pdb = if (pdb.enabled or false)
      then pdbLib.mkPDB {
        name = fullname; inherit namespace labels selectorLabels;
        minAvailable = pdb.minAvailable or null;
      }
      else null;

    _deliveryConfig = if delivery != null && (delivery.enabled or false)
      then delLib.mkDeliveryConfig ({ name = fullname; inherit namespace labels; } // (builtins.removeAttrs delivery [ "enabled" ]))
      else null;

    _breathabilityResources = if breathability != null && (breathability.enabled or false)
      then brLib.mkBreathability ({
        name = fullname; inherit namespace labels;
        targetRef = { kind = "Deployment"; name = fullname; };
      } // (builtins.removeAttrs breathability [ "enabled" ]))
      else [];

  in {
    deployment = _deployment;
    serviceAccount = _serviceAccount;
    podMonitor = _podMonitor;
    networkPolicies = _networkPolicies;
    pdb = _pdb;
    deliveryConfig = _deliveryConfig;
    breathabilityResources = _breathabilityResources;
    allResources =
      o _deployment ++ o _serviceAccount ++ o _podMonitor
      ++ _networkPolicies ++ o _pdb ++ o _deliveryConfig
      ++ _breathabilityResources;
  };
}
