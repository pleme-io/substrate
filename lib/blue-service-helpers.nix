# substrate/lib/blue-service-helpers.nix
#
# A blue program as a system service that runs on an interval: one spec, the
# launchd daemon on nix-darwin and the systemd service + timer on NixOS, so a
# fleet tool written in blue runs the same way on every node. The program
# itself is a package from mkBlueProgramPackage (build/scripting/
# blue-program-package.nix); these return module fragments to merge into
# `config`.
#
# One run per tick, not a long-lived loop: the scheduler restarts it, a crash
# costs one tick, and the program holds no state between runs except what it
# writes to disk.
#
# Usage (inside a module's `config`):
#
#   helpers = import "${substrate}/lib/blue-service-helpers.nix" { inherit lib; };
#   config = lib.mkIf cfg.enable (helpers.mkBlueIntervalDarwin {
#     name = "tehai"; package = cfg.package; intervalSeconds = 15;
#   });
{ lib }:
{
  # nix-darwin: launchd.daemons.<name>, as root, at load and every interval.
  mkBlueIntervalDarwin =
    {
      name,
      package,
      intervalSeconds,
      environment ? { },
      label ? "io.pleme.${name}",
    }:
    {
      launchd.daemons.${name}.serviceConfig = {
        Label = label;
        ProgramArguments = [ (lib.getExe package) ];
        StartInterval = intervalSeconds;
        RunAtLoad = true;
        EnvironmentVariables = environment;
        StandardOutPath = "/var/log/${name}.log";
        StandardErrorPath = "/var/log/${name}.log";
      };
    };

  # NixOS: a oneshot systemd service, started at boot and every interval by a
  # timer.
  mkBlueIntervalNixos =
    {
      name,
      package,
      intervalSeconds,
      environment ? { },
      description ? "${name} (a blue program, every ${toString intervalSeconds}s)",
    }:
    {
      systemd.services.${name} = {
        inherit description environment;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe package;
        };
      };
      systemd.timers.${name} = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "10s";
          OnUnitActiveSec = "${toString intervalSeconds}s";
          AccuracySec = "1s";
        };
      };
    };
}
