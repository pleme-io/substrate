{ lib }:
rec {
  table = {
    session-host = {
      launchd = { ProcessType = "Interactive"; Nice = 0; LowPriorityIO = false; };
      systemd = { Nice = 0; CPUWeight = 100; IOWeight = 100; };
    };
    latency-server = {
      launchd = { ProcessType = "Interactive"; Nice = 0; LowPriorityIO = false; };
      systemd = { Nice = 0; CPUWeight = 200; IOWeight = 200; };
    };
    service = {
      launchd = { ProcessType = "Standard"; Nice = 0; LowPriorityIO = false; };
      systemd = { Nice = 0; CPUWeight = 100; IOWeight = 100; };
    };
    background = {
      launchd = { ProcessType = "Background"; Nice = 10; LowPriorityIO = true; };
      systemd = { Nice = 10; CPUWeight = 20; IOWeight = 20; };
    };
    xpc-adaptive = {
      launchd = { ProcessType = "Adaptive"; };
      systemd = { };
    };
  };

  classes = builtins.attrNames table;

  type = lib.types.enum classes;

  launchd = class: table.${class}.launchd;

  systemd = class: table.${class}.systemd;

  launchdOr = raw: class: if class == null then raw else launchd class;

  systemdOr = raw: class: if class == null then raw else systemd class;

  besideProcessType = { daemon, class, processType }:
    "${daemon}: workloadClass \"${class}\" renders ProcessType \"${(launchd class).ProcessType}\"; processType \"${processType}\" beside it is not rendered";
}
