# Home-Manager Module Tests
#
# Pure Nix evaluation tests for all hm/ helpers.
# No builds, no pkgs, instant feedback.
#
# Usage:
#   nix eval --impure --raw --file lib/hm/tests.nix --apply 'r: r.summary'
#   nix eval --impure --raw --file lib/hm/tests.nix --apply 'r: builtins.toJSON r.allPassed'
let
  lib = (import <nixpkgs> { system = "x86_64-linux"; }).lib;
  testHelpers = import ../util/test-helpers.nix { inherit lib; };
  serviceHelpers = import ./service-helpers.nix { inherit lib; };
  typedConfig = import ./typed-config-helpers.nix { inherit lib; };
  secretHelpers = import ./secret-helpers.nix { inherit lib; };
  workspaceHelpers = import ./workspace-helpers.nix { inherit lib; };
  claudeMdHelpers = import ./claude-md-helpers.nix { inherit lib; };
  fragmentHelpers = import ./flake-fragment-helpers.nix { inherit lib; };
  nixosHelpers = import ./nixos-service-helpers.nix { inherit lib; };
  mcpHelpers = import ./mcp-helpers.nix { inherit lib; };

  inherit (testHelpers) mkTest runTests;
in runTests [

  # ════════════════════════════════════════════════════════════════════
  # service-helpers.nix — mkMcpServerEntry
  # ════════════════════════════════════════════════════════════════════

  (mkTest "mcp-entry-minimal"
    (let e = serviceHelpers.mkMcpServerEntry { command = "/bin/zoekt-mcp"; };
    in e.type == "stdio" && e.command == "/bin/zoekt-mcp" && !(e ? args) && !(e ? env))
    "minimal MCP entry should only have type and command, omit empty args/env")

  (mkTest "mcp-entry-with-args"
    (let e = serviceHelpers.mkMcpServerEntry { command = "/bin/tool"; args = ["--port" "8080"]; };
    in e.args == ["--port" "8080"])
    "MCP entry with args should include them")

  (mkTest "mcp-entry-with-env"
    (let e = serviceHelpers.mkMcpServerEntry { command = "/bin/tool"; env = { FOO = "bar"; }; };
    in e.env.FOO == "bar")
    "MCP entry with env should include it")

  (mkTest "mcp-entry-empty-args-omitted"
    (let e = serviceHelpers.mkMcpServerEntry { command = "/bin/tool"; args = []; env = {}; };
    in !(e ? args) && !(e ? env))
    "empty args and env should be omitted, preventing silent config bloat")

  # ════════════════════════════════════════════════════════════════════
  # service-helpers.nix — mkAnvilRegistration
  # ════════════════════════════════════════════════════════════════════

  (mkTest "anvil-reg-basic"
    (let r = serviceHelpers.mkAnvilRegistration { name = "zoekt"; command = "zoekt-mcp"; };
    in r.blackmatter.components.anvil.mcp.servers.zoekt.command == "zoekt-mcp"
      && r.blackmatter.components.anvil.mcp.servers.zoekt.enable)
    "basic anvil registration should set command and default enable=true")

  (mkTest "anvil-reg-with-package-null"
    (let r = serviceHelpers.mkAnvilRegistration { name = "t"; command = "cmd"; };
    in !(r.blackmatter.components.anvil.mcp.servers.t ? package))
    "anvil registration with null package should omit package attr")

  (mkTest "anvil-reg-with-scopes"
    (let r = serviceHelpers.mkAnvilRegistration { name = "t"; command = "cmd"; scopes = ["pleme" "akeyless"]; };
    in r.blackmatter.components.anvil.mcp.servers.t.scopes == ["pleme" "akeyless"])
    "anvil registration should pass through scopes")

  (mkTest "anvil-reg-disabled"
    (let r = serviceHelpers.mkAnvilRegistration { name = "t"; command = "cmd"; enable = false; };
    in !r.blackmatter.components.anvil.mcp.servers.t.enable)
    "anvil registration with enable=false should propagate")

  (mkTest "anvil-reg-env-files"
    (let r = serviceHelpers.mkAnvilRegistration {
      name = "gh"; command = "mcp-server-github";
      envFiles = { GITHUB_TOKEN = "/run/secrets/gh-token"; };
    };
    in r.blackmatter.components.anvil.mcp.servers.gh.envFiles.GITHUB_TOKEN == "/run/secrets/gh-token")
    "anvil registration should preserve envFiles for runtime credential resolution")

  # ════════════════════════════════════════════════════════════════════
  # service-helpers.nix — mkLaunchdService
  # ════════════════════════════════════════════════════════════════════

  (let svc = serviceHelpers.mkLaunchdService {
    name = "zoekt-webserver";
    label = "io.pleme.zoekt-webserver";
    command = "/nix/store/xxx/bin/zoekt-webserver";
    args = ["-index" "/idx" "-listen" ":6070"];
    logDir = "/Users/me/Library/Logs";
  };
  in mkTest "launchd-basic"
    (svc.launchd.agents.zoekt-webserver.enable
      && svc.launchd.agents.zoekt-webserver.config.Label == "io.pleme.zoekt-webserver"
      && svc.launchd.agents.zoekt-webserver.config.RunAtLoad
      && svc.launchd.agents.zoekt-webserver.config.KeepAlive
      && svc.launchd.agents.zoekt-webserver.config.ProcessType == "Adaptive"
      && svc.launchd.agents.zoekt-webserver.config.StandardOutPath == "/Users/me/Library/Logs/zoekt-webserver.log"
      && svc.launchd.agents.zoekt-webserver.config.StandardErrorPath == "/Users/me/Library/Logs/zoekt-webserver.err"
      && builtins.length svc.launchd.agents.zoekt-webserver.config.ProgramArguments == 5)
    "launchd service should include label, keepalive, log paths, and all program arguments")

  (let svc = serviceHelpers.mkLaunchdService {
    name = "test"; label = "l"; command = "/bin/t"; logDir = "/l";
    env = { FOO = "bar"; };
  };
  in mkTest "launchd-with-env"
    (svc.launchd.agents.test.config.EnvironmentVariables.FOO == "bar")
    "launchd service with env should set EnvironmentVariables")

  (let svc = serviceHelpers.mkLaunchdService {
    name = "test"; label = "l"; command = "/bin/t"; logDir = "/l";
  };
  in mkTest "launchd-no-env"
    (!(svc.launchd.agents.test.config ? EnvironmentVariables))
    "launchd service without env should omit EnvironmentVariables")

  # ════════════════════════════════════════════════════════════════════
  # service-helpers.nix — mkLaunchdPeriodicTask
  # ════════════════════════════════════════════════════════════════════

  (let svc = serviceHelpers.mkLaunchdPeriodicTask {
    name = "index-repos";
    label = "io.pleme.index-repos";
    command = "/bin/indexer";
    interval = 3600;
    logDir = "/tmp";
  };
  in mkTest "launchd-periodic-basic"
    (svc.launchd.agents.index-repos.config.StartInterval == 3600
      && svc.launchd.agents.index-repos.config.ProcessType == "Background"
      && svc.launchd.agents.index-repos.config.LowPriorityIO
      && svc.launchd.agents.index-repos.config.Nice == 10)
    "periodic task should set interval, Background process type, and IO priority")

  # ════════════════════════════════════════════════════════════════════
  # service-helpers.nix — mkSystemdService
  # ════════════════════════════════════════════════════════════════════

  (let svc = serviceHelpers.mkSystemdService {
    name = "zoekt-webserver";
    description = "Zoekt Web UI";
    command = "/bin/zoekt-webserver";
    args = ["-listen" ":6070"];
  };
  in mkTest "systemd-basic"
    (svc.systemd.user.services.zoekt-webserver.Unit.Description == "Zoekt Web UI"
      && svc.systemd.user.services.zoekt-webserver.Service.Type == "simple"
      && svc.systemd.user.services.zoekt-webserver.Service.Restart == "on-failure"
      && svc.systemd.user.services.zoekt-webserver.Service.RestartSec == 5
      && svc.systemd.user.services.zoekt-webserver.Install.WantedBy == ["default.target"])
    "systemd service should have description, type, restart policy, and wantedBy")

  (let svc = serviceHelpers.mkSystemdService {
    name = "t"; description = "d"; command = "/bin/t";
    env = { PORT = "8080"; };
  };
  in mkTest "systemd-with-env"
    (builtins.length svc.systemd.user.services.t.Service.Environment == 1)
    "systemd service with env should produce Environment list entries")

  (let svc = serviceHelpers.mkSystemdService {
    name = "t"; description = "d"; command = "/bin/t";
  };
  in mkTest "systemd-no-env"
    (!(svc.systemd.user.services.t.Service ? Environment))
    "systemd service without env should omit Environment attr")

  (let svc = serviceHelpers.mkSystemdService {
    name = "t"; description = "d"; command = "/bin/t";
    preStart = "/bin/setup";
  };
  in mkTest "systemd-prestart"
    (svc.systemd.user.services.t.Service.ExecStartPre == "/bin/setup")
    "systemd service with preStart should set ExecStartPre")

  # ════════════════════════════════════════════════════════════════════
  # service-helpers.nix — mkSystemdPeriodicTask
  # ════════════════════════════════════════════════════════════════════

  (let svc = serviceHelpers.mkSystemdPeriodicTask {
    name = "reindex";
    description = "Periodic reindex";
    command = "/bin/indexer";
    interval = 3600;
  };
  in mkTest "systemd-periodic-basic"
    (svc.systemd.user.services.reindex.Service.Type == "oneshot"
      && svc.systemd.user.timers.reindex.Timer.OnUnitActiveSec == "3600s"
      && svc.systemd.user.timers.reindex.Timer.OnBootSec == "30s"
      && svc.systemd.user.timers.reindex.Install.WantedBy == ["timers.target"])
    "periodic task should create oneshot service and timer with correct interval")

  (let svc = serviceHelpers.mkSystemdPeriodicTask {
    name = "t"; description = "d"; command = "/bin/t";
    interval = 60; after = ["network.target"];
  };
  in mkTest "systemd-periodic-after"
    (svc.systemd.user.services.t.Unit.After == ["network.target"])
    "periodic task should propagate after dependencies")

  # ════════════════════════════════════════════════════════════════════
  # typed-config-helpers.nix — optAttr
  # ════════════════════════════════════════════════════════════════════

  (mkTest "opt-attr-non-null"
    (typedConfig.optAttr "model" "opus" == { model = "opus"; })
    "optAttr with non-null value should produce singleton attrset")

  (mkTest "opt-attr-null"
    (typedConfig.optAttr "model" null == {})
    "optAttr with null value should produce empty set, preventing null keys in JSON")

  # ════════════════════════════════════════════════════════════════════
  # typed-config-helpers.nix — optList
  # ════════════════════════════════════════════════════════════════════

  (mkTest "opt-list-non-empty"
    (typedConfig.optList "tags" ["a" "b"] == { tags = ["a" "b"]; })
    "optList with non-empty list should produce attrset")

  (mkTest "opt-list-empty"
    (typedConfig.optList "tags" [] == {})
    "optList with empty list should produce empty set, preventing empty arrays in config")

  # ════════════════════════════════════════════════════════════════════
  # typed-config-helpers.nix — optNested
  # ════════════════════════════════════════════════════════════════════

  (mkTest "opt-nested-non-empty"
    (typedConfig.optNested "env" { FOO = "bar"; } == { env = { FOO = "bar"; }; })
    "optNested with non-empty attrset should produce attrset")

  (mkTest "opt-nested-empty"
    (typedConfig.optNested "env" {} == {})
    "optNested with empty attrset should produce empty set")

  # ════════════════════════════════════════════════════════════════════
  # typed-config-helpers.nix — mkJsonConfig
  # ════════════════════════════════════════════════════════════════════

  (mkTest "json-config-basic"
    (let c = typedConfig.mkJsonConfig { path = ".config/app.json"; config = { theme = "nord"; }; };
    in c ? ".config/app.json" && c.".config/app.json" ? text)
    "mkJsonConfig should create a home.file entry with text attribute")

  (mkTest "json-config-merged"
    (let
      c = typedConfig.mkJsonConfig {
        path = "cfg.json";
        config = { a = 1; };
        extraConfig = { b = 2; };
      };
      parsed = builtins.fromJSON c."cfg.json".text;
    in parsed.a == 1 && parsed.b == 2)
    "mkJsonConfig should merge config with extraConfig for escape-hatch extensibility")

  (mkTest "json-config-extra-overrides"
    (let
      c = typedConfig.mkJsonConfig {
        path = "cfg.json";
        config = { a = 1; };
        extraConfig = { a = 99; };
      };
      parsed = builtins.fromJSON c."cfg.json".text;
    in parsed.a == 99)
    "extraConfig should override config keys (right-hand side of // wins)")

  # ════════════════════════════════════════════════════════════════════
  # typed-config-helpers.nix — mkVersionedConfig
  # ════════════════════════════════════════════════════════════════════

  (mkTest "versioned-config-basic"
    (let c = typedConfig.mkVersionedConfig { version = 2; config = { theme = "dark"; }; };
    in c.version == 2 && c.theme == "dark")
    "mkVersionedConfig should merge version with config")

  (mkTest "versioned-config-default"
    (let c = typedConfig.mkVersionedConfig { config = { x = 1; }; };
    in c.version == 1)
    "mkVersionedConfig should default to version 1")

  (mkTest "versioned-config-override"
    (let c = typedConfig.mkVersionedConfig { version = 1; config = { version = 99; }; };
    in c.version == 99)
    "config with version key should override the provided version (// semantics)")

  # ════════════════════════════════════════════════════════════════════
  # typed-config-helpers.nix — mkTypedJsonFile
  # ════════════════════════════════════════════════════════════════════

  (mkTest "typed-json-file-basic"
    (let
      c = typedConfig.mkTypedJsonFile {
        path = "settings.json";
        typedSettings = { theme = "dark"; };
      };
      parsed = builtins.fromJSON c."settings.json".text;
    in parsed.theme == "dark")
    "mkTypedJsonFile should serialize typedSettings to JSON")

  (mkTest "typed-json-file-extra"
    (let
      c = typedConfig.mkTypedJsonFile {
        path = "s.json";
        typedSettings = { a = 1; };
        extraSettings = { b = 2; };
      };
      parsed = builtins.fromJSON c."s.json".text;
    in parsed.a == 1 && parsed.b == 2)
    "mkTypedJsonFile should merge typedSettings with extraSettings")

  # ════════════════════════════════════════════════════════════════════
  # secret-helpers.nix — mkPlaceholders
  # ════════════════════════════════════════════════════════════════════

  (mkTest "placeholder-format"
    (let p = secretHelpers.mkPlaceholders "BMSECRET" { db-password = {}; };
    in builtins.match "<BMSECRET:[a-f0-9]+:PLACEHOLDER>" p.db-password != null)
    "placeholder should match <PREFIX:sha256:PLACEHOLDER> format")

  (mkTest "placeholder-unique-per-name"
    (let p = secretHelpers.mkPlaceholders "X" { a = {}; b = {}; };
    in p.a != p.b)
    "different secret names should produce different placeholders to prevent collisions")

  (mkTest "placeholder-deterministic"
    (let
      p1 = secretHelpers.mkPlaceholders "X" { a = {}; };
      p2 = secretHelpers.mkPlaceholders "X" { a = {}; };
    in p1.a == p2.a)
    "same name should produce same placeholder (deterministic hashing)")

  # ════════════════════════════════════════════════════════════════════
  # secret-helpers.nix — effectiveContent
  # ════════════════════════════════════════════════════════════════════

  (mkTest "effective-content-inline"
    (secretHelpers.effectiveContent { file = null; content = "hello"; } == "hello")
    "effectiveContent should return content when file is null")

  # ════════════════════════════════════════════════════════════════════
  # secret-helpers.nix — substitutePlaceholders
  # ════════════════════════════════════════════════════════════════════

  (let
    secrets = { db = {}; };
    unified = { db = "<UNI:abc:PLACEHOLDER>"; };
    backend = { db = "%%SOPS_db%%"; };
    result = secretHelpers.substitutePlaceholders {
      content = "pass=<UNI:abc:PLACEHOLDER>";
      inherit secrets;
      unifiedPlaceholders = unified;
      backendPlaceholders = backend;
    };
  in mkTest "substitute-placeholders"
    (result == "pass=%%SOPS_db%%")
    "substitutePlaceholders should replace unified placeholders with backend-specific ones")

  (let
    secrets = { a = {}; b = {}; };
    unified = { a = "<U:a>"; b = "<U:b>"; };
    backend = { a = "%%A%%"; b = "%%B%%"; };
    result = secretHelpers.substitutePlaceholders {
      content = "<U:a> and <U:b>";
      inherit secrets;
      unifiedPlaceholders = unified;
      backendPlaceholders = backend;
    };
  in mkTest "substitute-multiple-placeholders"
    (result == "%%A%% and %%B%%")
    "substitutePlaceholders should handle multiple secrets in one content string")

  # ════════════════════════════════════════════════════════════════════
  # workspace-helpers.nix — mkGhosttyConfig
  # ════════════════════════════════════════════════════════════════════

  (let cfg = workspaceHelpers.mkGhosttyConfig {
    baseConfigPath = "~/.config/ghostty/config";
    workspace = {
      displayName = "pleme";
      theme = { accent = "#88C0D0"; cursorColor = null; selectionBackground = null; };
      ghostty = { extraConfig = ""; };
    };
  };
  in mkTest "ghostty-config-basic"
    (builtins.match ".*config-file = ~/.config/ghostty/config.*" cfg != null
      && builtins.match ".*title = pleme.*" cfg != null
      && builtins.match ".*cursor-color = #88C0D0.*" cfg != null)
    "ghostty config should include config-file, title, and cursor-color defaulting to accent")

  (let cfg = workspaceHelpers.mkGhosttyConfig {
    baseConfigPath = "/x";
    workspace = {
      displayName = "test";
      theme = { accent = "#FF0000"; cursorColor = "#00FF00"; selectionBackground = "#0000FF"; };
      ghostty = { extraConfig = "font-size = 14"; };
    };
  };
  in mkTest "ghostty-config-overrides"
    (builtins.match ".*cursor-color = #00FF00.*" cfg != null
      && builtins.match ".*selection-background = #0000FF.*" cfg != null
      && builtins.match ".*font-size = 14.*" cfg != null)
    "ghostty config should use cursorColor override and include selection-background and extra config")

  (let cfg = workspaceHelpers.mkGhosttyConfig {
    baseConfigPath = "/x";
    workspace = {
      displayName = "t";
      theme = { accent = "#FFF"; cursorColor = null; selectionBackground = null; };
      ghostty = { extraConfig = ""; };
    };
  };
  in mkTest "ghostty-config-no-selection"
    (builtins.match ".*selection-background.*" cfg == null)
    "ghostty config should omit selection-background when null")

  # ════════════════════════════════════════════════════════════════════
  # claude-md-helpers.nix — mkStaticDoc / mkInlineDoc
  # ════════════════════════════════════════════════════════════════════

  (let d = claudeMdHelpers.mkStaticDoc { id = "test-doc"; source = ./tests.nix; };
  in mkTest "static-doc-fields"
    (d.id == "test-doc" && d.priority == 50 && d.source != null && d.text == null && d.dynamicSections == {})
    "mkStaticDoc should set correct fields with default priority 50")

  (let d = claudeMdHelpers.mkInlineDoc { id = "inline"; text = "hello world"; priority = 100; };
  in mkTest "inline-doc-fields"
    (d.id == "inline" && d.priority == 100 && d.text == "hello world" && d.source == null)
    "mkInlineDoc should set text and custom priority")

  # ════════════════════════════════════════════════════════════════════
  # flake-fragment-helpers.nix — mkTendStatusApp
  # ════════════════════════════════════════════════════════════════════

  (let app = fragmentHelpers.mkTendStatusApp "pleme-io";
  in mkTest "tend-status-app-workspace"
    (builtins.match ".*--workspace pleme-io.*" app.script != null
      && builtins.match ".*tend status.*" app.script != null)
    "mkTendStatusApp with workspace should include --workspace flag")

  (let app = fragmentHelpers.mkTendStatusApp null;
  in mkTest "tend-status-app-null"
    (builtins.match ".*--workspace.*" app.script == null
      && builtins.match ".*tend status.*" app.script != null)
    "mkTendStatusApp with null should omit --workspace flag")

  # ════════════════════════════════════════════════════════════════════
  # flake-fragment-helpers.nix — mkFragment
  # ════════════════════════════════════════════════════════════════════

  (let f = fragmentHelpers.mkFragment { id = "my-frag"; };
  in mkTest "mk-fragment-defaults"
    (f.id == "my-frag"
      && f.priority == 50
      && f.apps == {}
      && f.flows == {}
      && f.systems == []
      && f.inputs ? nixpkgs
      && f.inputs ? flake-utils)
    "mkFragment should set defaults including nixpkgs+flake-utils inputs")

  (let f = fragmentHelpers.mkFragment {
    id = "f"; priority = 100;
    apps = { test = { script = "echo hi"; description = null; }; };
  };
  in mkTest "mk-fragment-custom"
    (f.priority == 100 && f.apps ? test)
    "mkFragment should accept custom priority and apps")

  # ════════════════════════════════════════════════════════════════════
  # flake-fragment-helpers.nix — mkOrgFragment
  # ════════════════════════════════════════════════════════════════════

  (let f = fragmentHelpers.mkOrgFragment { org = "pleme-io"; };
  in mkTest "mk-org-fragment-defaults"
    (f.id == "pleme-io"
      && f.priority == 50
      && f.apps ? tend-status
      && builtins.match ".*pleme-io.*" f.apps.tend-status.script != null)
    "mkOrgFragment should use org as id and add tend-status app")

  (let f = fragmentHelpers.mkOrgFragment {
    org = "myorg"; id = "custom-id";
    extraApps = { deploy = { script = "echo deploy"; description = null; }; };
  };
  in mkTest "mk-org-fragment-extra-apps"
    (f.id == "custom-id" && f.apps ? deploy && f.apps ? tend-status)
    "mkOrgFragment should merge extraApps with tend-status")

  # ════════════════════════════════════════════════════════════════════
  # nixos-service-helpers.nix — mkNixOSService
  # ════════════════════════════════════════════════════════════════════

  (let svc = nixosHelpers.mkNixOSService {
    name = "k3s";
    description = "Lightweight Kubernetes";
    command = "/bin/k3s";
    args = ["server"];
    type = "notify";
    delegate = true;
    killMode = "process";
  };
  in mkTest "nixos-service-basic"
    (svc.systemd.services.k3s.description == "Lightweight Kubernetes"
      && svc.systemd.services.k3s.serviceConfig.Type == "notify"
      && svc.systemd.services.k3s.serviceConfig.KillMode == "process"
      && svc.systemd.services.k3s.serviceConfig.Delegate == "yes"
      && svc.systemd.services.k3s.serviceConfig.Restart == "always"
      && svc.systemd.services.k3s.wantedBy == ["multi-user.target"])
    "nixos service should set Type, KillMode, Delegate, and wantedBy correctly")

  (let svc = nixosHelpers.mkNixOSService {
    name = "t"; description = "d"; command = "/bin/t";
  };
  in mkTest "nixos-service-no-delegate"
    (!(svc.systemd.services.t.serviceConfig ? Delegate))
    "nixos service without delegate should omit Delegate attr")

  (let svc = nixosHelpers.mkNixOSService {
    name = "t"; description = "d"; command = "/bin/t";
    limitNOFILE = 65536; limitNPROC = 4096;
  };
  in mkTest "nixos-service-resource-limits"
    (svc.systemd.services.t.serviceConfig.LimitNOFILE == 65536
      && svc.systemd.services.t.serviceConfig.LimitNPROC == 4096
      && !(svc.systemd.services.t.serviceConfig ? LimitCORE))
    "nixos service should set only specified resource limits, omit null ones")

  (let svc = nixosHelpers.mkNixOSService {
    name = "t"; description = "d"; command = "/bin/t";
    environmentFile = "/etc/env";
  };
  in mkTest "nixos-service-envfile"
    (svc.systemd.services.t.serviceConfig.EnvironmentFile == "/etc/env")
    "nixos service with environmentFile should set EnvironmentFile")

  (let svc = nixosHelpers.mkNixOSService {
    name = "t"; description = "d"; command = "/bin/t";
    execStartPre = "/bin/pre"; execStartPost = "/bin/post";
  };
  in mkTest "nixos-service-pre-post"
    (svc.systemd.services.t.serviceConfig.ExecStartPre == "/bin/pre"
      && svc.systemd.services.t.serviceConfig.ExecStartPost == "/bin/post")
    "nixos service should set ExecStartPre and ExecStartPost when provided")

  # ════════════════════════════════════════════════════════════════════
  # nixos-service-helpers.nix — mkFirewallConfig
  # ════════════════════════════════════════════════════════════════════

  (let fw = nixosHelpers.mkFirewallConfig {
    tcpPorts = [6443 10250];
    udpPorts = [8472];
    trustedInterfaces = ["cni0"];
  };
  in mkTest "firewall-full"
    (fw.networking.firewall.allowedTCPPorts == [6443 10250]
      && fw.networking.firewall.allowedUDPPorts == [8472]
      && fw.networking.firewall.trustedInterfaces == ["cni0"])
    "firewall config should set all port and interface lists")

  (let fw = nixosHelpers.mkFirewallConfig {};
  in mkTest "firewall-empty"
    (fw.networking.firewall == {})
    "firewall config with all empty should produce empty firewall attrset")

  (let fw = nixosHelpers.mkFirewallConfig { tcpPorts = [80]; };
  in mkTest "firewall-tcp-only"
    (fw.networking.firewall ? allowedTCPPorts
      && !(fw.networking.firewall ? allowedUDPPorts)
      && !(fw.networking.firewall ? trustedInterfaces))
    "firewall with only tcp should omit udp and interfaces")

  # ════════════════════════════════════════════════════════════════════
  # nixos-service-helpers.nix — mkKernelConfig
  # ════════════════════════════════════════════════════════════════════

  (let kc = nixosHelpers.mkKernelConfig {
    sysctl = { "net.ipv4.ip_forward" = 1; };
  };
  in mkTest "kernel-config-sysctl-only"
    (kc.boot.kernel.sysctl."net.ipv4.ip_forward" == 1)
    "kernel config with only sysctl should set sysctl")

  (let kc = nixosHelpers.mkKernelConfig {};
  in mkTest "kernel-config-empty"
    (!(kc ? boot))
    "kernel config with no modules or sysctl should produce empty set")

  (let kc = nixosHelpers.mkKernelConfig { modules = ["overlay"]; };
  in mkTest "kernel-config-modules-only"
    (kc.boot.kernelModules == ["overlay"])
    "kernel config with only modules should set kernelModules")

  # ════════════════════════════════════════════════════════════════════
  # mcp-helpers.nix — mkFilterForAgent / mkFilterForScope
  # ════════════════════════════════════════════════════════════════════

  (let
    serverDefs = {
      github = { agents = []; scopes = []; };
      zoekt = { agents = ["claude"]; scopes = []; };
      cursor-only = { agents = ["cursor"]; scopes = []; };
    };
    resolved = { github = { type = "stdio"; }; zoekt = { type = "stdio"; }; cursor-only = { type = "stdio"; }; };
    filtered = mcpHelpers.mkFilterForAgent serverDefs resolved "claude";
  in mkTest "filter-for-agent-basic"
    (filtered ? github && filtered ? zoekt && !(filtered ? cursor-only))
    "mkFilterForAgent should include global servers and agent-specific ones, exclude others")

  (let
    serverDefs = {
      s1 = { agents = []; scopes = ["pleme"]; };
      s2 = { agents = []; scopes = ["akeyless"]; };
      s3 = { agents = []; scopes = []; };
    };
    resolved = { s1 = {}; s2 = {}; s3 = {}; };
    filtered = mcpHelpers.mkFilterForScope serverDefs resolved "pleme";
  in mkTest "filter-for-scope-basic"
    (filtered ? s1 && !(filtered ? s2) && filtered ? s3)
    "mkFilterForScope should include matching scope and global servers, exclude non-matching")

  (let
    serverDefs = {
      s1 = { agents = ["claude"]; scopes = ["pleme"]; };
      s2 = { agents = ["cursor"]; scopes = ["pleme"]; };
      s3 = { agents = []; scopes = []; };
    };
    resolved = { s1 = {}; s2 = {}; s3 = {}; };
    filtered = mcpHelpers.mkFilterForAgentAndScope serverDefs resolved "claude" "pleme";
  in mkTest "filter-agent-and-scope"
    (filtered ? s1 && !(filtered ? s2) && filtered ? s3)
    "mkFilterForAgentAndScope should intersect both agent and scope filters")

  (let
    serverDefs = {
      s1 = { agents = []; scopes = []; };
    };
    resolved = { s1 = { type = "stdio"; command = "/bin/test"; }; };
    json = mcpHelpers.mkMcpJson {
      inherit serverDefs;
      resolvedServers = resolved;
      agentName = "cursor";
      extraServers = { extra = { type = "stdio"; command = "/bin/extra"; }; };
    };
    parsed = builtins.fromJSON json;
  in mkTest "mcp-json-with-extra"
    (parsed.mcpServers ? s1 && parsed.mcpServers ? extra)
    "mkMcpJson should merge filtered servers with extraServers")

]
