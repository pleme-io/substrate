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
#                      version = "0.1.0" };
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
#   - `extra` not an attrset, or carrying keys other than homeManager/nixos/darwin.
{ lib }:
let
  core = import ./core.nix { inherit lib; };
  optionSurface = import ./option-surface.nix { inherit lib; };
  daemonLib = import ./daemon.nix { inherit lib; };

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

      # subcommand null|"" → just args, no empty token.
      daemonArgv =
        (
          if daemonSpec.subcommand == null || daemonSpec.subcommand == "" then
            [ ]
          else
            [ daemonSpec.subcommand ]
        )
        ++ daemonSpec.args;

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
        class: fragment: extraMod:
        core.tag class {
          imports = [
            surface.module
            fragment
          ]
          ++ lib.optional (extraMod != null) extraMod;
        };
    in
    {
      homeManager = mkClassModule core.classes.homeManager hmFragment extraMods.homeManager;
      nixos = mkClassModule core.classes.nixos nixosFragment extraMods.nixos;
      darwin = mkClassModule core.classes.darwin darwinFragment extraMods.darwin;
      meta = {
        inherit name packageAttr platforms;
        optionPath = surface.optionPath;
        enablePath = surface.enablePath;
        hasDaemon = daemonSpec != null;
        daemonScope = if daemonSpec == null then null else daemonSpec.scope;
        inherit hasSettings;
        version = "0.1.0";
      };
      inherit surface;
    };
in
{
  inherit mkPackageModule;
}
