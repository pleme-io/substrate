# Home-manager MCP server deployment helpers
#
# Reusable patterns for AI coding agent MCP server management.
# Provides option types, wrapper script generation, server resolution,
# per-agent/scope filtering, and context wrapper generation.
#
# Used by: blackmatter-anvil, blackmatter-claude (via generatedServers)
#
# Agent Categories:
#   1. mcpjson  — anvil writes config file (Cursor, VS Code, Gemini, Rovo Dev)
#   2. claude   — agent reads anvil.generatedServers, deep-merges own config (Claude Code)
#   3. opencode — agent reads anvil.generatedServers in own module (OpenCode)
#   4. context  — anvil.contexts generates wrapper binaries (claude-pleme, claude-akeyless)
#
# Usage (in flake.nix):
#   homeManagerModules.default = import ./module {
#     mcpHelpers = import "${substrate}/lib/hm-mcp-helpers.nix" { lib = nixpkgs.lib; };
#   };
#
# Usage (in module/default.nix):
#   { mcpHelpers }: { lib, config, pkgs, ... }:
#   let inherit (mcpHelpers) mcpServerOpts agentOpts mkMcpWrapper mkResolvedServers; in { ... }
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

      scopes = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Restrict to these profile scopes. Empty list = all scopes.";
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
        type = types.enum [ "mcpjson" "claude" "opencode" ];
        default = "mcpjson";
        description = ''
          Config format:
          - mcpjson: standard { "mcpServers": { ... } } JSON (Cursor, VS Code, Gemini)
          - claude: skip deployment — module manages its own config via deep merge
          - opencode: skip deployment — module reads anvil.generatedServers directly (like claude)
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

  # ─── Per-Scope Filtering ──────────────────────────────────────
  # Filters resolved servers for a specific scope/profile. Servers with
  # empty scopes list are included in all scopes.
  #
  # Example:
  #   plemeServers = mcpHelpers.mkFilterForScope cfg.mcp.servers resolved "pleme";
  mkFilterForScope = serverDefs: resolvedServers: scopeName:
    filterAttrs (sname: _:
      let srv = serverDefs.${sname}; in
      srv.scopes == [] || elem scopeName srv.scopes
    ) resolvedServers;

  # ─── Combined Agent + Scope Filtering ────────────────────────────
  # Applies both agent and scope filters (intersection). Use this when
  # you need servers matching a specific agent AND scope simultaneously.
  #
  # Example:
  #   servers = mcpHelpers.mkFilterForAgentAndScope cfg.mcp.servers resolved "claude" "pleme";
  mkFilterForAgentAndScope = serverDefs: resolvedServers: agentName: scopeName:
    filterAttrs (sname: _:
      let srv = serverDefs.${sname}; in
      (srv.agents == [] || elem agentName srv.agents) &&
      (srv.scopes == [] || elem scopeName srv.scopes)
    ) resolvedServers;

  # ─── Context Wrapper Generator ──────────────────────────────────
  # Generates a shell wrapper binary for an org context + agent pair.
  # The wrapper sets WORKSPACE, filters MCP by scope, handles auth,
  # and execs the target binary with settings + MCP config flags.
  #
  # Used by blackmatter-anvil's contexts option to generate binaries
  # like claude-pleme, claude-akeyless.
  #
  # Example:
  #   pkg = mcpHelpers.mkContextWrapper pkgs {
  #     ctxName = "pleme"; scope = "pleme"; ctxEnv = {};
  #     agentName = "claude"; agent = { targetBin = "claude"; settings = { ... }; ... };
  #     serverDefs = cfg.mcp.servers; resolvedServers = resolved;
  #   };
  mkContextWrapper = pkgs: {
    ctxName, scope, ctxEnv ? {},
    agentName, agent,
    serverDefs, resolvedServers,
  }: let
    scopedServers = mkFilterForAgentAndScope serverDefs resolvedServers agentName scope;

    settingsJson = pkgs.writeText "${agentName}-${ctxName}-settings.json"
      (builtins.toJSON agent.settings);

    mcpJson = pkgs.writeText "${agentName}-${ctxName}-mcp.json"
      (builtins.toJSON { mcpServers = scopedServers; });

    authExports = concatStringsSep "\n" (
      (optional (agent.auth.apiKeyFile or null != null) ''
        key_file=${escapeShellArg agent.auth.apiKeyFile}
        if [ -f "$key_file" ]; then
          export ANTHROPIC_API_KEY="$(cat "$key_file")"
        fi
      '')
      ++ (mapAttrsToList (k: v: ''export ${k}=${escapeShellArg v}'') (agent.auth.env or {}))
    );

    envExports = concatStringsSep "\n"
      (mapAttrsToList (k: v: ''export ${k}=${escapeShellArg v}'') ctxEnv);

    unsetExports = concatStringsSep "\n"
      (map (v: "unset ${v}") (agent.unsetEnv or []));

    configDirSetup = optionalString ((agent.configDir or null) != null) ''
      export CLAUDE_CONFIG_DIR=${escapeShellArg agent.configDir}
      mkdir -p "$CLAUDE_CONFIG_DIR"
    '';

    extraArgsStr = concatStringsSep " " (map escapeShellArg (agent.extraArgs or []));
  in
    pkgs.writeShellScriptBin "${agentName}-${ctxName}" ''
      export WORKSPACE=${escapeShellArg ctxName}
      ${envExports}
      ${configDirSetup}
      ${authExports}
      ${unsetExports}
      exec ${agent.targetBin} \
        --settings ${settingsJson} \
        --mcp-config ${mcpJson} \
        ${extraArgsStr} \
        "$@"
    '';

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

  # ─── MCP Kind Registry ─────────────────────────────────────────────
  # kind → { serverPrefix?; mkServer = args: <partial server opts>; credEnvs?; }
  #   mkServer returns the kind's command/args/package/env/description. The
  #   fleet wires enable/scopes/envFiles. credEnvs lists the env vars that
  #   are file-backed credentials (dummy-managed by default; a fleet entry's
  #   `creds` overrides). Org modules extend via `(mcpKinds pkgs) // {...}`.
  # Generic kinds only — org-specific kinds (e.g. akeyless-jit) live in the
  # org module per the "generic in substrate, org kinds extend" decision.
  mcpKinds = pkgs: let
    grafanaReadOnly = [
      "-disable-write" "-enabled-tools"
      "search,datasource,prometheus,loki,incident,alerting,oncall,sift,asserts,pyroscope,dashboard,annotations,navigation"
    ];
  in {
    grafana = {
      mkServer = { url }: {
        package = pkgs.mcp-grafana; command = "mcp-grafana";
        args = grafanaReadOnly; env.GRAFANA_URL = url;
        description = "Grafana (read-only) — ${url}";
      };
      credEnvs = [ "GRAFANA_SERVICE_ACCOUNT_TOKEN" ];
    };
    datadog = {
      mkServer = { site ? "datadoghq.com" }: {
        command = "npx"; args = [ "-y" "@winor30/mcp-server-datadog" ];
        env.DATADOG_SITE = site; description = "Datadog — metrics/APM/logs (${site})";
      };
      credEnvs = [ "DATADOG_API_KEY" "DATADOG_APP_KEY" ];
    };
    splunk = {
      # UNVERIFIED package — disabled by default at call sites.
      mkServer = { url }: {
        command = "npx"; args = [ "-y" "@splunk/mcp-server" ];
        env.SPLUNK_URL = url; description = "Splunk logs — ${url}";
      };
      credEnvs = [ "SPLUNK_TOKEN" ];
    };
    kubernetes = {
      serverPrefix = "k8s";
      mkServer = { }: {
        package = pkgs.mcp-k8s-go; command = "mcp-k8s-go";
        description = "Kubernetes (read-only viewer kubeconfig)";
      };
      credEnvs = [ "KUBECONFIG" ];
    };
    argocd = {
      mkServer = { server }: {                       # UNVERIFIED package
        command = "npx"; args = [ "-y" "argocd-mcp" ];
        env.ARGOCD_SERVER = server; description = "ArgoCD — ${server}";
      };
      credEnvs = [ "ARGOCD_AUTH_TOKEN" ];
    };
    gcp = {
      mkServer = { }: { command = "npx"; args = [ "-y" "gcp-mcp" ]; description = "GCP (read-only SA)"; };
      credEnvs = [ "GOOGLE_APPLICATION_CREDENTIALS" ];
    };
    azure = {
      mkServer = { }: { command = "npx"; args = [ "-y" "@azure/mcp" ]; description = "Azure (read-only)"; };
      credEnvs = [ "AZURE_TOKEN" ];
    };
    sentry = {
      mkServer = { }: { command = "npx"; args = [ "-y" "@sentry/mcp-server" ]; description = "Sentry error tracking"; };
      credEnvs = [ "SENTRY_AUTH_TOKEN" ];
    };
  };

  # ─── Credential Strategy ───────────────────────────────────────────
  # mkCred { scope; homeDir; } { env; secret; strategy ? "dummy"; externalPath ? null; label ? ""; }
  #   → { envFile = {ENV=path;}; homeFile = {...}; sopsSecret = {...}; }
  # strategy:
  #   external — value lives at externalPath, managed elsewhere (no side-effect)
  #   dummy    — write a non-secret placeholder via home.file ("ready to turn on")
  #   sops     — declare sops.secrets (KEY MUST pre-exist in secrets.yaml)
  # Canonical fleet path: ~/.config/mcp-fleet/<scope>/<secret>.
  mkCred = { scope, homeDir }: { env, secret, strategy ? "dummy", externalPath ? null, label ? "" }:
    let
      rel = ".config/mcp-fleet/${scope}/${secret}";
      path = if strategy == "external" then externalPath else "${homeDir}/${rel}";
    in {
      envFile = { ${env} = path; };
      homeFile = optionalAttrs (strategy == "dummy") {
        ${rel}.text = "REPLACE-ME — dummy ${secret}${optionalString (label != "") " for ${label}"}; supply via SOPS and set strategy=\"sops\"\n";
      };
      sopsSecret = optionalAttrs (strategy == "sops") {
        "mcp-fleet/${scope}/${secret}" = { inherit path; mode = "0600"; };
      };
    };

  # ─── MCP Fleet ─────────────────────────────────────────────────────
  # Expand a catalog of same/mixed-kind endpoints into anvil servers plus
  # their credential side-effects, deduplicating the per-org generators.
  #
  # mkMcpFleet pkgs { scope; homeDir; entries; kinds ? mcpKinds pkgs; }
  #   entries :: [ { kind; name; args ? {}; enable ? false; scopes ? [scope];
  #                  creds ? null; } ]
  #     creds == null            → auto dummy creds from the kind's credEnvs
  #     creds == [ {env; strategy?; secret?; externalPath?;} ] → explicit
  #   → { servers = {...}; homeFiles = {...}; sopsSecrets = {...}; }
  #   namePrefix : optional infix to keep server names unique across fleets
  #     sharing the flat registry (e.g. "pleme" → grafana-pleme-lilitu).
  mkMcpFleet = pkgs: { scope, homeDir, entries, kinds ? mcpKinds pkgs, namePrefix ? null }:
    let
      mkc = mkCred { inherit scope homeDir; };
      credSlug = e: lib.toLower (concatStringsSep "-" (drop 1 (splitString "_" e)));
      resolveEntry = e: let
        kindDef = kinds.${e.kind};
        prefix = kindDef.serverPrefix or e.kind;
        serverName =
          if namePrefix == null then "${prefix}-${e.name}"
          else "${prefix}-${namePrefix}-${e.name}";
        envs = kindDef.credEnvs or [];
        autoCreds =
          if length envs <= 1
          then map (env: { inherit env; secret = "${e.kind}-${e.name}.token"; strategy = "dummy"; }) envs
          else map (env: { inherit env; secret = "${e.kind}-${e.name}.${credSlug env}"; strategy = "dummy"; }) envs;
        credSpecs = if (e.creds or null) != null then e.creds else autoCreds;
        creds = map (c: mkc {
          inherit (c) env;
          secret = c.secret or "${e.kind}-${e.name}.token";
          strategy = c.strategy or "dummy";
          externalPath = c.externalPath or null;
          label = serverName;
        }) credSpecs;
        partial = kindDef.mkServer (e.args or {});
      in {
        server = nameValuePair serverName (partial // {
          enable = e.enable or false;
          scopes = e.scopes or [ scope ];
          envFiles = (partial.envFiles or {}) // foldl' (a: c: a // c.envFile) {} creds;
        });
        homeFiles = foldl' (a: c: a // c.homeFile) {} creds;
        sopsSecrets = foldl' (a: c: a // c.sopsSecret) {} creds;
      };
      resolved = map resolveEntry entries;
    in {
      servers = listToAttrs (map (r: r.server) resolved);
      homeFiles = foldl' (a: r: a // r.homeFiles) {} resolved;
      sopsSecrets = foldl' (a: r: a // r.sopsSecrets) {} resolved;
    };
}
