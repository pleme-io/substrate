# WASI renderer — translates abstract workload specs to WASI component configs.
#
# Maps abstract capabilities to WASI Preview 2 interfaces.
{
  render = spec: let
    hasNetwork = (spec.network.egress or []) != [] || (spec.ports or []) != [];
    hasFilesystem = (spec.volumes or []) != [];
    hasHttp = (spec.ports or []) != [];
  in {
    # Component metadata
    name = spec.name;
    wasm_path = spec.wasmPath;

    # WASI capability grants (capability-based security)
    capabilities = {
      network = hasNetwork;
      filesystem = hasFilesystem;
      clocks = true;
      random = true;
      stdout = true;
      stderr = true;
    };

    # WASI world (which WIT interfaces the component uses)
    world =
      if hasHttp then "tatara-service"    # exports wasi:http/incoming-handler
      else "tatara-worker";                # imports only, no HTTP export

    # Filesystem mounts
    mounts = builtins.listToAttrs (map (v: {
      name = v.hostPath or "/tmp/${v.name}";
      value = v.mountPath or "/${v.name}";
    }) (spec.volumes or []));

    # Network policy for WASI sandbox
    network = {
      allowed_services = map (e: e.service) (spec.network.egress or []);
      allowed_addresses = [];
    };

    # WASI interfaces imported by this component
    imports = [
      "wasi:cli/environment@0.2.0"
      "wasi:clocks/monotonic-clock@0.2.0"
      "wasi:random/random@0.2.0"
    ]
    ++ (if hasNetwork then [ "wasi:sockets/tcp@0.2.0" "wasi:sockets/udp@0.2.0" ] else [])
    ++ (if hasHttp then [ "wasi:http/outgoing-handler@0.2.0" ] else [])
    ++ (if hasFilesystem then [ "wasi:filesystem/preopens@0.2.0" ] else [])
    ++ [
      # Tatara host interfaces
      "tatara:host/catalog@0.1.0"
      "tatara:host/config@0.1.0"
      "tatara:host/health@0.1.0"
      "tatara:host/secrets@0.1.0"
    ];

    # WASI interfaces exported by this component
    exports =
      if hasHttp then [ "wasi:http/incoming-handler@0.2.0" ]
      else [];

    # Resource limits
    fuel = let
      cpu = spec.resources.cpu or "100m";
      mhz = if builtins.match ".*m$" cpu != null
        then builtins.fromJSON (builtins.head (builtins.match "([0-9]+)m" cpu))
        else 0;
    in mhz * 1000000;

    max_memory_bytes = let
      mem = spec.resources.memory or "128Mi";
      mb = if builtins.match ".*Mi$" mem != null
        then builtins.fromJSON (builtins.head (builtins.match "([0-9]+)Mi" mem))
        else 128;
    in mb * 1024 * 1024;
  };
}
