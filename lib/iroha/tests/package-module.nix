# Tests — iroha.package-module (the keystone: lazy coupling-killer, package
# + extras install, cfg.package override, settings render, user/system
# daemon per-platform dispatch, mcp anvil registration + shim, http user
# unit, platform gates, class tagging, extra fragments, meta, typed throws).
{ lib, iroha }:
let
  inherit (iroha) mkPackageModule;

  fakeDrv = name: {
    type = "derivation";
    inherit name;
  };

  # ── stub pkgs (zero real nixpkgs) ────────────────────────────────────
  stubPkgsLinux = {
    stdenv.hostPlatform = {
      isDarwin = false;
      isLinux = true;
      system = "x86_64-linux";
    };
    formats.yaml = _: {
      type = lib.types.attrsOf lib.types.anything;
      generate = n: v: "gen:" + n;
    };
    tend = "TEND_DRV";
    helper = "HELPER_DRV";
    bash = "BASH_DRV";
  };
  stubPkgsDarwin = stubPkgsLinux // {
    stdenv.hostPlatform = {
      isDarwin = true;
      isLinux = false;
      system = "aarch64-darwin";
    };
  };
  # The coupling-killer fixture: no `tend` attribute AT ALL.
  stubPkgsNoTend = removeAttrs stubPkgsLinux [ "tend" ];

  # ── stub option universes ────────────────────────────────────────────
  hmUniverse =
    { lib, ... }:
    {
      options = {
        home.packages = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = [ ];
        };
        home.file = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        home.sessionVariables = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        home.homeDirectory = lib.mkOption {
          type = lib.types.str;
          default = "/home/u";
        };
        systemd.user.services = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        systemd.user.timers = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        launchd.agents = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        # the anvil landing pad — freeform servers attr, as declared by
        # blackmatter-anvil's mcpServerOpts in the real universe
        blackmatter.components.anvil.mcp.servers = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        # marker landing pad for the extra.homeManager fragment test
        marker = lib.mkOption {
          type = lib.types.str;
          default = "unset";
        };
      };
    };
  nixosUniverse =
    { lib, ... }:
    {
      options = {
        environment.systemPackages = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = [ ];
        };
        systemd.services = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
      };
    };
  darwinUniverse =
    { lib, ... }:
    {
      options = {
        environment.systemPackages = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = [ ];
        };
        launchd.daemons = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
      };
    };

  evalHM =
    pkgs: modules:
    lib.evalModules {
      class = "homeManager";
      modules = [
        hmUniverse
        { _module.args.pkgs = pkgs; }
      ]
      ++ modules;
    };
  evalNixos =
    pkgs: modules:
    lib.evalModules {
      class = "nixos";
      modules = [
        nixosUniverse
        { _module.args.pkgs = pkgs; }
      ]
      ++ modules;
    };
  evalDarwin =
    pkgs: modules:
    lib.evalModules {
      class = "darwin";
      modules = [
        darwinUniverse
        { _module.args.pkgs = pkgs; }
      ]
      ++ modules;
    };

  en = {
    programs.tend.enable = true;
  };

  # ── specs under test ─────────────────────────────────────────────────
  # Canonical: lazy package + extras + settings + user daemon.
  pm = mkPackageModule {
    name = "tend";
    description = "tend repo daemon";
    extraPackages = [ "helper" ];
    surface.settings = { };
    daemon = {
      scope = "user";
    };
  };
  pmSys = mkPackageModule {
    name = "tend";
    description = "tend repo daemon";
    daemon.scope = "system";
  };
  pmDarwinOnly = mkPackageModule {
    name = "tend";
    description = "tend repo daemon";
    platforms = [ "darwin" ];
  };
  pmExtra = mkPackageModule {
    name = "tend";
    description = "tend repo daemon";
    extra.homeManager = {
      marker = "from-extra";
    };
  };
  pmEmptySub = mkPackageModule {
    name = "tend";
    description = "tend repo daemon";
    daemon = {
      scope = "user";
      subcommand = "";
    };
  };
  pmPeriodic = mkPackageModule {
    name = "tend";
    description = "tend repo daemon";
    daemon = {
      scope = "user";
      schedule.interval = 300;
    };
  };
  pmNs = mkPackageModule {
    name = "tend";
    description = "tend repo daemon";
    surface.namespace = "blackmatter.components";
  };
  pmMcp = mkPackageModule {
    name = "tend";
    description = "tend repo daemon";
    mcp = {
      scopes = [ "dev" ];
      agents = [ "claude" ];
      shim = true;
    };
  };
  pmMcpNoAnvil = mkPackageModule {
    name = "tend";
    description = "tend repo daemon";
    mcp.anvil = false;
  };
  pmMcpBareArgs = mkPackageModule {
    name = "tend";
    description = "tend repo daemon";
    mcp = {
      subcommand = "";
      args = [ "--stdio" ];
    };
  };
  pmHttp = mkPackageModule {
    name = "tend";
    description = "tend repo daemon";
    http = { };
  };

  modArgs = {
    inherit lib;
    pkgs = stubPkgsLinux;
    config = { };
  };
in
{
  # ── THE COUPLING-KILLER ──────────────────────────────────────────────
  # enable = false against a pkgs that LACKS the package attr entirely:
  # evaluation succeeds and installs nothing — the lazy default never
  # forces pkgs.tend.
  disabled-never-forces-missing-package = {
    expr = (evalHM stubPkgsNoTend [ pm.homeManager ]).config.home.packages;
    expected = [ ];
  };

  # ── install path ─────────────────────────────────────────────────────
  enabled-installs-package-and-extras = {
    expr =
      (evalHM stubPkgsLinux [
        pm.homeManager
        en
      ]).config.home.packages;
    expected = [
      "TEND_DRV"
      "HELPER_DRV"
    ];
  };
  cfg-package-override-wins = {
    expr =
      let
        ps =
          (evalHM stubPkgsLinux [
            pm.homeManager
            en
            { programs.tend.package = fakeDrv "override-drv"; }
          ]).config.home.packages;
      in
      {
        head = (builtins.head ps).name;
        len = builtins.length ps;
      };
    expected = {
      head = "override-drv";
      len = 2;
    };
  };

  # ── settings render ──────────────────────────────────────────────────
  settings-render-file-and-session-variable = {
    expr =
      let
        c =
          (evalHM stubPkgsLinux [
            pm.homeManager
            en
          ]).config;
      in
      {
        src = c.home.file.".config/tend/tend.yaml".source;
        env = c.home.sessionVariables.TEND_CONFIG;
      };
    expected = {
      src = "gen:tend.yaml";
      env = "/home/u/.config/tend/tend.yaml";
    };
  };

  # ── user daemon: per-platform dispatch ───────────────────────────────
  user-daemon-linux-lands-systemd-user = {
    expr =
      let
        c =
          (evalHM stubPkgsLinux [
            pm.homeManager
            en
          ]).config;
        exec = c.systemd.user.services.tend.Service.ExecStart;
      in
      {
        hasSvc = c.systemd.user.services ? tend;
        execHasBin = lib.hasInfix "/bin/tend" exec;
        execHasSub = lib.hasInfix "daemon" exec;
        agents = c.launchd.agents;
      };
    expected = {
      hasSvc = true;
      execHasBin = true;
      execHasSub = true;
      agents = { };
    };
  };
  user-daemon-darwin-lands-launchd-agent = {
    expr =
      let
        c =
          (evalHM stubPkgsDarwin [
            pm.homeManager
            en
          ]).config;
      in
      {
        hasAgent = c.launchd.agents ? tend;
        headIsTendDrv = lib.hasPrefix "TEND_DRV" (builtins.head c.launchd.agents.tend.config.ProgramArguments);
        services = c.systemd.user.services;
      };
    expected = {
      hasAgent = true;
      headIsTendDrv = true;
      services = { };
    };
  };
  user-daemon-periodic-emits-user-timer = {
    expr =
      let
        c =
          (evalHM stubPkgsLinux [
            pmPeriodic.homeManager
            en
          ]).config;
      in
      {
        svcType = c.systemd.user.services.tend.Service.Type;
        timer = c.systemd.user.timers.tend.Timer.OnUnitActiveSec;
      };
    expected = {
      svcType = "oneshot";
      timer = "300s";
    };
  };
  empty-subcommand-no-trailing-token = {
    # systemd-escaped (toJSON-quoted) single argv element, no subcommand.
    expr =
      (evalHM stubPkgsLinux [
        pmEmptySub.homeManager
        en
      ]).config.systemd.user.services.tend.Service.ExecStart == ''"TEND_DRV/bin/tend"'';
    expected = true;
  };

  # ── system daemon: nixos + darwin projections ────────────────────────
  system-daemon-nixos-systemd-service = {
    expr =
      let
        c =
          (evalNixos stubPkgsLinux [
            pmSys.nixos
            en
          ]).config;
      in
      {
        restart = c.systemd.services.tend.serviceConfig.Restart;
        pkgsNonEmpty = c.environment.systemPackages != [ ];
      };
    expected = {
      restart = "always";
      pkgsNonEmpty = true;
    };
  };
  system-daemon-darwin-launchd-daemon = {
    expr =
      let
        c =
          (evalDarwin stubPkgsDarwin [
            pmSys.darwin
            en
          ]).config;
      in
      {
        hasDaemon = c.launchd.daemons ? tend;
        pkgsNonEmpty = c.environment.systemPackages != [ ];
      };
    expected = {
      hasDaemon = true;
      pkgsNonEmpty = true;
    };
  };

  # ── platform gate ────────────────────────────────────────────────────
  platform-gate-darwin-only-skips-linux-hm = {
    expr =
      (evalHM stubPkgsLinux [
        pmDarwinOnly.homeManager
        en
      ]).config.home.packages;
    expected = [ ];
  };
  platform-gate-darwin-only-active-on-darwin = {
    expr =
      (evalHM stubPkgsDarwin [
        pmDarwinOnly.homeManager
        en
      ]).config.home.packages;
    expected = [ "TEND_DRV" ];
  };

  # ── extra fragments ──────────────────────────────────────────────────
  extra-homemanager-module-lands = {
    expr = (evalHM stubPkgsLinux [ pmExtra.homeManager ]).config.marker;
    expected = "from-extra";
  };

  # ── mcp: anvil registration ──────────────────────────────────────────
  mcp-anvil-enabled-registers-server = {
    expr =
      let
        entry =
          (evalHM stubPkgsLinux [
            pmMcp.homeManager
            en
          ]).config.blackmatter.components.anvil.mcp.servers.tend;
      in
      {
        cmdEndsBin = lib.hasSuffix "/bin/tend" entry.command;
        args = entry.args;
        scopes = entry.scopes;
        agents = entry.agents;
        enable = entry.enable;
      };
    expected = {
      cmdEndsBin = true;
      args = [ "mcp" ];
      scopes = [ "dev" ];
      agents = [ "claude" ];
      enable = true;
    };
  };
  # Disabled module → no registration. Evaluated against the pkgs that
  # LACKS the package attr: the anvil entry is a lazy leaf, so the
  # coupling-killer extends to mcp.
  mcp-anvil-disabled-module-absent = {
    expr =
      (evalHM stubPkgsNoTend [
        pmMcp.homeManager
      ]).config.blackmatter.components.anvil.mcp.servers;
    expected = { };
  };
  mcp-anvil-false-no-registration = {
    expr =
      (evalHM stubPkgsLinux [
        pmMcpNoAnvil.homeManager
        en
      ]).config.blackmatter.components.anvil.mcp.servers;
    expected = { };
  };
  mcp-empty-subcommand-args-only = {
    expr =
      (evalHM stubPkgsLinux [
        pmMcpBareArgs.homeManager
        en
      ]).config.blackmatter.components.anvil.mcp.servers.tend.args;
    expected = [ "--stdio" ];
  };

  # ── mcp: shim option ─────────────────────────────────────────────────
  mcp-shim-option-exists-default-off = {
    expr =
      let
        r = evalHM stubPkgsLinux [
          pmMcp.homeManager
          en
        ];
      in
      {
        optExists = r.options.programs.tend ? enableMcpBin;
        fileAbsent = !(r.config.home.file ? ".local/bin/tend-mcp");
      };
    expected = {
      optExists = true;
      fileAbsent = true;
    };
  };
  mcp-shim-flipped-creates-home-file = {
    expr =
      let
        f =
          (evalHM stubPkgsLinux [
            pmMcp.homeManager
            en
            { programs.tend.enableMcpBin = true; }
          ]).config.home.file.".local/bin/tend-mcp";
      in
      {
        executable = f.executable;
        hasBash = lib.hasPrefix "#!BASH_DRV/bin/bash" f.text;
        hasExecBin = lib.hasInfix "exec TEND_DRV/bin/tend" f.text;
        hasSub = lib.hasInfix "mcp" f.text;
        hasPassthrough = lib.hasInfix ''"$@"'' f.text;
      };
    expected = {
      executable = true;
      hasBash = true;
      hasExecBin = true;
      hasSub = true;
      hasPassthrough = true;
    };
  };

  # ── http: user unit per-platform dispatch ────────────────────────────
  http-option-default-off-no-unit = {
    expr =
      (evalHM stubPkgsLinux [
        pmHttp.homeManager
        en
      ]).config.systemd.user.services;
    expected = { };
  };
  http-enabled-linux-lands-systemd-user = {
    expr =
      let
        c =
          (evalHM stubPkgsLinux [
            pmHttp.homeManager
            en
            { programs.tend.http.enable = true; }
          ]).config;
        exec = c.systemd.user.services."tend-http".Service.ExecStart;
      in
      {
        hasSvc = c.systemd.user.services ? "tend-http";
        execHasBin = lib.hasInfix "/bin/tend" exec;
        execHasServe = lib.hasInfix "serve" exec;
        execHasAddr = lib.hasInfix "--addr" exec && lib.hasInfix "127.0.0.1:7860" exec;
        agents = c.launchd.agents;
      };
    expected = {
      hasSvc = true;
      execHasBin = true;
      execHasServe = true;
      execHasAddr = true;
      agents = { };
    };
  };
  http-enabled-darwin-lands-launchd-agent = {
    expr =
      let
        c =
          (evalHM stubPkgsDarwin [
            pmHttp.homeManager
            en
            { programs.tend.http.enable = true; }
          ]).config;
        pa = c.launchd.agents."tend-http".config.ProgramArguments;
      in
      {
        hasAgent = c.launchd.agents ? "tend-http";
        hasServe = builtins.elem "serve" pa;
        hasAddr = builtins.elem "--addr" pa && builtins.elem "127.0.0.1:7860" pa;
        services = c.systemd.user.services;
      };
    expected = {
      hasAgent = true;
      hasServe = true;
      hasAddr = true;
      services = { };
    };
  };
  http-addr-override-wins = {
    expr =
      lib.hasInfix "0.0.0.0:9999"
        (evalHM stubPkgsLinux [
          pmHttp.homeManager
          en
          {
            programs.tend.http = {
              enable = true;
              addr = "0.0.0.0:9999";
            };
          }
        ]).config.systemd.user.services."tend-http".Service.ExecStart;
    expected = true;
  };
  http-requires-parent-enable = {
    expr =
      (evalHM stubPkgsLinux [
        pmHttp.homeManager
        { programs.tend.http.enable = true; }
      ]).config.systemd.user.services;
    expected = { };
  };

  # ── meta + surface introspection ─────────────────────────────────────
  meta-fields-exact = {
    expr = pm.meta;
    expected = {
      name = "tend";
      optionPath = [
        "programs"
        "tend"
      ];
      enablePath = [
        "programs"
        "tend"
        "enable"
      ];
      packageAttr = "tend";
      platforms = [
        "darwin"
        "linux"
      ];
      hasDaemon = true;
      daemonScope = "user";
      hasSettings = true;
      hasMcp = false;
      hasHttp = false;
      version = "0.1.0";
    };
  };
  meta-no-daemon-no-settings = {
    expr = {
      inherit (pmNs.meta) hasDaemon daemonScope hasSettings;
    };
    expected = {
      hasDaemon = false;
      daemonScope = null;
      hasSettings = false;
    };
  };
  meta-has-mcp-has-http = {
    expr = {
      mcpOnMcp = pmMcp.meta.hasMcp;
      httpOnMcp = pmMcp.meta.hasHttp;
      mcpOnHttp = pmHttp.meta.hasMcp;
      httpOnHttp = pmHttp.meta.hasHttp;
    };
    expected = {
      mcpOnMcp = true;
      httpOnMcp = false;
      mcpOnHttp = false;
      httpOnHttp = true;
    };
  };
  surface-exposed-with-lazy-package-default = {
    expr = pm.surface.packageSpec;
    expected = {
      attr = "tend";
      lazy = true;
    };
  };
  surface-overrides-merge-over-defaults = {
    expr = pmNs.meta.optionPath;
    expected = [
      "blackmatter"
      "components"
      "tend"
    ];
  };

  # ── typed throws ─────────────────────────────────────────────────────
  name-missing-throws = {
    expr = (builtins.tryEval (mkPackageModule { description = "d"; }).meta.name).success;
    expected = false;
  };
  description-missing-throws = {
    # mkEnableOption's description interpolation is LAZY — force it.
    expr =
      (builtins.tryEval
        ((mkPackageModule { name = "x"; }).surface.module modArgs).options.programs.x.enable.description
      ).success;
    expected = false;
  };
  platforms-invalid-throws = {
    expr =
      (builtins.tryEval
        (mkPackageModule {
          name = "x";
          description = "d";
          platforms = [ "windows" ];
        }).meta.platforms
      ).success;
    expected = false;
  };
  daemon-bad-scope-throws = {
    expr =
      (builtins.tryEval
        (mkPackageModule {
          name = "x";
          description = "d";
          daemon.scope = "global";
        }).meta.daemonScope
      ).success;
    expected = false;
  };
  daemon-bad-shape-throws = {
    expr =
      (builtins.tryEval
        (mkPackageModule {
          name = "x";
          description = "d";
          daemon = "yes";
        }).meta.hasDaemon
      ).success;
    expected = false;
  };
  extra-bad-key-or-shape-throws = {
    expr =
      let
        # imports lists are LAZY — force the inner composite's imports.
        forceImports = p: builtins.length (builtins.head p.homeManager.imports).imports;
      in
      {
        unknownKey =
          (builtins.tryEval (forceImports (mkPackageModule {
            name = "x";
            description = "d";
            extra.nixOS = { };
          }))).success;
        badShape =
          (builtins.tryEval (forceImports (mkPackageModule {
            name = "x";
            description = "d";
            extra = 42;
          }))).success;
      };
    expected = {
      unknownKey = false;
      badShape = false;
    };
  };
  extra-packages-bad-shape-throws = {
    expr =
      (builtins.tryEval
        (evalHM stubPkgsLinux [
          (mkPackageModule {
            name = "tend";
            description = "d";
            extraPackages = "helper";
          }).homeManager
          en
        ]).config.home.packages
      ).success;
    expected = false;
  };
  surface-bad-shape-throws = {
    expr =
      (builtins.tryEval
        (mkPackageModule {
          name = "x";
          description = "d";
          surface = 42;
        }).meta.optionPath
      ).success;
    expected = false;
  };
  mcp-bad-shape-or-key-throws = {
    expr = {
      badShape =
        (builtins.tryEval
          (mkPackageModule {
            name = "x";
            description = "d";
            mcp = "yes";
          }).meta.hasMcp
        ).success;
      unknownKey =
        (builtins.tryEval
          (mkPackageModule {
            name = "x";
            description = "d";
            mcp.subcmd = "m";
          }).meta.hasMcp
        ).success;
    };
    expected = {
      badShape = false;
      unknownKey = false;
    };
  };
  http-bad-shape-or-key-throws = {
    expr = {
      badShape =
        (builtins.tryEval
          (mkPackageModule {
            name = "x";
            description = "d";
            http = 80;
          }).meta.hasHttp
        ).success;
      unknownKey =
        (builtins.tryEval
          (mkPackageModule {
            name = "x";
            description = "d";
            http.port = 80;
          }).meta.hasHttp
        ).success;
    };
    expected = {
      badShape = false;
      unknownKey = false;
    };
  };
}
# ── class tagging: HM module under a nixos-class eval is REJECTED ──────
// iroha.mkModuleEvalCheck {
  name = "hm-module-under-nixos-class";
  modules = [
    (mkPackageModule {
      name = "tend";
      description = "tend repo daemon";
    }).homeManager
  ];
  class = "nixos";
  universe = [
    (
      { lib, ... }:
      {
        options.home.packages = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = [ ];
        };
      }
    )
  ];
  expectClassReject = true;
}
