# Tatara renderer — translates abstract workload specs to tatara job specs.
#
# Produces JSON-compatible attrsets matching tatara's JobSpec format.
# Auto-selects driver based on available build outputs.
{
  render = spec: let
    # Map archetype to tatara job type
    jobType = {
      "http-service" = "service";
      "worker" = "service";
      "cron-job" = "batch";
      "gateway" = "service";
      "stateful-service" = "service";
      "function" = "service";
      "frontend" = "service";
    }.${spec.archetype} or "service";

    # Auto-select driver
    driver =
      if spec.wasmPath != null then "wasi"
      else if spec.flakeRef != null then "nix"
      else if spec.image != null then "oci"
      else if spec.command != null then "exec"
      else "nix";

    # Build driver-specific task config
    taskConfig =
      if driver == "wasi" then {
        type = "wasi";
        wasm_path = spec.wasmPath;
        capabilities = {
          network = (spec.network.egress or []) != [];
          filesystem = (spec.volumes or []) != [];
          clocks = true;
          random = true;
          stdout = true;
          stderr = true;
        };
        mounts = builtins.listToAttrs (map (v: {
          name = v.hostPath or "/tmp/${v.name}";
          value = v.mountPath or "/${v.name}";
        }) (spec.volumes or []));
        allowed_services = map (e: e.service) (spec.network.egress or []);
      }
      else if driver == "nix" then {
        type = "nix";
        flake_ref = spec.flakeRef or "";
        args = spec.args' or [];
      }
      else if driver == "oci" then {
        type = "oci";
        image = spec.image or "";
        ports = builtins.listToAttrs (map (p: {
          name = toString p.port;
          value = toString p.port;
        }) (spec.ports or []));
      }
      else {
        type = "exec";
        command = spec.command or "echo";
        args = spec.args' or [ "hello" ];
      };

    # Parse K8s resource strings to numeric values
    parseCpu = s:
      if builtins.isInt s then s
      else if builtins.isString s then
        let m = builtins.match "([0-9]+)m$" s; in
        if m != null then builtins.fromJSON (builtins.head m)
        else let cores = builtins.match "([0-9]+)$" s; in
        if cores != null then (builtins.fromJSON (builtins.head cores)) * 1000
        else 0
      else 0;
    parseMem = s:
      if builtins.isInt s then s
      else if builtins.isString s then
        let gi = builtins.match "([0-9]+)Gi$" s; in
        if gi != null then (builtins.fromJSON (builtins.head gi)) * 1024
        else let mi = builtins.match "([0-9]+)Mi$" s; in
        if mi != null then builtins.fromJSON (builtins.head mi)
        else let g = builtins.match "([0-9]+)G$" s; in
        if g != null then (builtins.fromJSON (builtins.head g)) * 1000
        else let m = builtins.match "([0-9]+)M$" s; in
        if m != null then builtins.fromJSON (builtins.head m)
        else let ki = builtins.match "([0-9]+)Ki$" s; in
        if ki != null then (builtins.fromJSON (builtins.head ki)) / 1024
        else 0
      else 0;

  in {
    id = spec.name;
    job_type = jobType;
    groups = [{
      name = "main";
      count = spec.replicas;
      tasks = [{
        name = spec.name;
        driver = driver;
        config = taskConfig;
        env = spec.env or {};
        resources = {
          cpu_mhz = parseCpu (spec.resources.cpu or "0");
          memory_mb = parseMem (spec.resources.memory or "0");
        };
        health_checks =
          if spec.health != null then [{
            type = "http";
            port = (builtins.head (spec.ports or [{ port = 8080; }])).port;
            path = spec.health.path or "/healthz";
            interval_secs = 10;
            timeout_secs = 5;
          }] else [];
      }];
      service_name = spec.serviceName;
      secrets = map (s: {
        name = s.name;
        provider = s.provider or "env";
        key = s.key or s.name;
        env_var = s.envVar or (builtins.replaceStrings ["-"] ["_"] (builtins.toUpper s.name));
      }) (spec.secrets or []);
    }];
    constraints = [];
    meta = spec.meta or {};
  };
}
