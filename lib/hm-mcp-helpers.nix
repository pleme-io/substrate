# Home-manager MCP server deployment helpers
#
# Reusable patterns for AI coding agent MCP server management.
# Provides option types, wrapper script generation, server resolution,
# and per-agent filtering. Used by blackmatter-anvil and any module
# that manages MCP servers for AI coding agents.
#
# Usage (in flake.nix):
#   homeManagerModules.default = import ./module {
#     mcpHelpers = import "${substrate}/lib/hm-mcp-helpers.nix" { lib = nixpkgs.lib; };
#   };
#
# Usage (in module/default.nix):
#   { mcpHelpers }: { lib, config, pkgs, ... }:
#   let inherit (mcpHelpers) mcpServerOpts agentOpts mkMcpWrapper mkResolvedServers; in { ... }
#
# Used by: blackmatter-anvil, blackmatter-claude (via generatedServers)
{ lib }:
with lib;
let
  # ─── Internal: resolve command path from server definition ──────────
  _mkCommandPath = server:
    if server.package != null
    then "${server.package}/bin/${server.command}"
    else server.command;
# rec needed: mkResolvedServers→mkMcpWrapper, mkMcpJson→mkFilterForAgent,
# mkMcpAgentConfigs→mkMcpJson
in rec {
  # ─── MCP Server Option Type ────────────────────────────────────────
  # Submodule for defining an MCP server: command, args, credentials, etc.
  #
  # Example:
  #   options.mcp.servers = mkOption {
  #     type = types.attrsOf (types.submodule mcpHelpers.mcpServerOpts);
  #   };
  mcpServerOpts = { ... }: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether this MCP server is active.";
      };

      command = mkOption {
        type = types.str;
        description = "Executable command (binary name or path).";
      };

      args = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Arguments to pass to the command.";
      };

      env = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Static environment variables baked into the wrapper script.";
      };

      envFiles = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Env vars resolved from files at runtime. Key = var name, value = file path.";
      };

      package = mkOption {
        type = types.nullOr types.package;
        default = null;
        description = "Nix package providing the binary. Command is resolved relative to this.";
      };

      description = mkOption {
        type = types.str;
        default = "";
        description = "Human-readable description of what this server provides.";
      };

      agents = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Restrict to these agents. Empty list = deploy to all agents.";
      };
    };
  };

  # ─── Agent Option Type ─────────────────────────────────────────────
  # Submodule for registering an AI coding agent that consumes MCP servers.
  #
  # Example:
  #   options.agents = mkOption {
  #     type = types.attrsOf (types.submodule mcpHelpers.agentOpts);
  #   };
  agentOpts = { ... }: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Whether this agent is active.";
      };

      configPath = mkOption {
        type = types.str;
        description = "Relative path under home dir for MCP config file.";
        example = ".cursor/mcp.json";
      };

      configFormat = mkOption {
        type = types.enum [ "mcpjson" "claude" ];
        default = "mcpjson";
        description = ''
          Config format:
          - mcpjson: standard { "mcpServers": { ... } } JSON (Cursor, VS Code, OpenCode)
          - claude: skip deployment — module manages its own config via deep merge
        '';
      };

      extraServers = mkOption {
        type = types.attrs;
        default = {};
        description = "Agent-specific MCP servers merged with shared servers.";
      };
    };
  };

  # ─── Wrapper Script Generator ──────────────────────────────────────
  # Generates a shell wrapper for an MCP server needing env vars or
  # file-based credential resolution. Returns null if neither env nor
  # envFiles are configured (direct binary reference used instead).
  #
  # Requires pkgs for writeShellScript (passed as first arg, curried).
  #
  # Example:
  #   wrapper = mcpHelpers.mkMcpWrapper pkgs "github" serverCfg;
  mkMcpWrapper = pkgs: name: server: let
    cmd = _mkCommandPath server;

    envFileExports = concatStringsSep "\n" (mapAttrsToList (var: path: ''
      if [ -f ${escapeShellArg path} ]; then
        export ${var}="$(cat ${escapeShellArg path})"
      fi
    '') server.envFiles);

    staticExports = concatStringsSep "\n" (mapAttrsToList (var: val: ''
      export ${var}=${escapeShellArg val}
    '') server.env);

    needsWrapper = server.envFiles != {} || server.env != {};
  in
    if needsWrapper then
      pkgs.writeShellScript "mcp-${name}" ''
        ${envFileExports}
        ${staticExports}
        exec ${escapeShellArg cmd} ${concatStringsSep " " (map escapeShellArg server.args)}
      ''
    else null;

  # ─── Resolve Servers ───────────────────────────────────────────────
  # Transforms server option definitions into resolved MCP entry format.
  # Only includes enabled servers. Generates wrappers as needed.
  #
  # Returns: { name = { type = "stdio"; command = "..."; args = [...]; }; }
  #
  # Example:
  #   resolved = mcpHelpers.mkResolvedServers pkgs cfg.mcp.servers;
  mkResolvedServers = pkgs: servers: let
    enabled = filterAttrs (_: s: s.enable) servers;
  in mapAttrs (name: server: let
    wrapper = mkMcpWrapper pkgs name server;
    directCmd = _mkCommandPath server;
  in {
    type = "stdio";
    command = if wrapper != null then "${wrapper}" else directCmd;
    args = if wrapper != null then [] else server.args;
  }) enabled;

  # ─── Per-Agent Filtering ───────────────────────────────────────────
  # Filters resolved servers for a specific agent. Servers with empty
  # agents list are included for all agents. Uses the original serverDefs
  # to check each server's agents list (not the resolved values).
  #
  # Example:
  #   cursorServers = mcpHelpers.mkFilterForAgent cfg.mcp.servers resolved "cursor";
  mkFilterForAgent = serverDefs: resolvedServers: agentName:
    filterAttrs (sname: _:
      let srv = serverDefs.${sname}; in
      srv.agents == [] || elem agentName srv.agents
    ) resolvedServers;

  # ─── MCP JSON Config ───────────────────────────────────────────────
  # Generates a standard MCP JSON config string for an agent.
  #
  # Example:
  #   json = mcpHelpers.mkMcpJson {
  #     serverDefs = cfg.mcp.servers;
  #     resolvedServers = resolved;
  #     agentName = "cursor";
  #     extraServers = agent.extraServers;
  #   };
  mkMcpJson = { serverDefs, resolvedServers, agentName, extraServers ? {} }:
    let filtered = mkFilterForAgent serverDefs resolvedServers agentName;
    in builtins.toJSON {
      mcpServers = filtered // extraServers;
    };

  # ─── Agent Config Deployment ───────────────────────────────────────
  # Generates home.file entries for all mcpjson-format agents.
  # Returns an attrset suitable for merging into home.file.
  #
  # Example:
  #   home.file = mkMerge [
  #     (mcpHelpers.mkMcpAgentConfigs {
  #       serverDefs = cfg.mcp.servers;
  #       resolvedServers = resolved;
  #       agents = cfg.agents;
  #     })
  #   ];
  mkMcpAgentConfigs = { serverDefs, resolvedServers, agents }:
    mkMerge (mapAttrsToList (agentName: agent:
      optionalAttrs (agent.enable && agent.configFormat == "mcpjson") {
        "${agent.configPath}".text = mkMcpJson {
          inherit serverDefs resolvedServers agentName;
          extraServers = agent.extraServers;
        };
      }
    ) agents);
}
