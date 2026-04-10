# Kubernetes probe builders.
#
# Pure functions — no pkgs dependency.
let
  defs = import ../defaults.nix;
in rec {
  mkHttpProbe = {
    path,
    port ? "http",
    initialDelaySeconds ? 5,
    periodSeconds ? 10,
    failureThreshold ? 3,
    timeoutSeconds ? null,
    successThreshold ? null,
  }: {
    httpGet = { inherit path port; };
    inherit initialDelaySeconds periodSeconds failureThreshold;
  } // (if timeoutSeconds != null then { inherit timeoutSeconds; } else {})
    // (if successThreshold != null then { inherit successThreshold; } else {});

  mkTcpProbe = {
    port,
    initialDelaySeconds ? 5,
    periodSeconds ? 10,
    failureThreshold ? 3,
  }: {
    tcpSocket = { inherit port; };
    inherit initialDelaySeconds periodSeconds failureThreshold;
  };

  mkExecProbe = {
    command,
    initialDelaySeconds ? 5,
    periodSeconds ? 10,
    failureThreshold ? 3,
  }: {
    exec = { inherit command; };
    inherit initialDelaySeconds periodSeconds failureThreshold;
  };

  mkLivenessProbe = args: mkHttpProbe ({
    path = defs.liveness.path;
    port = defs.liveness.port;
    initialDelaySeconds = defs.liveness.initialDelaySeconds;
    periodSeconds = defs.liveness.periodSeconds;
    failureThreshold = defs.liveness.failureThreshold;
  } // args);

  mkReadinessProbe = args: mkHttpProbe ({
    path = defs.readiness.path;
    port = defs.readiness.port;
    initialDelaySeconds = defs.readiness.initialDelaySeconds;
    periodSeconds = defs.readiness.periodSeconds;
    failureThreshold = defs.readiness.failureThreshold;
  } // args);

  mkStartupProbe = args: mkHttpProbe ({
    path = defs.startup.path;
    port = defs.startup.port;
    initialDelaySeconds = defs.startup.initialDelaySeconds;
    periodSeconds = defs.startup.periodSeconds;
    failureThreshold = defs.startup.failureThreshold;
  } // args);
}
