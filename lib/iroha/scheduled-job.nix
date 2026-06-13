# iroha.scheduled-job — L2: a SCHEDULED (periodic/cron-like) job MODULE emitter.
#
# Sibling to iroha.service-module. service-module emits a full system-class
# MODULE for a KEEP-ALIVE daemon (systemd.services.<name> with Restart=… +
# launchd KeepAlive=true). This letter emits the OTHER half of the system
# scheduled-work pattern: a oneshot `systemd.services.<name>` (Type=oneshot,
# NO Restart) DRIVEN BY a `systemd.timers.<name>`, and a launchd
# `launchd.daemons.<name>` with StartInterval (interval) or
# StartCalendarInterval (calendar) + RunAtLoad=false + KeepAlive=false. It is
# the surface ~N nightly-fleet jobs reach for: mkScheduledFleetMutation
# (nightly fetch / flake-update / commit), the rio NIC-tune timers,
# attic-cache-warmer, any cron-like fleet job.
#
# iroha.daemon ALSO covers periodic mode, but emits unit ATTRS (the dominant
# USER-level keep-alive + periodic pattern); this letter emits a complete
# class-tagged MODULE (option surface + system unit + timer) for SYSTEM
# scheduled jobs — the same relationship daemon ↔ service-module hold for
# keep-alive units. It does NOT emit a package option (system jobs run
# absolute paths the caller resolves) and it does NOT emit a home-manager
# projection (these are system units).
#
# The schedule normalization mirrors daemon.nix exactly:
#   { interval :: int (seconds) }                 -> systemd OnUnitActiveSec
#                                                    "<n>s" + launchd StartInterval;
#   { calendar :: { systemd :: str (OnCalendar);
#                   launchd :: attrs (StartCalendarInterval) } }
#                                                 -> systemd OnCalendar str +
#                                                    launchd StartCalendarInterval.
# Exactly one of interval / calendar is required (a typed throw on missing,
# both, or neither). The calendar form here is ALWAYS the dual form (this
# letter projects to BOTH platforms from one spec, so both halves are
# mandatory) — there is no bare-calendar escape (that exists in daemon.nix
# only because its launchd-only projections can stand alone).
#
# ExecStart is built from EITHER an `execStart` string (verbatim, already an
# absolute command line; the caller owns escaping) OR a `command` + `args`
# pair (assembled from `[command] ++ args` and escaped with the nixpkgs
# escapeSystemdExecArg transform — toJSON + %%/$$ doubling, systemd Exec lines
# are NOT a shell; vendored below because this file is pure { lib }). The
# launchd ProgramArguments projection prefers the structured `command` + `args`
# argv (verbatim, no escaping); when only `execStart` is given it falls back to
# `[ "/bin/sh" "-c" execStart ]` (a bare string cannot be word-split safely).
#
# COMPOSES iroha.mkOptionSurface for the enable + extraOptions skeleton
# (package = false, settings = null) and iroha.core.tag for class tagging.
#
# Exports (pure { lib }, zero pkgs — pkgs binds late as a module arg):
#
#   mkScheduledJob :: {
#     name        :: str (required) — unit name + last option-path segment;
#     description :: str (required) — human description (enable option text +
#                                     systemd Description);
#     namespace   ? "services"      — dotted option root; the job lands at
#                                     <namespace>.<name>;
#     enable      ? true            — emit the `enable` option (mkEnableOption);
#     extraOptions ? { } | (lib -> attrs) — extra typed option declarations
#                                     merged under the option root (function
#                                     form receives lib);
#     execStart   ? null (str)      — verbatim absolute command line; OR
#     command     ? null (str)      — absolute program path …
#     args        ? [ ] (listOf str) — … with these args, escaped + joined;
#                                     exactly one of execStart / command;
#     schedule    :: {              — (required — typed throw if missing)
#                      interval :: int (seconds) }                 — every-N-sec
#                    | { calendar :: { systemd :: str (OnCalendar);
#                                      launchd :: attrs (StartCalendarInterval,
#                                        e.g. { Hour = 3; Minute = 0; }); } };
#                                     exactly one of interval / calendar;
#     persistent  ? true            — systemd Persistent= : run on next boot if
#                                     a scheduled run was missed while off;
#     randomizedDelaySec ? null (int) — systemd RandomizedDelaySec= (jitter);
#     environment ? { } (attrsOf str);
#     environmentFile ? null (str);
#     user        ? null (str);
#     group       ? null (str);
#     after       ? [ "network.target" ] — service ordering;
#     wants       ? [ ];
#     serviceConfigExtra ? { }      — raw serviceConfig passthrough (wins last);
#   } -> {
#     nixos :: class-tagged module (_class "nixos") —
#       options.<ns>.<name>.{ enable, …extraOptions };
#       config = mkIf cfg.enable {
#         systemd.services.<name> = {
#           inherit description;
#           after/wants (only non-empty);
#           environment (only when non-empty);
#           serviceConfig = { ExecStart, Type = "oneshot" }
#             // optional { EnvironmentFile, User, Group }
#             // serviceConfigExtra;
#         };
#         systemd.timers.<name> = {
#           inherit description;
#           wantedBy = [ "timers.target" ];
#           timerConfig =
#             { Persistent }
#             // (interval ? { OnBootSec = "<n>s"; OnUnitActiveSec = "<n>s"; }
#                 : { OnCalendar = <str>; })
#             // optional { RandomizedDelaySec };
#         };
#       };
#     darwin :: class-tagged module (_class "darwin") —
#       config = mkIf cfg.enable {
#         launchd.daemons.<name>.serviceConfig = {
#           ProgramArguments, RunAtLoad = false, KeepAlive = false,
#           StartInterval (int) | StartCalendarInterval (attrs),
#           EnvironmentVariables (when environment non-empty),
#         };
#       };
#       Tier-honest: launchd has no Persistent / RandomizedDelaySec / User
#       analog at this surface — only the load-bearing schedule + argv + env
#       fields cross over.
#     meta :: { name, optionPath, enablePath, kind = "scheduled-job",
#               scheduleKind = "interval"|"calendar" };
#   }
#
# Throws (every message prefixed "iroha.scheduled-job.mkScheduledJob: "):
#   - `name` / `description` missing;
#   - neither `execStart` nor `command` given, or BOTH given (ambiguous);
#   - `schedule` missing, not attrs, with both or neither of interval/calendar,
#     a non-int interval, or a malformed calendar (missing/typed-wrong
#     systemd / launchd halves);
#   - an Exec arg that is not a string/path/number (escapeSystemdExecArg).
{ lib }:
let
  core = import ./core.nix { inherit lib; };
  optionSurface = import ./option-surface.nix { inherit lib; };
  inherit (lib) optionalAttrs;

  # Vendored from nixpkgs nixos/lib/utils.nix escapeSystemdExecArg(s) (the same
  # transform daemon.nix / service-module.nix vendor — pure { lib } cannot
  # reach utils.nix; this is canonical nixpkgs semantics, not a fork). systemd
  # Exec lines are NOT a shell: toJSON emits the C-style escape subset, `%`
  # doubled to suppress specifier expansion, `$` doubled to suppress
  # environment substitution.
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
          throw "iroha.scheduled-job.mkScheduledJob: Exec arguments must be strings, paths, or numbers — got ${builtins.typeOf arg}."
      )
    );
  escapeSystemdExecArgs = lib.concatMapStringsSep " " escapeSystemdExecArg;

  mkScheduledJob =
    args:
    let
      name = args.name or (throw "iroha.scheduled-job.mkScheduledJob: `name` (str) is required.");
      description =
        args.description
          or (throw "iroha.scheduled-job.mkScheduledJob: `description` (str) is required.");
      namespace = args.namespace or "services";
      enable = args.enable or true;
      extraOptions = args.extraOptions or { };

      # ── exec line: exactly one of execStart / command ───────────────────
      hasExecStart = (args.execStart or null) != null;
      hasCommand = (args.command or null) != null;
      execStart =
        if hasExecStart && hasCommand then
          throw "iroha.scheduled-job.mkScheduledJob: takes exactly one of `execStart` (verbatim line) or `command` (+ `args`) — got both."
        else if hasExecStart then
          args.execStart
        else if hasCommand then
          escapeSystemdExecArgs ([ args.command ] ++ (args.args or [ ]))
        else
          throw "iroha.scheduled-job.mkScheduledJob: needs one of `execStart` (str) or `command` (str — absolute program path; the caller resolves the package).";

      # launchd ProgramArguments: prefer the structured argv (verbatim, no
      # escaping); fall back to a shell wrapper when only execStart is given (a
      # bare string cannot be word-split into an argv safely).
      programArguments =
        if hasCommand then
          [ args.command ] ++ (args.args or [ ])
        else
          [
            "/bin/sh"
            "-c"
            execStart
          ];

      environment = args.environment or { };
      environmentFile = args.environmentFile or null;
      user = args.user or null;
      group = args.group or null;
      after = args.after or [ "network.target" ];
      wants = args.wants or [ ];
      persistent = args.persistent or true;
      randomizedDelaySec = args.randomizedDelaySec or null;
      serviceConfigExtra = args.serviceConfigExtra or { };

      # ── schedule normalization (typed) ──────────────────────────────────
      # { interval = <int>; }                         -> { interval = <int>; }
      # { calendar = { systemd; launchd }; }          -> { calendar = …; }
      rawSchedule =
        args.schedule
          or (throw "iroha.scheduled-job.mkScheduledJob: `schedule` (required) must be { interval = <seconds :: int>; } or { calendar = { systemd = <OnCalendar str>; launchd = <StartCalendarInterval attrs>; }; }.");
      schedule =
        if !(builtins.isAttrs rawSchedule) then
          throw "iroha.scheduled-job.mkScheduledJob: `schedule` must be { interval = <seconds :: int>; } or { calendar = { systemd; launchd }; } — got ${builtins.typeOf rawSchedule}."
        else if rawSchedule ? interval && rawSchedule ? calendar then
          throw "iroha.scheduled-job.mkScheduledJob: `schedule` takes exactly one of `interval` or `calendar` — got both."
        else if rawSchedule ? interval then
          if builtins.isInt rawSchedule.interval then
            { inherit (rawSchedule) interval; }
          else
            throw "iroha.scheduled-job.mkScheduledJob: `schedule.interval` must be an int (seconds) — got ${builtins.typeOf rawSchedule.interval}."
        else if rawSchedule ? calendar then
          let
            cal = rawSchedule.calendar;
          in
          if !(builtins.isAttrs cal) then
            throw "iroha.scheduled-job.mkScheduledJob: `schedule.calendar` must be { systemd = <OnCalendar str>; launchd = <StartCalendarInterval attrs>; } — got ${builtins.typeOf cal}."
          else if !(cal ? systemd) || !(cal ? launchd) then
            throw "iroha.scheduled-job.mkScheduledJob: `schedule.calendar` needs both `systemd` (OnCalendar str) and `launchd` (StartCalendarInterval attrs) — this letter projects to both platforms."
          else if !(builtins.isString cal.systemd) then
            throw "iroha.scheduled-job.mkScheduledJob: `schedule.calendar.systemd` must be a systemd OnCalendar string — got ${builtins.typeOf cal.systemd}."
          else if !(builtins.isAttrs cal.launchd) then
            throw "iroha.scheduled-job.mkScheduledJob: `schedule.calendar.launchd` must be attrs (StartCalendarInterval shape) — got ${builtins.typeOf cal.launchd}."
          else
            {
              calendar = {
                inherit (cal) systemd launchd;
              };
            }
        else
          throw "iroha.scheduled-job.mkScheduledJob: `schedule` needs `interval` or `calendar` — got attrs with neither.";

      isInterval = schedule ? interval;
      scheduleKind = if isInterval then "interval" else "calendar";
      intervalSec = "${toString (schedule.interval or 0)}s";

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

      # ── systemd oneshot service (NixOS system) ──────────────────────────
      serviceConfig =
        {
          ExecStart = execStart;
          Type = "oneshot";
        }
        // optionalAttrs (environmentFile != null) { EnvironmentFile = environmentFile; }
        // optionalAttrs (user != null) { User = user; }
        // optionalAttrs (group != null) { Group = group; }
        // serviceConfigExtra;

      systemdService =
        {
          inherit description;
          inherit serviceConfig;
        }
        // optionalAttrs (after != [ ]) { inherit after; }
        // optionalAttrs (wants != [ ]) { inherit wants; }
        // optionalAttrs (environment != { }) { inherit environment; };

      # ── systemd timer (drives the oneshot service) ──────────────────────
      timerConfig =
        {
          Persistent = persistent;
        }
        // (
          if isInterval then
            {
              OnBootSec = intervalSec;
              OnUnitActiveSec = intervalSec;
            }
          else
            { OnCalendar = schedule.calendar.systemd; }
        )
        // optionalAttrs (randomizedDelaySec != null) { RandomizedDelaySec = randomizedDelaySec; };

      systemdTimer = {
        inherit description;
        wantedBy = [ "timers.target" ];
        inherit timerConfig;
      };

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
            systemd.timers.${name} = systemdTimer;
          };
        };

      # ── launchd (nix-darwin daemon) — minimal periodic projection ───────
      launchdServiceConfig =
        {
          ProgramArguments = programArguments;
          RunAtLoad = false;
          KeepAlive = false;
        }
        // (
          if isInterval then
            { StartInterval = schedule.interval; }
          else
            { StartCalendarInterval = schedule.calendar.launchd; }
        )
        // optionalAttrs (environment != { }) { EnvironmentVariables = environment; };

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
        inherit name optionPath enablePath scheduleKind;
        kind = "scheduled-job";
      };
    };
in
{
  inherit mkScheduledJob;
}
