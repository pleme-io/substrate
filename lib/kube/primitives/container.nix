# Kubernetes container builders.
#
# Pure functions — no pkgs dependency.
rec {
  mkContainer = {
    containerName,
    image,
    imagePullPolicy ? "Always",
    command ? [],
    args ? [],
    ports ? [],
    env ? [],
    envFrom ? [],
    resources ? {},
    securityContext ? {},
    livenessProbe ? null,
    readinessProbe ? null,
    startupProbe ? null,
    volumeMounts ? [],
    lifecycle ? {},
    downwardApi ? false,
  }: let
    downwardApiEnv = [
      { name = "POD_NAME"; valueFrom.fieldRef.fieldPath = "metadata.name"; }
      { name = "POD_NAMESPACE"; valueFrom.fieldRef.fieldPath = "metadata.namespace"; }
      { name = "NODE_NAME"; valueFrom.fieldRef.fieldPath = "spec.nodeName"; }
    ];
    allEnv = (if downwardApi then downwardApiEnv else []) ++ env;
  in {
    name = containerName;
    inherit image imagePullPolicy;
  }
  // (if command != [] then { inherit command; } else {})
  // (if args != [] then { inherit args; } else {})
  // (if ports != [] then { inherit ports; } else {})
  // (if allEnv != [] then { env = allEnv; } else {})
  // (if envFrom != [] then { inherit envFrom; } else {})
  // (if resources != {} then { inherit resources; } else {})
  // (if securityContext != {} then { inherit securityContext; } else {})
  // (if livenessProbe != null then { inherit livenessProbe; } else {})
  // (if readinessProbe != null then { inherit readinessProbe; } else {})
  // (if startupProbe != null then { inherit startupProbe; } else {})
  // (if volumeMounts != [] then { inherit volumeMounts; } else {})
  // (if lifecycle != {} then { inherit lifecycle; } else {});

  mkInitContainer = args: mkContainer args;
}
