# iroha.package-module — L2 keystone: one spec → one standardized
# package-module interface, projected onto all three module classes.
#
# The operator vision this letter realizes: a fleet app is declared ONCE
# (name + description + package + optional settings + optional daemon) and
# the alphabet emits the home-manager / NixOS / nix-darwin modules that
# every configuration layer composes over. It subsumes the hand-wired HM
# idioms of module-trio.nix (home.packages, platform gating, per-platform
# daemon dispatch) by composing the lower letters: option-surface owns the
# option skeleton (enable + LAZY package + RFC42 settings — lazy package
# resolution is the iroha default and the coupling-killer: a disabled
# module never forces pkgs.<attr>), daemon owns the four unit projections,
# core owns class tagging. Fragments land via `imports`, so consumers can
# override any piece through the module system. pkgs never appears at
# import time — it binds late, inside the emitted fragments.
#
# Exports (pure { lib }, zero pkgs):
#
#   mkPackageModule :: {
#     name        :: str (required) — component name (option leaf, unit name);
#     description :: str (required) — human description;
#     namespace   ? "programs"      — dotted option root;
#     optionName  ? name            — last option-path segment;
#     packageAttr ? name            — pkgs attribute the lazy package resolves to;
#     binaryName  ? name            — daemon binary under <package>/bin/;
#     platforms   ? [ "darwin" "linux" ] — non-empty subset; gates every fragment:
#                   HM gate = cfg.enable && (darwin∈platforms || !isDarwin)
#                                        && (linux∈platforms  ||  isDarwin);
#                   nixos gate  = cfg.enable && linux ∈ platforms;
#                   darwin gate = cfg.enable && darwin ∈ platforms;
#     surface     ? { }             — extra mkOptionSurface args merged OVER the
#                   computed defaults { name, description, namespace, optionName,
#                   package = { attr = packageAttr; lazy = true; } } — may add
#                   settings / extra / package overrides (escape hatch);
#     extraPackages ? [ ]           — listOf str: additional pkgs attr names
#                   installed alongside the package when enabled;
#     daemon      ? null | {
#       scope      ? "user"         — "user" (HM launchd agent / systemd --user)
#                                     | "system" (nix-darwin daemon / NixOS unit);
#       subcommand ? "daemon"       — null or "" → no subcommand token;
#       args       ? [ ]; env ? { }; keepAlive ? true; schedule ? null
#                   (passed through to iroha.daemon.mkDaemonUnit); logDir ? null;
#     }                             — exec command = "<resolved-pkg>/bin/<binaryName>",
#                   args = [ subcommand ] ++ args; the unit is resolved INSIDE the
#                   fragment where cfg/pkgs exist (cfg.package override respected);
#     mcp         ? null | {        — MCP distribution (subsumes module-trio's
#                                     withMcp + withAnvilMcp), HM only:
#       subcommand ? "mcp"          — null or "" → no subcommand token;
#       args       ? [ ]            — after the subcommand;
#       env        ? { }; scopes ? [ ]; agents ? [ ];
#       shim       ? false          — adds <ns>.<name>.enableMcpBin (bool, off):
#                   when flipped (and cfg.enable), home.file installs an
#                   executable ~/.local/bin/<name>-mcp text shim running
#                   `exec <resolved-pkg>/bin/<binaryName> <subcommand+args> "$@"`
#                   via ${pkgs.bash}/bin/bash — module-trio withMcp semantics;
#       anvil      ? true           — registers via iroha.mcp.mkMcpRegistration
#                   (command form, "<resolved-pkg>/bin/<binaryName>") into
#                   blackmatter.components.anvil.mcp.servers.<name>, gated
#                   mkIf cfg.enable (+ the HM platform gate);
#     };
#     http        ? null | {        — user-level HTTP service (subsumes
#                                     module-trio's withHttp), HM only:
#       subcommand ? "serve"        — null or "" → no subcommand token;
#       addr       ? "127.0.0.1:7860";
#     }                             — adds <ns>.<name>.http.{enable (bool, off),
#                   addr (str, default = http.addr)} options; when flipped (and
#                   cfg.enable), a user daemon unit (mkDaemonUnit, name
#                   "<name>-http", command = "<resolved-pkg>/bin/<binaryName>",
#                   args = [ subcommand "--addr" cfg.http.addr ]) lands via the
#                   same per-platform dispatch as the user daemon: darwin →
#                   launchd.agents."<name>-http", linux →
#                   systemd.user.services."<name>-http";
#     extra       ? { homeManager ? null; nixos ? null; darwin ? null; }
#                   — per-class extension modules appended to the corresponding
#                   emitted module's imports (NOT gated on enable);
#   } -> {
#     homeManager :: class-tagged module —
#                   imports = [ surface.module, hm-fragment, extra.homeManager? ];
#                   when gated on: home.packages = [ packageFor ] ++ extras;
#                   settings (when surface has them):
#                     home.file.<render.relPath>.source = render.source,
#                     home.sessionVariables.<render.envVar> =
#                       "<home.homeDirectory>/<render.relPath>";
#                   user daemon (scope == "user"): isDarwin →
#                     launchd.agents.<name> = unit.launchdAgent, else
#                     systemd.user.services.<name> = unit.systemdUser
#                     (+ systemd.user.timers.<name> when the unit is periodic);
#     nixos       :: class-tagged module — environment.systemPackages =
#                   [ packageFor ] ++ extras; system daemon (scope == "system"):
#                   systemd.services.<name> = unit.systemd (+ systemd.timers.<name>
#                   when periodic);
#     darwin      :: class-tagged module — environment.systemPackages; system
#                   daemon: launchd.daemons.<name> = unit.launchdDaemon;
#     meta        :: { name, optionPath, enablePath, packageAttr, platforms,
#                      hasDaemon, daemonScope (null when no daemon), hasSettings,
#                      hasMcp, hasHttp, version = "0.1.0" };
#     surface     :: the underlying mkOptionSurface result (introspection +
#                    escape hatch: packageFor / render / optionPath reusable);
#   }
#
# Throws (every message prefixed "iroha.package-module.mkPackageModule: "):
#   - `name` / `description` missing;
#   - `platforms` not a non-empty list drawn from [ "darwin" "linux" ];
#   - `extraPackages` not a list;
#   - `surface` not an attrset;
#   - `daemon` neither null nor an attrset; `daemon.scope` outside user|system;
#   - `mcp` neither null nor an attrset, or carrying keys other than
#     subcommand/args/env/scopes/agents/shim/anvil;
#   - `http` neither null nor an attrset, or carrying keys other than
#     subcommand/addr;
#   - `extra` not an attrset, or carrying keys other than homeManager/nixos/darwin.
{ lib }:
let
  core = import ./core.nix { inherit lib; };
  optionSurface = import ./option-surface.nix { inherit lib; };
  daemonLib = import ./daemon.nix { inherit lib; };
  mcpLib = import ./mcp.nix { inherit lib; };

  validPlatforms = [
    "darwin"
    "linux"
  ];
  validScopes = [
    "user"
    "system"
  ];
  validExtraKeys = [
    "homeManager"
    "nixos"
    "darwin"
  ];
  validMcpKeys = [
    "subcommand"
    "args"
    "env"
    "scopes"
    "agents"
    "shim"
    "anvil"
  ];
  validHttpKeys = [
    "subcommand"
    "addr"
  ];

  mkPackageModule =
    args:
    let
      name = args.name or (throw "iroha.package-module.mkPackageModule: `name` (str) is required.");
      description =
        args.description
          or (throw "iroha.package-module.mkPackageModule: `description` (str) is required.");
      namespace = args.namespace or "programs";
      optionName = args.optionName or name;
      packageAttr = args.packageAttr or name;
      binaryName = args.binaryName or name;

      platforms =
        let
          p = args.platforms or validPlatforms;
        in
        if !(builtins.isList p) || p == [ ] || !(builtins.all (x: builtins.elem x validPlatforms) p) then
          throw "iroha.package-module.mkPackageModule: `platforms` must be a non-empty list drawn from [ ${lib.concatStringsSep ", " validPlatforms} ] — got ${builtins.toJSON p}."
        else
          p;

      extraPackages =
        let
          e = args.extraPackages or [ ];
        in
        if !(builtins.isList e) then
          throw "iroha.package-module.mkPackageModule: `extraPackages` must be a list of pkgs attr names (listOf str) — got ${builtins.typeOf e}."
        else
          e;

      surfaceOverrides =
        let
          s = args.surface or { };
        in
        if !(builtins.isAttrs s) then
          throw "iroha.package-module.mkPackageModule: `surface` must be an attrset of mkOptionSurface overrides — got ${builtins.typeOf s}."
        else
          s;

      # Computed defaults UNDER, caller overrides OVER — lazy package
      # resolution (the coupling-killer) is the iroha default.
      surface = optionSurface.mkOptionSurface (
        {
          inherit
            name
            description
            namespace
            optionName
            ;
          package = {
            attr = packageAttr;
            lazy = true;
          };
        }
        // surfaceOverrides
      );

      daemonSpec =
        let
          d = args.daemon or null;
        in
        if d == null then
          null
        else if !(builtins.isAttrs d) then
          throw "iroha.package-module.mkPackageModule: `daemon` must be null or { scope ? \"user\", subcommand ? \"daemon\", args ? [ ], env ? { }, keepAlive ? true, schedule ? null, logDir ? null } — got ${builtins.typeOf d}."
        else
          let
            scope = d.scope or "user";
          in
          if !(builtins.elem scope validScopes) then
            throw "iroha.package-module.mkPackageModule: `daemon.scope` must be one of ${lib.concatStringsSep ", " validScopes} — got '${toString scope}'."
          else
            {
              inherit scope;
              subcommand = d.subcommand or "daemon";
              args = d.args or [ ];
              env = d.env or { };
              keepAlive = d.keepAlive or true;
              schedule = d.schedule or null;
              logDir = d.logDir or null;
            };

      mcpSpec =
        let
          m = args.mcp or null;
        in
        if m == null then
          null
        else if !(builtins.isAttrs m) then
          throw "iroha.package-module.mkPackageModule: `mcp` must be null or { subcommand ? \"mcp\", args ? [ ], env ? { }, scopes ? [ ], agents ? [ ], shim ? false, anvil ? true } — got ${builtins.typeOf m}."
        else if removeAttrs m validMcpKeys != { } then
          throw "iroha.package-module.mkPackageModule: `mcp` accepts only the keys ${lib.concatStringsSep ", " validMcpKeys} — got unknown key(s) ${lib.concatStringsSep ", " (builtins.attrNames (removeAttrs m validMcpKeys))}."
        else
          {
            subcommand = m.subcommand or "mcp";
            args = m.args or [ ];
            env = m.env or { };
            scopes = m.scopes or [ ];
            agents = m.agents or [ ];
            shim = m.shim or false;
            anvil = m.anvil or true;
          };

      httpSpec =
        let
          h = args.http or null;
        in
        if h == null then
          null
        else if !(builtins.isAttrs h) then
          throw "iroha.package-module.mkPackageModule: `http` must be null or { subcommand ? \"serve\", addr ? \"127.0.0.1:7860\" } — got ${builtins.typeOf h}."
        else if removeAttrs h validHttpKeys != { } then
          throw "iroha.package-module.mkPackageModule: `http` accepts only the keys ${lib.concatStringsSep ", " validHttpKeys} — got unknown key(s) ${lib.concatStringsSep ", " (builtins.attrNames (removeAttrs h validHttpKeys))}."
        else
          {
            subcommand = h.subcommand or "serve";
            addr = h.addr or "127.0.0.1:7860";
          };

      extraMods =
        let
          e = args.extra or { };
        in
        if !(builtins.isAttrs e) then
          throw "iroha.package-module.mkPackageModule: `extra` must be an attrset { homeManager ? null, nixos ? null, darwin ? null } — got ${builtins.typeOf e}."
        else if removeAttrs e validExtraKeys != { } then
          throw "iroha.package-module.mkPackageModule: `extra` accepts only the keys ${lib.concatStringsSep ", " validExtraKeys} — got unknown key(s) ${lib.concatStringsSep ", " (builtins.attrNames (removeAttrs e validExtraKeys))}."
        else
          {
            homeManager = e.homeManager or null;
            nixos = e.nixos or null;
            darwin = e.darwin or null;
          };

      hasUserDaemon = daemonSpec != null && daemonSpec.scope == "user";
      hasSystemDaemon = daemonSpec != null && daemonSpec.scope == "system";
      daemonIsPeriodic = daemonSpec != null && daemonSpec.schedule != null;
      hasSettings = surface.settingsSpec != null;
      hasMcp = mcpSpec != null;
      hasHttp = httpSpec != null;
      hasMcpShim = hasMcp && mcpSpec.shim;
      hasAnvil = hasMcp && mcpSpec.anvil;

      # subcommand null|"" → just args, no empty token.
      subTokens = sub: if sub == null || sub == "" then [ ] else [ sub ];
      daemonArgv = subTokens daemonSpec.subcommand ++ daemonSpec.args;
      mcpArgv = subTokens mcpSpec.subcommand ++ mcpSpec.args;
      httpArgvFor = cfg: subTokens httpSpec.subcommand ++ [ "--addr" cfg.http.addr ];

      # Resolved INSIDE fragments where cfg/pkgs exist — mkDaemonUnit is pure
      # and takes the already-resolved absolute command string.
      unitFor =
        { cfg, pkgs }:
        daemonLib.mkDaemonUnit {
          inherit name description;
          command = "${surface.packageFor { inherit cfg pkgs; }}/bin/${binaryName}";
          args = daemonArgv;
          inherit (daemonSpec)
            env
            keepAlive
            schedule
            logDir
            ;
        };

      # The "<name>-http" user unit — same resolution discipline as unitFor.
      httpUnitFor =
        { cfg, pkgs }:
        daemonLib.mkDaemonUnit {
          name = "${name}-http";
          description = "${description} HTTP service";
          command = "${surface.packageFor { inherit cfg pkgs; }}/bin/${binaryName}";
          args = httpArgvFor cfg;
        };

      # mcp/http option islands live in a sibling options module (NOT in the
      # surface's `extra` slot — that slot stays the caller's escape hatch).
      # HM-only, matching module-trio: the shim and the http unit are
      # home-level concerns.
      mcpHttpOptionsModule =
        { lib, ... }:
        {
          options = lib.setAttrByPath surface.optionPath (
            lib.optionalAttrs hasMcpShim {
              enableMcpBin = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Install a `${name}-mcp` shim at ~/.local/bin/${name}-mcp that runs `${binaryName} ${toString mcpSpec.subcommand}` (stdio transport) — useful for registering with blackmatter-anvil.";
              };
            }
            // lib.optionalAttrs hasHttp {
              http = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Run ${name} as a user-level HTTP service (`${binaryName} ${toString httpSpec.subcommand} --addr <addr>`).";
                };
                addr = lib.mkOption {
                  type = lib.types.str;
                  default = httpSpec.addr;
                  description = "Listen address for the ${name} HTTP service.";
                };
              };
            }
          );
        };

      onDarwin = builtins.elem "darwin" platforms;
      onLinux = builtins.elem "linux" platforms;

      hmPlatformOk =
        pkgs:
        (onDarwin || !pkgs.stdenv.hostPlatform.isDarwin)
        && (onLinux || pkgs.stdenv.hostPlatform.isDarwin);

      packagesFor =
        { cfg, pkgs }: [ (surface.packageFor { inherit cfg pkgs; }) ] ++ map (a: pkgs.${a}) extraPackages;

      hmFragment =
        {
          lib,
          pkgs,
          config,
          ...
        }:
        let
          cfg = lib.getAttrFromPath surface.optionPath config;
          render = surface.render { inherit cfg pkgs; };
          unit = unitFor { inherit cfg pkgs; };
          httpUnit = httpUnitFor { inherit cfg pkgs; };
          resolvedBin = "${surface.packageFor { inherit cfg pkgs; }}/bin/${binaryName}";
        in
        {
          config = lib.mkIf (cfg.enable && hmPlatformOk pkgs) (
            lib.mkMerge (
              [ { home.packages = packagesFor { inherit cfg pkgs; }; } ]
              ++ lib.optional hasSettings {
                home.file.${surface.settingsSpec.relPath}.source = render.source;
                home.sessionVariables.${surface.settingsSpec.envVar} =
                  config.home.homeDirectory + "/" + surface.settingsSpec.relPath;
              }
              # MCP shim — module-trio withMcp semantics: a text shim on
              # ~/.local/bin that execs the resolved binary over stdio.
              ++ lib.optionals hasMcpShim [
                (lib.mkIf cfg.enableMcpBin {
                  home.file.".local/bin/${name}-mcp" = {
                    executable = true;
                    text = ''
                      #!${pkgs.bash}/bin/bash
                      exec ${resolvedBin}${lib.optionalString (mcpArgv != [ ]) " ${lib.escapeShellArgs mcpArgv}"} "$@"
                    '';
                  };
                })
              ]
              # Anvil registration — through iroha.mcp.mkMcpRegistration
              # (command form: the path is pre-resolved here, where
              # cfg.package overrides are visible). serverEntry is placed
              # directly so the registration stays a LAZY leaf under the
              # servers option — a disabled module never forces the package.
              ++ lib.optionals hasAnvil [
                {
                  blackmatter.components.anvil.mcp.servers.${name} =
                    (mcpLib.mkMcpRegistration {
                      inherit name description;
                      command = resolvedBin;
                      args = mcpArgv;
                      inherit (mcpSpec) env scopes agents;
                    }).serverEntry;
                }
              ]
              # Platform branches as TWO mkIfs (the selector lives in the
              # condition, never in an if/then/else over the body shape —
              # see the module-trio.nix recursion note).
              ++ lib.optionals hasUserDaemon [
                (lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
                  launchd.agents.${name} = unit.launchdAgent;
                })
                # mkMerge elements, never `//` — `systemd.user.services.X //
                # systemd.user.timers.X` would shallow-clobber the shared
                # `systemd` key.
                (lib.mkIf (!pkgs.stdenv.hostPlatform.isDarwin) (
                  lib.mkMerge (
                    [ { systemd.user.services.${name} = unit.systemdUser; } ]
                    ++ lib.optional daemonIsPeriodic {
                      systemd.user.timers.${name} = unit.systemdUserTimer;
                    }
                  )
                ))
              ]
              # HTTP user unit — same per-platform dispatch as the user
              # daemon, gated on the http.enable island.
              ++ lib.optionals hasHttp [
                (lib.mkIf (cfg.http.enable && pkgs.stdenv.hostPlatform.isDarwin) {
                  launchd.agents."${name}-http" = httpUnit.launchdAgent;
                })
                (lib.mkIf (cfg.http.enable && !pkgs.stdenv.hostPlatform.isDarwin) {
                  systemd.user.services."${name}-http" = httpUnit.systemdUser;
                })
              ]
            )
          );
        };

      nixosFragment =
        {
          lib,
          pkgs,
          config,
          ...
        }:
        let
          cfg = lib.getAttrFromPath surface.optionPath config;
          unit = unitFor { inherit cfg pkgs; };
        in
        {
          config = lib.mkIf (cfg.enable && onLinux) (
            lib.mkMerge (
              [ { environment.systemPackages = packagesFor { inherit cfg pkgs; }; } ]
              # mkMerge elements, never `//` — services + timers share the
              # `systemd` key (shallow-clobber hazard).
              ++ lib.optional hasSystemDaemon (
                lib.mkMerge (
                  [ { systemd.services.${name} = unit.systemd; } ]
                  ++ lib.optional daemonIsPeriodic { systemd.timers.${name} = unit.systemdTimer; }
                )
              )
            )
          );
        };

      darwinFragment =
        {
          lib,
          pkgs,
          config,
          ...
        }:
        let
          cfg = lib.getAttrFromPath surface.optionPath config;
          unit = unitFor { inherit cfg pkgs; };
        in
        {
          config = lib.mkIf (cfg.enable && onDarwin) (
            lib.mkMerge (
              [ { environment.systemPackages = packagesFor { inherit cfg pkgs; }; } ]
              ++ lib.optional hasSystemDaemon {
                launchd.daemons.${name} = unit.launchdDaemon;
              }
            )
          );
        };

      mkClassModule =
        class: extraImports: fragment: extraMod:
        core.tag class {
          imports = [
            surface.module
          ]
          ++ extraImports
          ++ [ fragment ]
          ++ lib.optional (extraMod != null) extraMod;
        };
    in
    {
      homeManager = mkClassModule core.classes.homeManager (lib.optional (
        hasMcpShim || hasHttp
      ) mcpHttpOptionsModule) hmFragment extraMods.homeManager;
      nixos = mkClassModule core.classes.nixos [ ] nixosFragment extraMods.nixos;
      darwin = mkClassModule core.classes.darwin [ ] darwinFragment extraMods.darwin;
      meta = {
        inherit name packageAttr platforms;
        optionPath = surface.optionPath;
        enablePath = surface.enablePath;
        hasDaemon = daemonSpec != null;
        daemonScope = if daemonSpec == null then null else daemonSpec.scope;
        inherit hasSettings hasMcp hasHttp;
        version = "0.1.0";
      };
      inherit surface;
    };
in
{
  inherit mkPackageModule;
}
