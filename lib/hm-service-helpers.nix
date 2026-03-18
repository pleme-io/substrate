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
      description = "DEPRECATED: use mkAnvilRegistration. Generated MCP server attrset.";
    };

    scopes = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Anvil scopes — controls which agent profiles receive this server. Empty = all profiles.";
    };
  };

  # ─── MCP server entry value (DEPRECATED — use mkAnvilRegistration) ───
  # Builds the standard stdio MCP entry attrset.
  # Kept for backward compatibility. New services should use
  # mkAnvilRegistration to self-register with blackmatter-anvil.
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

  # ─── Anvil self-registration ────────────────────────────────────────
  # Generates config that writes an MCP server definition to anvil.
  # Used by service modules to register with blackmatter-anvil when
  # mcp.enable = true, eliminating the need for manual bridge code.
  #
  # Returns a config attrset: { blackmatter.components.anvil.mcp.servers.<name> = { ... }; }
  #
  # Requires blackmatter-anvil module to be loaded (standard for all
  # pleme-io deployments via darwinConfigurations sharedModules).
  #
  # Example:
  #   config = mkIf mcpCfg.enable (mkAnvilRegistration {
  #     name = "zoekt";
  #     command = "zoekt-mcp";
  #     package = mcpCfg.package;
  #     env.ZOEKT_URL = "http://localhost:6070";
  #     scopes = mcpCfg.scopes;
  #   });
  mkAnvilRegistration = {
    name,
    command,
    args ? [],
    env ? {},
    envFiles ? {},
    package ? null,
    description ? "",
    scopes ? [],
    agents ? [],
  }: {
    blackmatter.components.anvil.mcp.servers.${name} = {
      inherit command args env envFiles description scopes agents;
    } // optionalAttrs (package != null) { inherit package; };
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
