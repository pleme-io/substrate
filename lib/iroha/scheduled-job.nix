# iroha.scheduled-job — L2: a SCHEDULED (periodic/cron-like) job MODULE emitter
#                         + the pure systemd-unit renderer it stands on.
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
# TWO exports, layered:
#
#   mkScheduledUnit — the PURE systemd-unit renderer (data -> data). Takes
#     already-resolved values (the caller owns the option surface + reads its
#     own cfg) and returns the two systemd attrsets:
#       { service :: systemd.services.<x>; timer :: systemd.timers.<x>;
#         programArguments :: argv; scheduleKind :: "interval"|"calendar"; }
#     This is the composable core: a BESPOKE module (one whose ExecStart /
#     schedule are FUNCTIONS of its own typed options — attic-store-push,
#     k3s-export, dns jobs) keeps its hand-authored option surface and reaches
#     for mkScheduledUnit INSIDE its `config` block to farm the repeating
#     systemd service+timer SHAPE (Type / serviceConfig composition /
#     timerConfig / Persistent / wantedBy / service-level passthrough) without
#     surrendering its knobs. Systemd-only (a NixOS-system unit renderer); its
#     `schedule` is the simple `{ interval = <int>; } | { calendar = <str>; }`.
#
#   mkScheduledJob — the FULL dual-platform MODULE wrapper. Composes
#     mkOptionSurface (enable + extraOptions) + core.tag for class tagging,
#     uses mkScheduledUnit for the NixOS systemd half, and adds the launchd
#     projection. The surface for jobs whose ExecStart + schedule are STATIC
#     at construction time. iroha.daemon ALSO covers periodic mode but emits
#     unit ATTRS (the dominant USER-level keep-alive pattern); this letter
#     emits a complete class-tagged MODULE for SYSTEM scheduled jobs.
#
# The dual schedule normalization (mkScheduledJob) mirrors daemon.nix exactly:
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
# only because its launchd-only projections can stand alone). The PURE
# mkScheduledUnit, by contrast, is systemd-only and so takes a bare
# `{ calendar = <OnCalendar str>; }` (no launchd half to demand).
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
# serviceConfigExtra merges into `serviceConfig` (wins last) — Type override,
# SyslogIdentifier, RuntimeMaxSec, hardening, … . serviceExtra merges onto the
# SERVICE-LEVEL attrs (siblings of serviceConfig, wins last) — `path`,
# `restartIfChanged`, `unitConfig`, … . Both default `{}` (behavior-neutral).
#
# COMPOSES iroha.mkOptionSurface for the enable + extraOptions skeleton
# (package = false, settings = null) and iroha.core.tag for class tagging.
#
# Exports (pure { lib }, zero pkgs — pkgs binds late as a module arg):
#
#   mkScheduledUnit :: {
#     description :: str (required);
#     execStart   ? null (str) | command ? null (str) + args ? [ ] (listOf str);
#                                     exactly one of execStart / command;
#     schedule    :: { interval :: int (seconds) }
#                  | { calendar :: str (systemd OnCalendar) };  (systemd-only)
#     persistent  ? true; randomizedDelaySec ? null (int);
#     environment ? { } (attrsOf str); environmentFile ? null (str);
#     user ? null (str); group ? null (str);
#     after ? [ "network.target" ] (listOf str); wants ? [ ] (listOf str);
#     serviceConfigExtra ? { }  — raw serviceConfig passthrough (wins last);
#     serviceExtra ? { }        — raw SERVICE-LEVEL passthrough (path,
#                                 restartIfChanged, unitConfig …; wins last);
#   } -> {
#     service :: systemd.services.<x> attrs
#       = { description; serviceConfig = { ExecStart; Type="oneshot"; }
#             // { EnvironmentFile?; User?; Group?; } // serviceConfigExtra; }
#         // { after?; wants?; environment?; } // serviceExtra;
#     timer   :: systemd.timers.<x> attrs
#       = { description; wantedBy=["timers.target"];
#           timerConfig = { Persistent }
#             // (interval ? { OnBootSec; OnUnitActiveSec } : { OnCalendar })
#             // { RandomizedDelaySec? }; };
#     programArguments :: argv (for a launchd projection);
#     scheduleKind :: "interval" | "calendar";
#   }
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
#     serviceExtra ? { }            — raw service-level passthrough (wins last);
#   } -> {
#     nixos :: class-tagged module (_class "nixos") —
#       options.<ns>.<name>.{ enable, …extraOptions };
#       config = mkIf cfg.enable {
#         systemd.services.<name> = <mkScheduledUnit … .service>;
#         systemd.timers.<name>   = <mkScheduledUnit … .timer>;
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
# Throws (every message prefixed "iroha.scheduled-job."):
#   - `name` / `description` missing;
#   - neither `execStart` nor `command` given, or BOTH given (ambiguous);
#   - `schedule` missing, not attrs, with both or neither of interval/calendar,
#     a non-int interval, or a malformed calendar (missing/typed-wrong
#     systemd / launchd halves; the bare systemd string for mkScheduledUnit);
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
          throw "iroha.scheduled-job: Exec arguments must be strings, paths, or numbers — got ${builtins.typeOf arg}."
      )
    );
  escapeSystemdExecArgs = lib.concatMapStringsSep " " escapeSystemdExecArg;

  # ── shared exec resolution (execStart XOR command + args) ─────────────
  # Returns the systemd ExecStart line + the launchd argv, or throws on a
  # missing / ambiguous spec. Used by BOTH mkScheduledUnit and mkScheduledJob.
  resolveExec =
    args:
    let
      hasExecStart = (args.execStart or null) != null;
      hasCommand = (args.command or null) != null;
    in
    if hasExecStart && hasCommand then
      throw "iroha.scheduled-job: takes exactly one of `execStart` (verbatim line) or `command` (+ `args`) — got both."
    else if hasExecStart then
      {
        execStart = args.execStart;
        programArguments = [
          "/bin/sh"
          "-c"
          args.execStart
        ];
      }
    else if hasCommand then
      let
        argv = [ args.command ] ++ (args.args or [ ]);
      in
      {
        execStart = escapeSystemdExecArgs argv;
        programArguments = argv;
      }
    else
      throw "iroha.scheduled-job: needs one of `execStart` (str) or `command` (str — absolute program path; the caller resolves the package).";

  # ── PURE systemd-unit renderer (data -> { service, timer }) ───────────
  mkScheduledUnit =
    args:
    let
      description =
        args.description
          or (throw "iroha.scheduled-job.mkScheduledUnit: `description` (str) is required.");
      exec = resolveExec args;
      environment = args.environment or { };
      environmentFile = args.environmentFile or null;
      user = args.user or null;
      group = args.group or null;
      after = args.after or [ "network.target" ];
      wants = args.wants or [ ];
      persistent = args.persistent or true;
      randomizedDelaySec = args.randomizedDelaySec or null;
      serviceConfigExtra = args.serviceConfigExtra or { };
      serviceExtra = args.serviceExtra or { };

      # systemd-only schedule: { interval = <int>; } | { calendar = <str>; }
      rawSchedule =
        args.schedule
          or (throw "iroha.scheduled-job.mkScheduledUnit: `schedule` (required) must be { interval = <seconds :: int>; } or { calendar = <OnCalendar str>; }.");
      schedule =
        if !(builtins.isAttrs rawSchedule) then
          throw "iroha.scheduled-job.mkScheduledUnit: `schedule` must be { interval = <int>; } or { calendar = <OnCalendar str>; } — got ${builtins.typeOf rawSchedule}."
        else if rawSchedule ? interval && rawSchedule ? calendar then
          throw "iroha.scheduled-job.mkScheduledUnit: `schedule` takes exactly one of `interval` or `calendar` — got both."
        else if rawSchedule ? interval then
          if builtins.isInt rawSchedule.interval then
            { inherit (rawSchedule) interval; }
          else
            throw "iroha.scheduled-job.mkScheduledUnit: `schedule.interval` must be an int (seconds) — got ${builtins.typeOf rawSchedule.interval}."
        else if rawSchedule ? calendar then
          if builtins.isString rawSchedule.calendar then
            { inherit (rawSchedule) calendar; }
          else
            throw "iroha.scheduled-job.mkScheduledUnit: `schedule.calendar` must be a systemd OnCalendar string — got ${builtins.typeOf rawSchedule.calendar}."
        else
          throw "iroha.scheduled-job.mkScheduledUnit: `schedule` needs `interval` or `calendar` — got attrs with neither.";

      isInterval = schedule ? interval;
      intervalSec = "${toString (schedule.interval or 0)}s";

      serviceConfig =
        {
          ExecStart = exec.execStart;
          Type = "oneshot";
        }
        // optionalAttrs (environmentFile != null) { EnvironmentFile = environmentFile; }
        // optionalAttrs (user != null) { User = user; }
        // optionalAttrs (group != null) { Group = group; }
        // serviceConfigExtra;

      service =
        {
          inherit description;
          inherit serviceConfig;
        }
        // optionalAttrs (after != [ ]) { inherit after; }
        // optionalAttrs (wants != [ ]) { inherit wants; }
        // optionalAttrs (environment != { }) { inherit environment; }
        // serviceExtra;

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
            { OnCalendar = schedule.calendar; }
        )
        // optionalAttrs (randomizedDelaySec != null) { RandomizedDelaySec = randomizedDelaySec; };

      timer = {
        inherit description;
        wantedBy = [ "timers.target" ];
        inherit timerConfig;
      };
    in
    {
      inherit service timer;
      inherit (exec) programArguments;
      scheduleKind = if isInterval then "interval" else "calendar";
    };

  # ── FULL dual-platform module wrapper ─────────────────────────────────
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

      # ── dual schedule normalization (typed; requires both halves for the
      #    calendar form, since this wrapper projects to BOTH platforms) ──
      rawSchedule =
        args.schedule
          or (throw "iroha.scheduled-job.mkScheduledJob: `schedule` (required) must be { interval = <seconds :: int>; } or { calendar = { systemd = <OnCalendar str>; launchd = <StartCalendarInterval attrs>; }; }.");
      dualSchedule =
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

      isInterval = dualSchedule ? interval;
      scheduleKind = if isInterval then "interval" else "calendar";

      # project the dual schedule down to the systemd-only form the pure
      # renderer consumes.
      systemdSchedule =
        if isInterval then
          { inherit (dualSchedule) interval; }
        else
          { calendar = dualSchedule.calendar.systemd; };

      unit = mkScheduledUnit {
        inherit description;
        schedule = systemdSchedule;
        execStart = args.execStart or null;
        command = args.command or null;
        args = args.args or [ ];
        environment = args.environment or { };
        environmentFile = args.environmentFile or null;
        user = args.user or null;
        group = args.group or null;
        after = args.after or [ "network.target" ];
        wants = args.wants or [ ];
        persistent = args.persistent or true;
        randomizedDelaySec = args.randomizedDelaySec or null;
        serviceConfigExtra = args.serviceConfigExtra or { };
        serviceExtra = args.serviceExtra or { };
      };

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
            systemd.services.${name} = unit.service;
            systemd.timers.${name} = unit.timer;
          };
        };

      # ── launchd (nix-darwin daemon) — minimal periodic projection ───────
      launchdServiceConfig =
        {
          ProgramArguments = unit.programArguments;
          RunAtLoad = false;
          KeepAlive = false;
        }
        // (
          if isInterval then
            { StartInterval = dualSchedule.interval; }
          else
            { StartCalendarInterval = dualSchedule.calendar.launchd; }
        )
        // optionalAttrs ((args.environment or { }) != { }) { EnvironmentVariables = args.environment; };

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
  inherit mkScheduledUnit mkScheduledJob;
}
