# nix-kube pure evaluation tests.
#
# Run: nix eval --json -f lib/kube/tests.nix
# All tests return true on success, throw on failure.
let
  # Primitives
  meta = import ./primitives/metadata.nix;
  sec = import ./primitives/security.nix;
  probes = import ./primitives/probes.nix;
  containers = import ./primitives/container.nix;
  dep = import ./primitives/deployment.nix;
  svc = import ./primitives/service.nix;
  sa = import ./primitives/service-account.nix;
  cm = import ./primitives/config-map.nix;
  ns = import ./primitives/namespace.nix;
  rbac = import ./primitives/rbac.nix;
  np = import ./primitives/network-policy.nix;
  sm = import ./primitives/service-monitor.nix;
  pm = import ./primitives/pod-monitor.nix;
  hpa = import ./primitives/hpa.nix;
  pdb = import ./primitives/pdb.nix;
  pr = import ./primitives/prometheus-rule.nix;
  ss = import ./primitives/statefulset.nix;
  ds = import ./primitives/daemonset.nix;
  cj = import ./primitives/cronjob.nix;
  job = import ./primitives/job.nix;
  so = import ./primitives/scaled-object.nix;
  pa = import ./primitives/peer-auth.nix;
  dr = import ./primitives/destination-rule.nix;
  lr = import ./primitives/limit-range.nix;
  rq = import ./primitives/resource-quota.nix;
  pc = import ./primitives/priority-class.nix;
  sh = import ./primitives/shinka.nix;
  del = import ./primitives/delivery.nix;
  br = import ./primitives/breathability.nix;

  # Eval
  eval = import ./eval.nix;

  # Assertion helper
  assert' = name: cond:
    if cond then true
    else throw "Test failed: ${name}";
in rec {
  # ── Metadata ─────────────────────────────────────────────
  testMkLabels = let
    l = meta.mkLabels { name = "test"; instance = "test-release"; };
  in assert' "mkLabels sets app.kubernetes.io/name"
    (l."app.kubernetes.io/name" == "test" && l."app.kubernetes.io/instance" == "test-release");

  testMkSelectorLabels = let
    l = meta.mkSelectorLabels { name = "test"; };
  in assert' "mkSelectorLabels" (l."app.kubernetes.io/name" == "test");

  testMkFullname = let
    n = meta.mkFullname { name = "my-service"; };
  in assert' "mkFullname" (n == "my-service");

  testMkFullnameOverride = let
    n = meta.mkFullname { name = "x"; fullnameOverride = "custom"; };
  in assert' "mkFullname override" (n == "custom");

  testAttestationAnnotationsDisabled = let
    a = meta.mkAttestationAnnotations {};
  in assert' "attestation disabled returns empty" (a == {});

  testAttestationAnnotationsEnabled = let
    a = meta.mkAttestationAnnotations { enabled = true; signature = "blake3:abc"; };
  in assert' "attestation enabled" (a."sekiban.pleme.io/signature" == "blake3:abc");

  # ── Security ─────────────────────────────────────────────
  testPodSecurityContext = let
    c = sec.mkPodSecurityContext {};
  in assert' "pod security context" (c.runAsNonRoot == true && c.runAsUser == 1000);

  testContainerSecurityContext = let
    c = sec.mkContainerSecurityContext {};
  in assert' "container security context" (c.allowPrivilegeEscalation == false);

  # ── Probes ───────────────────────────────────────────────
  testLivenessProbe = let
    p = probes.mkLivenessProbe {};
  in assert' "liveness probe" (p.httpGet.path == "/healthz");

  testReadinessProbe = let
    p = probes.mkReadinessProbe {};
  in assert' "readiness probe" (p.httpGet.path == "/readyz");

  # ── Container ────────────────────────────────────────────
  testMkContainer = let
    c = containers.mkContainer { containerName = "app"; image = "test:v1"; };
  in assert' "container" (c.name == "app" && c.image == "test:v1");

  testContainerDownwardApi = let
    c = containers.mkContainer { containerName = "app"; image = "test:v1"; downwardApi = true; };
  in assert' "container downward api" (builtins.length c.env == 3);

  # ── Deployment ───────────────────────────────────────────
  testMkDeployment = let
    d = dep.mkDeployment {
      name = "app"; namespace = "default"; image = "test:v1";
      selectorLabels = { app = "test"; };
    };
  in assert' "deployment kind" (d.kind == "Deployment" && d.apiVersion == "apps/v1");

  testDeploymentNoReplicasWhenAutoscaling = let
    d = dep.mkDeployment {
      name = "app"; namespace = "default"; image = "test:v1";
      selectorLabels = { app = "test"; };
      autoscalingEnabled = true;
    };
  in assert' "deployment omits replicas with autoscaling" (!(d.spec ? replicas));

  # ── Service ──────────────────────────────────────────────
  testMkService = let
    s = svc.mkService {
      name = "app"; namespace = "default";
      selectorLabels = { app = "test"; };
      ports = [{ name = "http"; port = 8080; targetPort = "http"; }];
    };
  in assert' "service" (s.kind == "Service" && builtins.length s.spec.ports == 1);

  # ── ServiceAccount ───────────────────────────────────────
  testMkServiceAccount = let
    s = sa.mkServiceAccount { name = "app"; namespace = "default"; };
  in assert' "service account" (s.kind == "ServiceAccount");

  # ── ConfigMap ────────────────────────────────────────────
  testMkConfigMap = let
    c = cm.mkConfigMap { name = "cfg"; namespace = "default"; data = { key = "val"; }; };
  in assert' "configmap" (c.kind == "ConfigMap" && c.data.key == "val");

  # ── Namespace ────────────────────────────────────────────
  testMkNamespace = let
    n = ns.mkNamespace { name = "test-ns"; };
  in assert' "namespace" (n.kind == "Namespace" && n.metadata.name == "test-ns");

  # ── RBAC ─────────────────────────────────────────────────
  testMkClusterRole = let
    r = rbac.mkClusterRole { name = "test"; rules = [{ apiGroups = ["*"]; resources = ["*"]; verbs = ["*"]; }]; };
  in assert' "cluster role" (r.kind == "ClusterRole" && builtins.length r.rules == 1);

  testMkOperatorRbac = let
    r = rbac.mkOperatorRbac { name = "op"; namespace = "op-ns"; rules = []; };
  in assert' "operator rbac" (r ? serviceAccount && r ? clusterRole && r ? clusterRoleBinding);

  # ── NetworkPolicy ────────────────────────────────────────
  testMkNetworkPolicySet = let
    nps = np.mkNetworkPolicySet { name = "app"; namespace = "default"; selectorLabels = { app = "test"; }; };
  in assert' "network policy set" (builtins.length nps == 3);

  testMkNetworkPolicySetDisabled = let
    nps = np.mkNetworkPolicySet { name = "app"; namespace = "default"; selectorLabels = {}; enabled = false; };
  in assert' "network policy disabled" (nps == []);

  # ── ServiceMonitor ───────────────────────────────────────
  testMkServiceMonitor = let
    s = sm.mkServiceMonitor { name = "app"; namespace = "default"; };
  in assert' "service monitor" (s.kind == "ServiceMonitor");

  # ── PodMonitor ───────────────────────────────────────────
  testMkPodMonitor = let
    p = pm.mkPodMonitor { name = "app"; namespace = "default"; };
  in assert' "pod monitor" (p.kind == "PodMonitor");

  # ── HPA ──────────────────────────────────────────────────
  testMkHPA = let
    h = hpa.mkHPA { name = "app"; namespace = "default"; targetCPUUtilizationPercentage = 80; };
  in assert' "hpa" (h.kind == "HorizontalPodAutoscaler" && h.apiVersion == "autoscaling/v2");

  # ── PDB ──────────────────────────────────────────────────
  testMkPDB = let
    p = pdb.mkPDB { name = "app"; namespace = "default"; minAvailable = 1; };
  in assert' "pdb" (p.kind == "PodDisruptionBudget" && p.spec.minAvailable == 1);

  # ── PrometheusRule ───────────────────────────────────────
  testMkStandardAlerts = let
    a = pr.mkStandardAlerts { name = "app"; namespace = "default"; };
  in assert' "standard alerts" (a.kind == "PrometheusRule" && builtins.length (builtins.head a.spec.groups).rules == 4);

  # ── StatefulSet ──────────────────────────────────────────
  testMkStatefulSet = let
    s = ss.mkStatefulSet { name = "db"; namespace = "default"; image = "pg:16"; serviceName = "db"; };
  in assert' "statefulset" (s.kind == "StatefulSet");

  # ── DaemonSet ────────────────────────────────────────────
  testMkDaemonSet = let
    d = ds.mkDaemonSet { name = "agent"; namespace = "default"; image = "agent:v1"; };
  in assert' "daemonset" (d.kind == "DaemonSet");

  # ── CronJob ──────────────────────────────────────────────
  testMkCronJob = let
    c = cj.mkCronJob { name = "cron"; namespace = "default"; image = "job:v1"; schedule = "*/5 * * * *"; };
  in assert' "cronjob" (c.kind == "CronJob" && c.spec.schedule == "*/5 * * * *");

  # ── Job ──────────────────────────────────────────────────
  testMkJob = let
    j = job.mkJob { name = "mig"; namespace = "default"; image = "mig:v1"; };
  in assert' "job" (j.kind == "Job");

  # ── ScaledObject ─────────────────────────────────────────
  testMkScaledObject = let
    s = so.mkScaledObject { name = "worker"; namespace = "default"; targetRef = { kind = "Deployment"; name = "worker"; }; };
  in assert' "scaled object" (s.kind == "ScaledObject" && s.apiVersion == "keda.sh/v1alpha1");

  # ── Istio ────────────────────────────────────────────────
  testMkPeerAuthentication = let
    p = pa.mkPeerAuthentication { name = "app"; namespace = "default"; };
  in assert' "peer auth" (p.kind == "PeerAuthentication" && p.spec.mtls.mode == "STRICT");

  testMkDestinationRule = let
    d = dr.mkDestinationRule { name = "app"; namespace = "default"; host = "app.default.svc"; };
  in assert' "destination rule" (d.kind == "DestinationRule");

  # ── Governance ───────────────────────────────────────────
  testMkLimitRange = let
    l = lr.mkLimitRange { name = "lr"; namespace = "default"; container = { default.cpu = "200m"; }; };
  in assert' "limit range" (l.kind == "LimitRange" && builtins.length l.spec.limits == 1);

  testMkResourceQuota = let
    r = rq.mkResourceQuota { name = "rq"; namespace = "default"; hard = { "requests.cpu" = "4"; }; };
  in assert' "resource quota" (r.kind == "ResourceQuota");

  testMkPriorityClassSet = let
    pcs = pc.mkPriorityClassSet {};
  in assert' "priority class set" (builtins.length pcs == 4);

  # ── Shinka ───────────────────────────────────────────────
  testMkDatabaseMigration = let
    m = sh.mkDatabaseMigration {
      name = "app"; namespace = "default";
      database = { host = "db"; port = 5432; }; migrator = { tool = "sqlx"; };
    };
  in assert' "database migration" (m.kind == "DatabaseMigration");

  testMkShinkaWaitContainer = let
    c = sh.mkShinkaWaitContainer { name = "app"; };
  in assert' "shinka wait container" (c.name == "shinka-wait");

  # ── Delivery ─────────────────────────────────────────────
  testMkDeliveryConfig = let
    d = del.mkDeliveryConfig { name = "worker"; namespace = "default"; };
  in assert' "delivery config" (d.kind == "ConfigMap" && d.data ? "delivery.yaml");

  # ── Breathability ────────────────────────────────────────
  testMkBreathability = let
    b = br.mkBreathability {
      name = "worker"; namespace = "default";
      targetRef = { kind = "Deployment"; name = "worker"; };
    };
  in assert' "breathability" (builtins.length b == 1 && (builtins.head b).kind == "ScaledObject");

  # ── Eval ─────────────────────────────────────────────────
  testSortByKind = let
    resources = [
      { apiVersion = "apps/v1"; kind = "Deployment"; metadata = { name = "app"; namespace = "default"; }; }
      { apiVersion = "v1"; kind = "Namespace"; metadata = { name = "default"; }; }
      { apiVersion = "v1"; kind = "Service"; metadata = { name = "svc"; namespace = "default"; }; }
      { apiVersion = "v1"; kind = "ConfigMap"; metadata = { name = "cfg"; namespace = "default"; }; }
    ];
    sorted = eval.sortByKind eval.defaultDependencyOrder resources;
    kinds = map (r: r.kind) sorted;
  in assert' "sort by kind" (kinds == [ "Namespace" "ConfigMap" "Service" "Deployment" ]);

  testFlatten = let
    input = {
      deployment = { apiVersion = "apps/v1"; kind = "Deployment"; metadata.name = "app"; };
      service = { apiVersion = "v1"; kind = "Service"; metadata.name = "svc"; };
      ignored = null;
    };
    flat = eval.flatten input;
  in assert' "flatten" (builtins.length flat == 2);

  testMkKubeEval = let
    resources = [
      { apiVersion = "apps/v1"; kind = "Deployment"; metadata = { name = "app"; namespace = "ns"; }; }
      { apiVersion = "v1"; kind = "Namespace"; metadata = { name = "ns"; }; }
    ];
    result = eval.mkKubeEval { inherit resources; };
  in assert' "mkKubeEval orders correctly" ((builtins.head result).kind == "Namespace");

  # ── New: Secret ───────────────────────────────────────────
  secretLib = import ./primitives/secret.nix;
  testMkSecret = let
    s = secretLib.mkSecret { name = "db-creds"; namespace = "default"; type = "Opaque"; data = { password = "base64enc"; }; };
  in assert' "secret" (s.kind == "Secret" && s.type == "Opaque" && s.data.password == "base64enc");

  testMkTlsSecret = let
    s = secretLib.mkTlsSecret { name = "tls"; namespace = "default"; certData = "cert"; keyData = "key"; };
  in assert' "tls secret" (s.type == "kubernetes.io/tls");

  # ── New: Ingress ─────────────────────────────────────────
  ingressLib = import ./primitives/ingress.nix;
  testMkIngress = let
    i = ingressLib.mkIngress { name = "web"; namespace = "default"; rules = [{ host = "example.com"; }]; };
  in assert' "ingress" (i.kind == "Ingress" && i.apiVersion == "networking.k8s.io/v1");

  testMkSimpleIngress = let
    i = ingressLib.mkSimpleIngress {
      name = "web"; namespace = "default"; host = "example.com";
      serviceName = "web-svc"; servicePort = 8080;
    };
  in assert' "simple ingress" (i.kind == "Ingress" && builtins.length i.spec.rules == 1);

  # ── New: Probe variants ──────────────────────────────────
  testMkTcpProbe = let
    p = probes.mkTcpProbe { port = 5432; };
  in assert' "tcp probe" (p.tcpSocket.port == 5432);

  testMkExecProbe = let
    p = probes.mkExecProbe { command = [ "/bin/check" ]; };
  in assert' "exec probe" (builtins.length p.exec.command == 1);

  # ── New: Headless Service ────────────────────────────────
  testMkHeadlessService = let
    s = svc.mkHeadlessService { name = "db"; namespace = "default"; selectorLabels = { app = "db"; }; ports = [{ name = "pg"; port = 5432; targetPort = "pg"; }]; };
  in assert' "headless service" (s.spec.clusterIP == "None");

  # ── New: Annotations ─────────────────────────────────────
  testMkPrometheusAnnotations = let
    a = meta.mkPrometheusAnnotations {};
  in assert' "prometheus annotations" (a."prometheus.io/scrape" == "true");

  testMkIstioAnnotations = let
    a = meta.mkIstioAnnotations { enabled = true; };
  in assert' "istio annotations" (a."sidecar.istio.io/inject" == "true");

  testMkIstioAnnotationsDisabled = let
    a = meta.mkIstioAnnotations {};
  in assert' "istio disabled" (a == {});

  # ── New: Edge cases ──────────────────────────────────────
  testMkFullnameTruncation = let
    longName = "a-very-long-service-name-that-exceeds-the-kubernetes-sixty-three-character-limit-by-far";
    n = meta.mkFullname { name = longName; };
  in assert' "fullname truncates to 63" (builtins.stringLength n == 63);

  testEmptyNetworkPolicySet = let
    nps = np.mkNetworkPolicySet { name = "x"; namespace = "default"; selectorLabels = {}; enabled = true; };
  in assert' "network policy set with empty selectors" (builtins.length nps == 3);

  # ── New: Eval ordering with new kinds ────────────────────
  testSortWithIngress = let
    resources = [
      { apiVersion = "networking.k8s.io/v1"; kind = "Ingress"; metadata = { name = "web"; namespace = "default"; }; }
      { apiVersion = "apps/v1"; kind = "Deployment"; metadata = { name = "app"; namespace = "default"; }; }
      { apiVersion = "v1"; kind = "Service"; metadata = { name = "svc"; namespace = "default"; }; }
    ];
    sorted = eval.sortByKind eval.defaultDependencyOrder resources;
    kinds = map (r: r.kind) sorted;
  in assert' "ingress after service" (kinds == [ "Service" "Deployment" "Ingress" ]);

  # ── All tests pass ───────────────────────────────────────
  allPassed = builtins.all (x: x == true) (builtins.attrValues {
    inherit testMkLabels testMkSelectorLabels testMkFullname testMkFullnameOverride;
    inherit testAttestationAnnotationsDisabled testAttestationAnnotationsEnabled;
    inherit testPodSecurityContext testContainerSecurityContext;
    inherit testLivenessProbe testReadinessProbe;
    inherit testMkContainer testContainerDownwardApi;
    inherit testMkDeployment testDeploymentNoReplicasWhenAutoscaling;
    inherit testMkService testMkServiceAccount testMkConfigMap testMkNamespace;
    inherit testMkClusterRole testMkOperatorRbac;
    inherit testMkNetworkPolicySet testMkNetworkPolicySetDisabled;
    inherit testMkServiceMonitor testMkPodMonitor testMkHPA testMkPDB;
    inherit testMkStandardAlerts;
    inherit testMkStatefulSet testMkDaemonSet testMkCronJob testMkJob;
    inherit testMkScaledObject testMkPeerAuthentication testMkDestinationRule;
    inherit testMkLimitRange testMkResourceQuota testMkPriorityClassSet;
    inherit testMkDatabaseMigration testMkShinkaWaitContainer;
    inherit testMkDeliveryConfig testMkBreathability;
    inherit testSortByKind testFlatten testMkKubeEval;
    # New tests
    inherit testMkSecret testMkTlsSecret;
    inherit testMkIngress testMkSimpleIngress;
    inherit testMkTcpProbe testMkExecProbe;
    inherit testMkHeadlessService;
    inherit testMkPrometheusAnnotations testMkIstioAnnotations testMkIstioAnnotationsDisabled;
    inherit testMkFullnameTruncation testEmptyNetworkPolicySet;
    inherit testSortWithIngress;
  });
}
