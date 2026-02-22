# Home-manager module helpers for daemon + MCP tool services
#
# Reusable patterns shared by zoekt-mcp, codesearch, and any future tool
# that follows the daemon + MCP server entry pattern.
#
# Usage (in flake.nix):
#   homeManagerModules.default = import ./module {
#     hmHelpers = import "${substrate}/lib/hm-service-helpers.nix" { lib = nixpkgs.lib; };
#   };
#
# Usage (in module/default.nix):
#   { hmHelpers }: { lib, config, pkgs, ... }:
#   let inherit (hmHelpers) mkMcpOptions mkMcpServerEntry mkLaunchdService ...; in { ... }
{ lib }:
with lib;
{
  # ─── MCP server entry options ─────────────────────────────────────────
  # Standard option set for services.<name>.mcp: { enable, package, serverEntry }
  #
  # serverEntry is internal — set by the module config, consumed by claude module.
  #
  # Example:
  #   options.services.myTool.mcp = hmHelpers.mkMcpOptions {
  #     defaultPackage = daemonCfg.package;
  #     defaultPackageText = "config.services.myTool.daemon.package";
  #   };
  mkMcpOptions = {
    defaultPackage,
    defaultPackageText ? null,
  }: {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Generate MCP server entry (consumed by claude modules)";
    };

    package = mkOption {
      type = types.package;
      default = defaultPackage;
      description = "Package providing the MCP server binary";
    } // optionalAttrs (defaultPackageText != null) {
      defaultText = literalExpression defaultPackageText;
    };

    serverEntry = mkOption {
      type = types.attrs;
      default = {};
      internal = true;
      description = "Generated MCP server attrset — consumed by claude module, not set by users";
    };
  };

  # ─── MCP server entry value ──────────────────────────────────────────
  # Builds the standard stdio MCP entry attrset.
  #
  # Example:
  #   hmHelpers.mkMcpServerEntry {
  #     command = "${mcpCfg.package}/bin/zoekt-mcp";
  #     env.ZOEKT_URL = "http://localhost:${toString port}";
  #   }
  mkMcpServerEntry = {
    command,
    args ? [],
    env ? {},
  }: {
    type = "stdio";
    command = toString command;
  } // optionalAttrs (args != []) {
    inherit args;
  } // optionalAttrs (env != {}) {
    inherit env;
  };

  # ─── Darwin launchd service (persistent, KeepAlive) ───────────────────
  # Returns a config block: { launchd.agents.<name> = { ... }; }
  #
  # Example:
  #   hmHelpers.mkLaunchdService {
  #     name = "zoekt-webserver";
  #     label = "io.pleme.zoekt-webserver";
  #     command = "${pkg}/bin/zoekt-webserver";
  #     args = ["-index" indexDir "-listen" ":${port}"];
  #     logDir = "${homeDir}/Library/Logs";
  #   }
  mkLaunchdService = {
    name,
    label,
    command,
    args ? [],
    env ? {},
    logDir,
    keepAlive ? true,
    runAtLoad ? true,
    processType ? "Adaptive",
  }: {
    launchd.agents.${name} = {
      enable = true;
      config = {
        Label = label;
        ProgramArguments = [command] ++ args;
        RunAtLoad = runAtLoad;
        KeepAlive = keepAlive;
        ProcessType = processType;
        StandardOutPath = "${logDir}/${name}.log";
        StandardErrorPath = "${logDir}/${name}.err";
      } // optionalAttrs (env != {}) {
        EnvironmentVariables = env;
      };
    };
  };

  # ─── Darwin launchd periodic task ─────────────────────────────────────
  # Returns a config block for a periodic (StartInterval) launchd agent.
  # Runs as low-priority background work with IO throttling.
  mkLaunchdPeriodicTask = {
    name,
    label,
    command,
    args ? [],
    interval,
    logDir,
    runAtLoad ? true,
  }: {
    launchd.agents.${name} = {
      enable = true;
      config = {
        Label = label;
        ProgramArguments = [command] ++ args;
        StartInterval = interval;
        RunAtLoad = runAtLoad;
        ProcessType = "Background";
        LowPriorityIO = true;
        Nice = 10;
        StandardOutPath = "${logDir}/${name}.log";
        StandardErrorPath = "${logDir}/${name}.err";
      };
    };
  };

  # ─── Linux systemd user service (persistent) ─────────────────────────
  # Returns a config block: { systemd.user.services.<name> = { ... }; }
  mkSystemdService = {
    name,
    description,
    command,
    args ? [],
    env ? {},
    after ? ["default.target"],
    wantedBy ? ["default.target"],
    preStart ? null,
    restartSec ? 5,
  }: {
    systemd.user.services.${name} = {
      Unit = {
        Description = description;
        After = after;
      };
      Service = {
        Type = "simple";
        ExecStart = concatStringsSep " " ([command] ++ args);
        Restart = "on-failure";
        RestartSec = restartSec;
      } // optionalAttrs (env != {}) {
        Environment = mapAttrsToList (k: v: "${k}=${v}") env;
      } // optionalAttrs (preStart != null) {
        ExecStartPre = preStart;
      };
      Install.WantedBy = wantedBy;
    };
  };

  # ─── Linux systemd periodic task (oneshot + timer) ───────────────────
  # Returns a config block with both the oneshot service and its timer.
  mkSystemdPeriodicTask = {
    name,
    description,
    command,
    args ? [],
    interval,
    after ? [],
    bootDelay ? "30s",
  }: {
    systemd.user.services.${name} = {
      Unit = {
        Description = description;
      } // optionalAttrs (after != []) {
        After = after;
      };
      Service = {
        Type = "oneshot";
        ExecStart = concatStringsSep " " ([command] ++ args);
      };
    };

    systemd.user.timers.${name} = {
      Unit.Description = "${description} timer";
      Timer = {
        OnBootSec = bootDelay;
        OnUnitActiveSec = "${toString interval}s";
        Unit = "${name}.service";
      };
      Install.WantedBy = ["timers.target"];
    };
  };
}
