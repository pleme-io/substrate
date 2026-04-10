# mkMicroservice — Full HTTP microservice composition.
#
# Produces: Deployment + Service + ServiceAccount + ServiceMonitor +
#           NetworkPolicySet + optional PDB + HPA + PrometheusRule +
#           Istio + Shinka + Breathability + Delivery + Resilience
#
# Pure function — no pkgs dependency.
let
  dep = import ../primitives/deployment.nix;
  svc = import ../primitives/service.nix;
  sa = import ../primitives/service-account.nix;
  smLib = import ../primitives/service-monitor.nix;
  np = import ../primitives/network-policy.nix;
  pdbLib = import ../primitives/pdb.nix;
  hpaLib = import ../primitives/hpa.nix;
  prLib = import ../primitives/prometheus-rule.nix;
  cmLib = import ../primitives/config-map.nix;
  paLib = import ../primitives/peer-auth.nix;
  shLib = import ../primitives/shinka.nix;
  delLib = import ../primitives/delivery.nix;
  brLib = import ../primitives/breathability.nix;
  meta = import ../primitives/metadata.nix;
  probes = import ../primitives/probes.nix;
  sec = import ../primitives/security.nix;
  defs = import ../defaults.nix;
in rec {
  mkMicroservice = {
    name,
    namespace,
    image,
    instance ? name,
    fullnameOverride ? null,
    nameOverride ? null,
    replicas ? defs.replicas,
    autoscaling ? { enabled = false; },
    pdb ? { enabled = false; },
    ports ? [{ name = "http"; containerPort = 8080; protocol = "TCP"; }],
    service ? { type = "ClusterIP"; ports = [{ name = "http"; port = 8080; targetPort = "http"; }]; },
    networkPolicy ? { enabled = true; },
    health ? {},
    startupProbe ? { enabled = false; },
    resources ? defs.resources,
    podSecurityContext ? defs.podSecurityContext,
    securityContext ? defs.containerSecurityContext,
    monitoring ? { enabled = true; },
    alerts ? null,
    env ? [],
    envFrom ? [],
    volumeMounts ? [],
    volumes ? [],
    command ? [],
    args ? [],
    configMaps ? [],
    initContainers ? [],
    sidecars ? [],
    lifecycle ? {},
    serviceAccount ? { create = true; },
    strategy ? defs.strategy,
    terminationGracePeriodSeconds ? defs.terminationGracePeriodSeconds,
    priorityClassName ? null,
    topologySpreadConstraints ? [],
    nodeSelector ? {},
    tolerations ? [],
    affinity ? {},
    additionalLabels ? {},
    podAnnotations ? {},
    downwardApi ? false,
    attestation ? {},
    istio ? { enabled = false; },
    shinkaMigration ? null,
    shinkaWait ? null,
    delivery ? null,
    breathability ? null,
    prometheusRules ? null,
  }: let
    fullname = meta.mkFullname { inherit name instance fullnameOverride nameOverride; };
    labels = meta.mkLabels { name = name; inherit instance additionalLabels; managedBy = defs.managedBy; };
    selectorLabels = meta.mkSelectorLabels { name = name; inherit instance; };

    # Probes
    liveness = probes.mkLivenessProbe (health // {});
    readiness = probes.mkReadinessProbe ({ path = health.readyPath or defs.readiness.path; } // (builtins.removeAttrs health [ "readyPath" ]));
    startup = if (startupProbe.enabled or false) then probes.mkStartupProbe (builtins.removeAttrs startupProbe [ "enabled" ]) else null;

    # Init containers: shinka wait + user-provided
    allInitContainers =
      (if shinkaWait != null && (shinkaWait.enabled or false)
       then [ (shLib.mkShinkaWaitContainer ({ name = fullname; } // (builtins.removeAttrs shinkaWait [ "enabled" ]))) ]
       else [])
      ++ initContainers;

    saName = if (serviceAccount.create or true) then serviceAccount.name or fullname else serviceAccount.name or "default";

    # Optional list helper
    o = x: if x == null then [] else if builtins.isList x then x else [ x ];

    _deployment = dep.mkDeployment {
      name = fullname; inherit namespace labels selectorLabels;
      annotations = meta.mkAttestationAnnotations attestation;
      autoscalingEnabled = autoscaling.enabled or false;
      inherit replicas strategy image ports env envFrom resources volumeMounts
              volumes command args lifecycle sidecars terminationGracePeriodSeconds
              priorityClassName topologySpreadConstraints nodeSelector tolerations
              affinity downwardApi;
      containerSecurityContext = securityContext;
      inherit podSecurityContext;
      serviceAccountName = saName;
      livenessProbe = liveness;
      readinessProbe = readiness;
      startupProbe = startup;
      initContainers = allInitContainers;
      podAnnotations = podAnnotations
        // meta.mkPrometheusAnnotations (monitoring // {})
        // meta.mkIstioAnnotations istio;
      podLabels = selectorLabels;
      inherit attestation;
    };

    _service = svc.mkService {
      name = fullname; inherit namespace labels selectorLabels attestation;
      type = service.type or "ClusterIP";
      ports = service.ports or [];
    };

    _serviceAccount = if (serviceAccount.create or true)
      then sa.mkServiceAccount {
        name = saName; inherit namespace labels;
        annotations = serviceAccount.annotations or {};
      }
      else null;

    _serviceMonitor = if (monitoring.enabled or true)
      then smLib.mkServiceMonitor {
        name = fullname; inherit namespace labels selectorLabels;
        port = monitoring.port or defs.monitoring.port;
        path = monitoring.path or defs.monitoring.path;
        interval = monitoring.interval or defs.monitoring.interval;
        scrapeTimeout = monitoring.scrapeTimeout or defs.monitoring.scrapeTimeout;
      }
      else null;

    _networkPolicies = np.mkNetworkPolicySet {
      name = fullname; inherit namespace labels selectorLabels;
      enabled = networkPolicy.enabled or true;
      allowDns = networkPolicy.allowDns or defs.networkPolicy.allowDns;
      allowPrometheus = networkPolicy.allowPrometheus or defs.networkPolicy.allowPrometheus;
      monitoringPort = monitoring.port or defs.monitoring.port;
      additionalPolicies = networkPolicy.additionalPolicies or [];
    };

    _hpa = if (autoscaling.enabled or false)
      then hpaLib.mkHPA {
        name = fullname; inherit namespace labels;
        targetRef = { apiVersion = "apps/v1"; kind = "Deployment"; name = fullname; };
        minReplicas = autoscaling.minReplicas or 1;
        maxReplicas = autoscaling.maxReplicas or 5;
        targetCPUUtilizationPercentage = autoscaling.targetCPU or null;
        targetMemoryUtilizationPercentage = autoscaling.targetMemory or null;
      }
      else null;

    _pdb = if (pdb.enabled or false)
      then pdbLib.mkPDB {
        name = fullname; inherit namespace labels selectorLabels;
        minAvailable = pdb.minAvailable or null;
        maxUnavailable = pdb.maxUnavailable or null;
      }
      else null;

    _configMaps = cmLib.mkConfigMaps {
      inherit namespace labels;
      configs = configMaps;
    };

    _standardAlerts = if alerts != null && (alerts.enabled or false)
      then prLib.mkStandardAlerts ({
        name = fullname; inherit namespace labels;
      } // (builtins.removeAttrs alerts [ "enabled" ]))
      else null;

    _prometheusRule = if prometheusRules != null && (prometheusRules.enabled or false)
      then prLib.mkPrometheusRule {
        name = fullname; inherit namespace labels;
        groups = prometheusRules.groups;
      }
      else null;

    _peerAuthentication = if (istio.enabled or false)
      then paLib.mkPeerAuthentication { name = fullname; inherit namespace labels selectorLabels; }
      else null;

    _databaseMigration = if shinkaMigration != null && (shinkaMigration.enabled or false)
      then shLib.mkDatabaseMigration ({
        name = fullname; inherit namespace labels;
      } // (builtins.removeAttrs shinkaMigration [ "enabled" ]))
      else null;

    _deliveryConfig = if delivery != null && (delivery.enabled or false)
      then delLib.mkDeliveryConfig ({
        name = fullname; inherit namespace labels;
      } // (builtins.removeAttrs delivery [ "enabled" ]))
      else null;

    _breathabilityResources = if breathability != null && (breathability.enabled or false)
      then brLib.mkBreathability ({
        name = fullname; inherit namespace labels;
        targetRef = { kind = "Deployment"; name = fullname; };
      } // (builtins.removeAttrs breathability [ "enabled" ]))
      else [];

  in {
    deployment = _deployment;
    service = _service;
    serviceAccount = _serviceAccount;
    serviceMonitor = _serviceMonitor;
    networkPolicies = _networkPolicies;
    hpa = _hpa;
    pdb = _pdb;
    configMaps = _configMaps;
    standardAlerts = _standardAlerts;
    prometheusRule = _prometheusRule;
    peerAuthentication = _peerAuthentication;
    databaseMigration = _databaseMigration;
    deliveryConfig = _deliveryConfig;
    breathabilityResources = _breathabilityResources;
    allResources =
      o _deployment ++ o _service ++ o _serviceAccount ++ o _serviceMonitor
      ++ _networkPolicies ++ o _hpa ++ o _pdb ++ _configMaps
      ++ o _standardAlerts ++ o _prometheusRule ++ o _peerAuthentication
      ++ o _databaseMigration ++ o _deliveryConfig ++ _breathabilityResources;
  };
}
