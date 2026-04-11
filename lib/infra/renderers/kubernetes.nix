# Kubernetes renderer — translates abstract workload specs to K8s manifests.
#
# Delegates to the existing nix-kube composition library.
# No duplication — the archetype spec is mapped to nix-kube arguments.
let
  micro = import ../../kube/compositions/microservice.nix;
  worker = import ../../kube/compositions/worker.nix;
  cron = import ../../kube/compositions/cronjob.nix;
  web = import ../../kube/compositions/web.nix;
  db = import ../../kube/compositions/database.nix;
  eval = import ../../kube/eval.nix;
in {
  render = spec: let
    namespace = spec.meta.namespace or "default";
    image = spec.image or "placeholder:latest";

    # Common arguments mapped from abstract spec to nix-kube
    commonArgs = {
      inherit (spec) name;
      inherit namespace image;
      ports = spec.ports;
      resources = spec.resources;
      env = builtins.attrValues (builtins.mapAttrs (k: v: { name = k; value = v; }) (spec.env or {}));
      monitoring = { enabled = true; };
      networkPolicy = { enabled = true; };
      additionalLabels = spec.labels or {};
    } // (if spec.health != null then {
      health = spec.health;
    } else {})
    // (if spec.scaling != null then {
      autoscaling = spec.scaling // { enabled = true; };
      replicas = spec.scaling.min or spec.replicas;
    } else {
      replicas = spec.replicas;
    });

    rendered = {
      "http-service" = micro.mkMicroservice (commonArgs // {
        service = {
          type = spec.meta.serviceType or "ClusterIP";
          ports = spec.ports;
        };
      });
      "worker" = worker.mkWorker commonArgs;
      "cron-job" = cron.mkCronjobService (commonArgs // {
        schedule = spec.schedule or "*/5 * * * *";
      });
      "gateway" = web.mkWeb commonArgs;
      "stateful-service" = db.mkDatabase (commonArgs // {
        storage = (builtins.head (spec.volumes or [{ storage = "10Gi"; }])).storage or "10Gi";
      });
      "function" = micro.mkMicroservice (commonArgs // {
        service = { type = "ClusterIP"; ports = spec.ports; };
        # KEDA ScaledObject would be added via breathability
      });
      "frontend" = web.mkWeb commonArgs;
    };

    result = rendered.${spec.archetype} or (micro.mkMicroservice commonArgs);
  in eval.mkKubeEval { resources = result; };
}
