# nix-kube evaluation and dependency ordering.
#
# Flattens composition outputs into ordered resource lists for the reconciler.
# Consumed via: nix eval --json .#kubeResources.<system>.clusters.<name>
#
# Pure functions — no pkgs dependency.
rec {
  # Default dependency order: lower number = deploy first, delete last.
  defaultDependencyOrder = {
    "Namespace" = 0;
    "CustomResourceDefinition" = 10;
    "PriorityClass" = 15;
    "StorageClass" = 16;
    "ClusterRole" = 20;
    "ClusterRoleBinding" = 21;
    "ServiceAccount" = 30;
    "Role" = 31;
    "RoleBinding" = 32;
    "ConfigMap" = 40;
    "Secret" = 41;
    "ExternalSecret" = 42;
    "PersistentVolumeClaim" = 45;
    "PersistentVolume" = 44;
    "LimitRange" = 50;
    "ResourceQuota" = 51;
    "NetworkPolicy" = 55;
    "Service" = 60;
    "DatabaseMigration" = 65;
    "Deployment" = 70;
    "StatefulSet" = 71;
    "DaemonSet" = 72;
    "CronJob" = 73;
    "Job" = 74;
    "HorizontalPodAutoscaler" = 80;
    "PodDisruptionBudget" = 81;
    "ScaledObject" = 82;
    "ServiceMonitor" = 90;
    "PodMonitor" = 91;
    "PrometheusRule" = 92;
    "Ingress" = 85;
    "IngressClass" = 84;
    "PeerAuthentication" = 95;
    "DestinationRule" = 96;
    "VirtualService" = 86;
    "Gateway" = 87;
    "HTTPRoute" = 88;
    "GRPCRoute" = 88;
    "MutatingWebhookConfiguration" = 98;
    "ValidatingWebhookConfiguration" = 99;
  };

  # Sort resources by kind priority, then namespace, then name.
  sortByKind = order: resources:
    builtins.sort (a: b:
      let
        pa = order.${a.kind} or 100;
        pb = order.${b.kind} or 100;
        na = a.metadata.namespace or "";
        nb = b.metadata.namespace or "";
        nameA = a.metadata.name or "";
        nameB = b.metadata.name or "";
      in
        if pa != pb then pa < pb
        else if na != nb then na < nb
        else nameA < nameB
    ) resources;

  # Flatten a composition result into an ordered resource list.
  # Accepts either:
  #   - A list of resources (pass through)
  #   - An attrset with an `allResources` field
  #   - An attrset of resources (auto-flatten)
  flatten = resources:
    if builtins.isList resources then resources
    else if resources ? allResources then resources.allResources
    else
      let
        vals = builtins.attrValues resources;
        flattenOne = v:
          if v == null then []
          else if builtins.isList v then builtins.concatMap flattenOne v
          else if builtins.isAttrs v && v ? apiVersion then [ v ]
          else if builtins.isAttrs v then builtins.concatMap flattenOne (builtins.attrValues v)
          else [];
      in builtins.concatMap flattenOne vals;

  # Evaluate and order a set of resources for the reconciler.
  mkKubeEval = {
    resources,
    dependencyOrder ? defaultDependencyOrder,
  }: let
    flat = flatten resources;
    filtered = builtins.filter (r: r != null) flat;
  in sortByKind dependencyOrder filtered;

  # Merge multiple resource sets into a single ordered list.
  mergeResourceSets = {
    sets,
    dependencyOrder ? defaultDependencyOrder,
  }: let
    allFlat = builtins.concatMap (s: flatten s) sets;
    filtered = builtins.filter (r: r != null) allFlat;
  in sortByKind dependencyOrder filtered;

  # Build a complete cluster definition from named service compositions.
  mkCluster = {
    name,
    services ? {},
    infrastructure ? {},
    dependencyOrder ? defaultDependencyOrder,
  }: let
    infraResources = builtins.concatMap (s: flatten s) (builtins.attrValues infrastructure);
    serviceResources = builtins.concatMap (s: flatten s) (builtins.attrValues services);
    all = builtins.filter (r: r != null) (infraResources ++ serviceResources);
  in sortByKind dependencyOrder all;
}
