# mkOperator — Kubernetes operator composition with RBAC.
#
# Produces: Deployment + ServiceAccount + ClusterRole + ClusterRoleBinding +
#           Service + ServiceMonitor + NetworkPolicySet
#
# Pure function — no pkgs dependency.
let
  dep = import ../primitives/deployment.nix;
  svc = import ../primitives/service.nix;
  rbac = import ../primitives/rbac.nix;
  smLib = import ../primitives/service-monitor.nix;
  np = import ../primitives/network-policy.nix;
  meta = import ../primitives/metadata.nix;
  probes = import ../primitives/probes.nix;
  defs = import ../defaults.nix;
in rec {
  mkOperator = {
    name,
    namespace,
    image,
    instance ? name,
    replicas ? 1,
    rbacRules ? [],
    ports ? [{ name = "http"; containerPort = 8080; protocol = "TCP"; }],
    service ? { type = "ClusterIP"; ports = [{ name = "http"; port = 8080; targetPort = "http"; }]; },
    health ? {},
    resources ? defs.resources,
    podSecurityContext ? defs.podSecurityContext,
    securityContext ? defs.containerSecurityContext,
    monitoring ? { enabled = true; },
    networkPolicy ? { enabled = true; },
    env ? [],
    envFrom ? [],
    volumeMounts ? [],
    volumes ? [],
    command ? [],
    args ? [],
    initContainers ? [],
    lifecycle ? { preStop.exec.command = [ "/bin/sh" "-c" "sleep 15" ]; },
    additionalLabels ? {},
    podAnnotations ? {},
    attestation ? {},
    priorityClassName ? null,
    nodeSelector ? {},
    tolerations ? [],
  }: let
    fullname = meta.mkFullname { inherit name instance; };
    labels = meta.mkLabels { name = name; inherit instance additionalLabels; };
    selectorLabels = meta.mkSelectorLabels { name = name; inherit instance; };

    liveness = probes.mkLivenessProbe (health // {});
    readiness = probes.mkReadinessProbe ({ path = health.readyPath or defs.readiness.path; } // (builtins.removeAttrs health [ "readyPath" ]));

    rbacSet = rbac.mkOperatorRbac {
      name = fullname; inherit namespace labels;
      rules = rbacRules;
    };

    o = x: if x == null then [] else if builtins.isList x then x else [ x ];

    _serviceAccount = rbacSet.serviceAccount;
    _clusterRole = rbacSet.clusterRole;
    _clusterRoleBinding = rbacSet.clusterRoleBinding;

    _deployment = dep.mkDeployment {
      name = fullname; inherit namespace labels selectorLabels replicas image ports
              env envFrom resources volumeMounts volumes command args lifecycle
              initContainers priorityClassName nodeSelector tolerations;
      strategy = { type = "Recreate"; };
      containerSecurityContext = securityContext;
      inherit podSecurityContext;
      serviceAccountName = fullname;
      livenessProbe = liveness;
      readinessProbe = readiness;
      podAnnotations = podAnnotations // meta.mkPrometheusAnnotations monitoring;
      podLabels = selectorLabels;
      inherit attestation;
    };

    _service = svc.mkService {
      name = fullname; inherit namespace labels selectorLabels attestation;
      type = service.type or "ClusterIP";
      ports = service.ports or [];
    };

    _serviceMonitor = if (monitoring.enabled or true)
      then smLib.mkServiceMonitor { name = fullname; inherit namespace labels selectorLabels; }
      else null;

    _networkPolicies = np.mkNetworkPolicySet {
      name = fullname; inherit namespace labels selectorLabels;
      enabled = networkPolicy.enabled or true;
    };

  in {
    serviceAccount = _serviceAccount;
    clusterRole = _clusterRole;
    clusterRoleBinding = _clusterRoleBinding;
    deployment = _deployment;
    service = _service;
    serviceMonitor = _serviceMonitor;
    networkPolicies = _networkPolicies;
    allResources =
      o _serviceAccount ++ o _clusterRole ++ o _clusterRoleBinding
      ++ o _deployment ++ o _service ++ o _serviceMonitor
      ++ _networkPolicies;
  };
}
