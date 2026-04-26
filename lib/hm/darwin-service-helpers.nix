# nix-darwin module helpers for system-level services.
#
# Provides launchd.daemons primitives — the system-level analog to
# nixos-service-helpers.nix's mkNixOSService. For per-user launchd
# agents (HM-level), see hm/service-helpers.nix's mkLaunchdService.
#
# Three layers of launchd on macOS:
#   - launchd.daemons.<name>    -- system-wide, runs as root or a service user (THIS FILE)
#   - launchd.user.agents.<name> -- nix-darwin per-user (rare; HM is preferred)
#   - launchd.agents.<name>      -- home-manager per-user (hm/service-helpers.nix)
#
# Usage (in flake.nix):
#   darwinModules.<name> = import ./module/darwin {
#     darwinHelpers = import "${substrate}/lib/darwin-service-helpers.nix" { lib = nixpkgs.lib; };
#   };
#
# Usage (in module):
#   { darwinHelpers }: { config, lib, pkgs, ... }:
#   let inherit (darwinHelpers) mkLaunchdDaemon mkLaunchdPeriodicDaemon ...; in { ... }
{ lib }:
with lib;
{
  # ─── System-level launchd daemon (persistent, runs as root) ──────────
  # Returns: { launchd.daemons.<name> = { serviceConfig = { ... }; }; }
  #
  # Analogous to mkNixOSService for system-level systemd services.
  # Use this for daemons that must run as root or a dedicated service user.
  # For per-user agents, use hmHelpers.mkLaunchdService instead.
  #
  # Example:
  #   darwinHelpers.mkLaunchdDaemon {
  #     name = "k3s-server";
  #     label = "io.pleme.k3s-server";
  #     command = "${pkg}/bin/k3s";
  #     args = ["server" "--cluster-cidr" "10.42.0.0/16"];
  #     userName = "root";
  #     keepAlive = true;
  #     logDir = "/var/log";
  #   }
  mkLaunchdDaemon = {
    name,
    label,
    command,
    args ? [],
    env ? {},
    logDir ? "/var/log",
    keepAlive ? true,
    runAtLoad ? true,
    processType ? "Adaptive",
    userName ? "root",
    groupName ? null,
    workingDirectory ? null,
    softResourceLimits ? null,
    hardResourceLimits ? null,
  }: {
    launchd.daemons.${name} = {
      serviceConfig = {
        Label = label;
        ProgramArguments = [ command ] ++ args;
        RunAtLoad = runAtLoad;
        KeepAlive = keepAlive;
        ProcessType = processType;
        StandardOutPath = "${logDir}/${name}.log";
        StandardErrorPath = "${logDir}/${name}.err";
        UserName = userName;
      } // optionalAttrs (env != {}) {
        EnvironmentVariables = env;
      } // optionalAttrs (groupName != null) {
        GroupName = groupName;
      } // optionalAttrs (workingDirectory != null) {
        WorkingDirectory = workingDirectory;
      } // optionalAttrs (softResourceLimits != null) {
        SoftResourceLimits = softResourceLimits;
      } // optionalAttrs (hardResourceLimits != null) {
        HardResourceLimits = hardResourceLimits;
      };
    };
  };

  # ─── System-level periodic daemon (interval-driven) ──────────────────
  # Runs at fixed intervals as a low-priority background daemon.
  # Use for cleanup jobs, sync sweeps, health probes.
  mkLaunchdPeriodicDaemon = {
    name,
    label,
    command,
    args ? [],
    interval,
    logDir ? "/var/log",
    runAtLoad ? true,
    userName ? "root",
  }: {
    launchd.daemons.${name} = {
      serviceConfig = {
        Label = label;
        ProgramArguments = [ command ] ++ args;
        StartInterval = interval;
        RunAtLoad = runAtLoad;
        ProcessType = "Background";
        LowPriorityIO = true;
        Nice = 10;
        StandardOutPath = "${logDir}/${name}.log";
        StandardErrorPath = "${logDir}/${name}.err";
        UserName = userName;
      };
    };
  };

  # ─── System-level scheduled daemon (calendar-driven) ─────────────────
  # Runs at specific calendar times. calendarSpec is a single attrset or
  # list of attrsets, each in launchd StartCalendarInterval shape:
  #   { Hour = 3; Minute = 0; }            # daily at 3:00am
  #   { Weekday = 1; Hour = 0; Minute = 0; }  # Mondays at midnight
  mkLaunchdScheduledDaemon = {
    name,
    label,
    command,
    args ? [],
    calendarSpec,
    logDir ? "/var/log",
    userName ? "root",
  }: {
    launchd.daemons.${name} = {
      serviceConfig = {
        Label = label;
        ProgramArguments = [ command ] ++ args;
        StartCalendarInterval = if isList calendarSpec then calendarSpec else [ calendarSpec ];
        ProcessType = "Background";
        LowPriorityIO = true;
        StandardOutPath = "${logDir}/${name}.log";
        StandardErrorPath = "${logDir}/${name}.err";
        UserName = userName;
      };
    };
  };

  # ─── Watchpath-triggered daemon ──────────────────────────────────────
  # Runs when files at watchPaths change. Useful for config-change
  # reactions or filesystem-driven workflows.
  mkLaunchdWatchDaemon = {
    name,
    label,
    command,
    args ? [],
    watchPaths,
    logDir ? "/var/log",
    userName ? "root",
  }: {
    launchd.daemons.${name} = {
      serviceConfig = {
        Label = label;
        ProgramArguments = [ command ] ++ args;
        WatchPaths = watchPaths;
        ProcessType = "Background";
        StandardOutPath = "${logDir}/${name}.log";
        StandardErrorPath = "${logDir}/${name}.err";
        UserName = userName;
      };
    };
  };

  # ─── System-wide defaults ────────────────────────────────────────────
  # Wraps system.defaults pattern for nix-darwin modules.
  # Returns: { system.defaults.<domain> = settings; }
  mkSystemDefaults = {
    domain,
    settings,
  }: {
    system.defaults.${domain} = settings;
  };

  # ─── Service user (system) ───────────────────────────────────────────
  # Creates a dedicated system user for daemon execution.
  # Returns: { users.users.<name>; users.groups.<name>; }
  #
  # Note: nix-darwin requires `users.knownUsers` for dscl creation.
  mkServiceUser = {
    name,
    uid,
    gid ? uid,
    home ? "/var/empty",
    description ? "Service user for ${name}",
    shell ? "/usr/bin/false",
  }: {
    users.knownUsers = [ name ];
    users.knownGroups = [ name ];
    users.users.${name} = {
      inherit uid gid home description shell;
    };
    users.groups.${name} = {
      inherit gid;
      members = [ name ];
    };
  };

  # ─── System package install (Darwin) ─────────────────────────────────
  # Mirror of mkNixOSService's environment.systemPackages pattern.
  mkSystemPackage = pkg: {
    environment.systemPackages = [ pkg ];
  };

  # ─── Homebrew compatibility shim (rare) ──────────────────────────────
  # For darwin-only deps not yet packaged in nixpkgs. Use sparingly.
  mkHomebrewPackage = {
    casks ? [],
    brews ? [],
    masApps ? {},
  }: {
    homebrew = {}
      // optionalAttrs (casks != []) { inherit casks; }
      // optionalAttrs (brews != []) { inherit brews; }
      // optionalAttrs (masApps != {}) { masApps = masApps; };
  };
}
