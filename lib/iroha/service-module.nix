# iroha.service-module — L2: a full SYSTEM-class service MODULE emitter.
#
# iroha.daemon (the L2 sibling) emits unit ATTRS for the dominant
# user-level keep-alive/periodic pattern and EXPLICITLY excludes the
# root/system power fields (Type=notify, EnvironmentFile, StateDirectory,
# RuntimeDirectory, User/Group, hardening, ExecStartPre/Post, oneshot
# RemainAfterExit, …). This letter is the missing surface those ~50 fleet
# files reach for: it emits a complete class-tagged MODULE — an option
# surface (enable + caller-typed extras) plus a full system
# `systemd.services.<name>` (NixOS) and a minimal `launchd.daemons.<name>`
# (nix-darwin) projection that DO carry those fields. It does NOT emit a
# package option (system services run absolute paths the caller resolves)
# and it does NOT emit a home-manager projection (these are system units).
#
# ExecStart is built from EITHER an `execStart` string (verbatim, already
# an absolute command line) OR a `command` + `args` pair. When `command`
# is given, the systemd line is assembled from `[command] ++ args` and
# escaped with the nixpkgs escapeSystemdExecArg transform (toJSON + %%/$$
# doubling — systemd Exec lines are NOT a shell), vendored below because
# this file is pure { lib } and daemon.nix exports no escaper. When only
# `execStart` is given it is used verbatim (the caller owns escaping). The
# launchd ProgramArguments projection prefers the structured `command` +
# `args` form (a verbatim argv list, no escaping); when only `execStart`
# is given it falls back to `[ "/bin/sh" "-c" execStart ]` — documented
# because a bare string cannot be word-split safely into an argv.
#
# COMPOSES iroha.mkOptionSurface for the enable + extraOptions skeleton
# (package = false, settings = null) and iroha.core.tag for class tagging.
#
# Exports (pure { lib }, zero pkgs — pkgs binds late as a module arg):
#
#   mkServiceModule :: {
#     name        :: str (required) — unit name + last option-path segment;
#     description :: str (required) — human description (enable option text
#                                     + systemd Description);
#     namespace   ? "services"      — dotted option root; the option lands
#                                     at <namespace>.<name>;
#     enable      ? true            — emit the `enable` option (mkEnableOption);
#     extraOptions ? { } | (lib -> attrs) — extra typed option declarations
#                                     merged under the option root (function
#                                     form receives lib);
#     service     :: {              — the system unit spec
#       execStart   ? null (str)    — verbatim absolute command line; OR
#       command     ? null (str)    — absolute program path …
#       args        ? [ ] (listOf str) — … with these args, escaped + joined;
#                                     exactly one of execStart / command is
#                                     required;
#       type        ? "simple"      — "simple"|"oneshot"|"notify"|"forking";
#       wants       ? [ ];
#       requires    ? [ ];
#       after       ? [ "network.target" ];
#       before      ? [ ];
#       environment ? { } (attrsOf str);
#       environmentFile ? null (str);
#       stateDirectory  ? null (str);
#       runtimeDirectory ? null (str);
#       workingDirectory ? null (str);
#       user        ? null (str);
#       group       ? null (str);
#       restart     ? "on-failure";
#       restartSec  ? null (int|str);
#       remainAfterExit ? null (bool) — for oneshot units;
#       execStartPre  ? [ ] (listOf str);
#       execStartPost ? [ ] (listOf str);
#       wantedBy    ? [ "multi-user.target" ];
#       hardening   ? { }           — caller-typed attrs merged into
#                                     serviceConfig (ProtectSystem,
#                                     NoNewPrivileges, …);
#       serviceConfigExtra ? { }    — raw serviceConfig passthrough (wins
#                                     last);
#     };
#   } -> {
#     nixos :: class-tagged module (_class "nixos") —
#       options.<ns>.<name>.{ enable, …extraOptions };
#       config = mkIf cfg.enable {
#         systemd.services.<name> = {
#           inherit description;
#           wants/requires/after/before/wantedBy (only non-empty lists);
#           environment (only when non-empty);
#           serviceConfig =
#             { ExecStart, Type, Restart }
#             // optional { RestartSec, EnvironmentFile, StateDirectory,
#                           RuntimeDirectory, WorkingDirectory, User, Group,
#                           RemainAfterExit, ExecStartPre, ExecStartPost }
#             // hardening // serviceConfigExtra;
#         };
#       };
#     darwin :: class-tagged module (_class "darwin") —
#       config = mkIf cfg.enable {
#         launchd.daemons.<name>.serviceConfig = {
#           ProgramArguments = [command] ++ args  (or [ "/bin/sh" "-c"
#                              execStart ] when only execStart is given),
#           KeepAlive = (type != "oneshot"),
#           RunAtLoad = true,
#           EnvironmentVariables (when environment non-empty),
#           WorkingDirectory (when set),
#         };
#       };
#       Tier-honest: the darwin projection is intentionally MINIMAL —
#       launchd has no systemd-hardening analog, so hardening/EnvironmentFile/
#       StateDirectory/etc. are NOT projected; only the load-bearing
#       run-it-as-a-daemon fields cross over. For full plists use
#       hm/darwin-service-helpers.nix mkLaunchdDaemon.
#     meta :: { name, optionPath, enablePath, kind = "system-service" };
#   }
#
# Throws (every message prefixed "iroha.service-module.mkServiceModule: "):
#   - `name` / `description` missing;
#   - `service` missing, or neither `execStart` nor `command` given, or BOTH
#     given (ambiguous);
#   - `service.type` not in simple|oneshot|notify|forking;
#   - an Exec arg that is not a string/path/number (escapeSystemdExecArg).
{ lib }:
let
  core = import ./core.nix { inherit lib; };
  optionSurface = import ./option-surface.nix { inherit lib; };
  inherit (lib) optionalAttrs;

  # Vendored from nixpkgs nixos/lib/utils.nix escapeSystemdExecArg(s) (same
  # transform daemon.nix vendors — daemon.nix exports no escaper, so it is
  # duplicated here at the pure-{ lib } border; both are the canonical
  # nixpkgs semantics, not a fork). systemd Exec lines are NOT a shell:
  # toJSON emits the C-style escape subset, `%` doubled to suppress
  # specifier expansion, `$` doubled to suppress environment substitution.
  escapeSystemdExecArg =
    arg:
    lib.replaceStrings [ "%" "$" ] [ "%%" "$$" ] (
      builtins.toJSON (
        if builtins.isString arg then
          arg
        else if builtins.isPath arg then
          toString arg
        else if builtins.isInt arg || builtins.isFloat arg then
          toString arg
        else
          throw "iroha.service-module.mkServiceModule: Exec arguments must be strings, paths, or numbers — got ${builtins.typeOf arg}."
      )
    );
  escapeSystemdExecArgs = lib.concatMapStringsSep " " escapeSystemdExecArg;

  validTypes = [
    "simple"
    "oneshot"
    "notify"
    "forking"
  ];

  mkServiceModule =
    args:
    let
      name = args.name or (throw "iroha.service-module.mkServiceModule: `name` (str) is required.");
      description =
        args.description
          or (throw "iroha.service-module.mkServiceModule: `description` (str) is required.");
      namespace = args.namespace or "services";
      enable = args.enable or true;
      extraOptions = args.extraOptions or { };
      service =
        args.service
          or (throw "iroha.service-module.mkServiceModule: `service` (attrs — the system unit spec) is required.");

      # ── exec line: exactly one of execStart / command ───────────────────
      hasExecStart = (service.execStart or null) != null;
      hasCommand = (service.command or null) != null;
      execStart =
        if hasExecStart && hasCommand then
          throw "iroha.service-module.mkServiceModule: `service` takes exactly one of `execStart` (verbatim line) or `command` (+ `args`) — got both."
        else if hasExecStart then
          service.execStart
        else if hasCommand then
          escapeSystemdExecArgs ([ service.command ] ++ (service.args or [ ]))
        else
          throw "iroha.service-module.mkServiceModule: `service` needs one of `execStart` (str) or `command` (str — absolute program path; the caller resolves the package).";

      # launchd ProgramArguments: prefer the structured argv (verbatim, no
      # escaping); fall back to a shell wrapper when only execStart is given
      # (a bare string cannot be word-split into an argv safely).
      programArguments =
        if hasCommand then
          [ service.command ] ++ (service.args or [ ])
        else
          [
            "/bin/sh"
            "-c"
            execStart
          ];

      type = service.type or "simple";
      _typeChecked =
        if builtins.elem type validTypes then
          type
        else
          throw "iroha.service-module.mkServiceModule: `service.type` must be one of ${lib.concatStringsSep ", " validTypes} — got '${toString type}'.";

      wants = service.wants or [ ];
      requires = service.requires or [ ];
      after = service.after or [ "network.target" ];
      before = service.before or [ ];
      environment = service.environment or { };
      environmentFile = service.environmentFile or null;
      stateDirectory = service.stateDirectory or null;
      runtimeDirectory = service.runtimeDirectory or null;
      workingDirectory = service.workingDirectory or null;
      user = service.user or null;
      group = service.group or null;
      restart = service.restart or "on-failure";
      restartSec = service.restartSec or null;
      remainAfterExit = service.remainAfterExit or null;
      execStartPre = service.execStartPre or [ ];
      execStartPost = service.execStartPost or [ ];
      wantedBy = service.wantedBy or [ "multi-user.target" ];
      hardening = service.hardening or { };
      serviceConfigExtra = service.serviceConfigExtra or { };

      # ── option surface (enable + extras; no package, no settings) ───────
      surface = optionSurface.mkOptionSurface {
        inherit
          name
          description
          namespace
          enable
          ;
        package = false;
        settings = null;
        extra = extraOptions;
      };

      optionPath = surface.optionPath;
      enablePath = surface.enablePath;

      # ── systemd serviceConfig (NixOS system) ────────────────────────────
      serviceConfig =
        {
          ExecStart = execStart;
          Type = _typeChecked;
          Restart = restart;
        }
        // optionalAttrs (restartSec != null) { RestartSec = restartSec; }
        // optionalAttrs (environmentFile != null) { EnvironmentFile = environmentFile; }
        // optionalAttrs (stateDirectory != null) { StateDirectory = stateDirectory; }
        // optionalAttrs (runtimeDirectory != null) { RuntimeDirectory = runtimeDirectory; }
        // optionalAttrs (workingDirectory != null) { WorkingDirectory = workingDirectory; }
        // optionalAttrs (user != null) { User = user; }
        // optionalAttrs (group != null) { Group = group; }
        // optionalAttrs (remainAfterExit != null) { RemainAfterExit = remainAfterExit; }
        // optionalAttrs (execStartPre != [ ]) { ExecStartPre = execStartPre; }
        // optionalAttrs (execStartPost != [ ]) { ExecStartPost = execStartPost; }
        // hardening
        // serviceConfigExtra;

      systemdService =
        {
          inherit description;
          inherit serviceConfig;
        }
        // optionalAttrs (wants != [ ]) { inherit wants; }
        // optionalAttrs (requires != [ ]) { inherit requires; }
        // optionalAttrs (after != [ ]) { inherit after; }
        // optionalAttrs (before != [ ]) { inherit before; }
        // optionalAttrs (wantedBy != [ ]) { inherit wantedBy; }
        // optionalAttrs (environment != { }) { inherit environment; };

      nixosFragment =
        {
          config,
          ...
        }:
        let
          cfg = lib.getAttrFromPath optionPath config;
        in
        {
          config = lib.mkIf cfg.enable {
            systemd.services.${name} = systemdService;
          };
        };

      # ── launchd (nix-darwin daemon) — minimal projection ────────────────
      launchdServiceConfig =
        {
          ProgramArguments = programArguments;
          KeepAlive = type != "oneshot";
          RunAtLoad = true;
        }
        // optionalAttrs (environment != { }) { EnvironmentVariables = environment; }
        // optionalAttrs (workingDirectory != null) { WorkingDirectory = workingDirectory; };

      darwinFragment =
        {
          config,
          ...
        }:
        let
          cfg = lib.getAttrFromPath optionPath config;
        in
        {
          config = lib.mkIf cfg.enable {
            launchd.daemons.${name}.serviceConfig = launchdServiceConfig;
          };
        };

      mkClassModule =
        class: fragment:
        core.tag class {
          imports = [
            surface.module
            fragment
          ];
        };
    in
    {
      nixos = mkClassModule core.classes.nixos nixosFragment;
      darwin = mkClassModule core.classes.darwin darwinFragment;
      meta = {
        inherit name optionPath enablePath;
        kind = "system-service";
      };
    };
in
{
  inherit mkServiceModule;
}
