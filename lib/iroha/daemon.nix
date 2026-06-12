# iroha.daemon — L2: one daemon spec, four platform projections.
#
# Unifies the four service-helper dialects (hm/service-helpers.nix
# mkSystemdService/mkLaunchdService + their periodic-task variants,
# hm/nixos-service-helpers.nix mkNixOSService, hm/darwin-service-helpers.nix
# mkLaunchdDaemon/mkLaunchdPeriodicDaemon/mkLaunchdScheduledDaemon) into a
# single typed shape projected onto systemd (NixOS system), systemd --user
# (home-manager), launchd daemons (nix-darwin) and launchd agents
# (home-manager). The mapped semantics: keepAlive maps to systemd
# Restart="always" vs launchd KeepAlive=true; a schedule turns the
# unit into a periodic job (oneshot service + timer on systemd,
# StartInterval/StartCalendarInterval with KeepAlive=false + RunAtLoad=false
# on launchd) instead of a keep-alive daemon; env becomes systemd
# `environment` attrs, HM "K=V" Environment list entries, and launchd
# EnvironmentVariables; logDir feeds launchd StandardOutPath/StandardErrorPath
# while the systemd projections ignore it (the journal owns logs).
#
# SCOPE (tier-honest): this letter covers the simple-daemon subset — the
# dominant fleet pattern (user-level keep-alive daemons + periodic jobs).
# Power fields for root/notify-class daemons (Type=notify, Delegate,
# KillMode, RestartSec, wants/requires, EnvironmentFile, resource limits,
# launchd UserName/ProcessType/Label) are NOT first-class spec fields yet;
# pass them through the typed escape hatches below (`systemdExtra`,
# `systemdUserExtra`, `launchdExtra`), or keep using the canonical helpers
# (hm/nixos-service-helpers.nix mkNixOSService for k3s-class system daemons,
# hm/darwin-service-helpers.nix mkLaunchdDaemon for full plists) until the
# fields are promoted here. Promotion trigger: third spec'd consumer.
#
# Exec-line escaping: systemd Exec lines are NOT a shell — `%` specifier
# expansion and `$` environment substitution apply before word splitting,
# and quoting does not protect them. The systemd projections therefore use
# the nixpkgs escapeSystemdExecArg transform (toJSON + %%/$$ doubling,
# vendored below because this file is pure { lib }), never shell escaping.
# launchd ProgramArguments stays a verbatim argv list (no escaping needed).
#
# Exports (pure { lib }, zero pkgs — the caller resolves packages and passes
# an absolute `command` path, e.g. "${pkg}/bin/tend"):
#
#   mkDaemonUnit :: {
#     name        :: str (required) — the unit name on every platform;
#     description ? name;
#     command     :: str (required) — absolute program path;
#     args        ? [ ]   (listOf str);
#     env         ? { }   (attrsOf str);
#     keepAlive   ? true  — restart-forever daemon vs exit-tolerated service;
#     workingDir  ? null  (nullOr str);
#     schedule    ? null  — null = long-running daemon;
#                   { interval :: int (seconds) } = periodic, all platforms;
#                   { calendar :: dual | bare }   = periodic at calendar
#                     times, where
#                       dual = { launchd :: attrs (StartCalendarInterval
#                                shape, e.g. { Hour = 3; Minute = 0; });
#                                systemd :: str (OnCalendar expression); }
#                              — every projection works;
#                       bare = launchd-shaped attrs, used verbatim by the
#                              launchd projections; forcing systemdTimer /
#                              systemdUserTimer THROWS a typed error asking
#                              for the dual form (the systemd/systemdUser
#                              service halves remain valid oneshot units —
#                              only the timers need the OnCalendar string);
#     after       ? [ "network.target" ]  (system-systemd ordering; the
#                   systemd --user projection only emits After when the
#                   caller passes `after` explicitly — network.target does
#                   not exist in the user instance, so a default there
#                   would be a silent no-op);
#     logDir      ? null  (nullOr str) — when set, launchd projections write
#                   "<logDir>/<name>.log" / "<logDir>/<name>.err";
#     systemdExtra     ? { } — merged into systemd serviceConfig (typed
#                   escape hatch for Type/Delegate/KillMode/RestartSec/...);
#     systemdUserExtra ? { } — merged into the HM Service section;
#     launchdExtra     ? { } — merged into launchd serviceConfig
#                   (UserName/ProcessType/Label/limits/...);
#   } -> {
#     systemd          :: attrs — NixOS systemd.services.<name> value:
#                        { description, after, environment (only when
#                          env != {}), serviceConfig = { ExecStart =
#                          systemd-escaped ([command] ++ args), Restart =
#                          "always"|"on-failure", WorkingDirectory? } } plus
#                          wantedBy = ["multi-user.target"]; periodic mode
#                          instead sets serviceConfig.Type = "oneshot" with
#                          NO Restart and NO wantedBy (the timer drives it);
#     systemdTimer     :: null | NixOS systemd.timers.<name> value:
#                        { wantedBy = ["timers.target"], timerConfig =
#                          { OnBootSec/OnUnitActiveSec = "<n>s" } for
#                          interval, { OnCalendar = <str> } for calendar };
#     systemdUser      :: attrs — HM systemd.user.services.<name> shape:
#                        { Unit = { Description, After? }, Service =
#                          { ExecStart, Restart?, Environment = ["K=V" ...]
#                            when env != {}, WorkingDirectory?, Type =
#                            "oneshot" for periodic }, Install.WantedBy =
#                          ["default.target"] (omitted for periodic) };
#     systemdUserTimer :: null | HM systemd.user.timers.<name> shape:
#                        { Unit.Description, Timer = { OnBootSec/
#                          OnUnitActiveSec or OnCalendar },
#                          Install.WantedBy = ["timers.target"] };
#     launchdDaemon    :: attrs — nix-darwin launchd.daemons.<name> value:
#                        { serviceConfig = { ProgramArguments = [command] ++
#                          args, KeepAlive, RunAtLoad = true,
#                          EnvironmentVariables when env != {},
#                          WorkingDirectory?, StandardOutPath/
#                          StandardErrorPath when logDir, StartInterval (int)
#                          | StartCalendarInterval (attrs) for periodic } };
#                          periodic mode: KeepAlive = false, RunAtLoad =
#                          false;
#     launchdAgent     :: attrs — HM launchd.agents.<name> value:
#                        { enable = true; config = <launchdDaemon
#                          .serviceConfig, same attrset>; };
#     meta             :: { name, kind = "daemon" | "periodic" };
#   }
#
# Throws (every message prefixed "iroha.daemon.mkDaemonUnit: "):
#   - `name` or `command` missing;
#   - `schedule` not null/attrs, with both or neither of interval/calendar,
#     or a non-int interval;
#   - `schedule.calendar` neither bare attrs nor a well-formed dual
#     { launchd :: attrs; systemd :: str; };
#   - forcing systemdTimer / systemdUserTimer of a bare-calendar unit.
{ lib }:
let
  inherit (lib) optionalAttrs mapAttrsToList;

  # Vendored from nixpkgs nixos/lib/utils.nix escapeSystemdExecArg(s) —
  # this file is pure { lib } and cannot reach utils.nix. systemd parses
  # Exec lines with C-style escapes (toJSON emits a subset), `%` must be
  # doubled to suppress specifier expansion, `$` doubled to suppress
  # environment substitution. Shell escaping (escapeShellArgs) is WRONG
  # here — systemd is not sh.
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
          throw "iroha.daemon.mkDaemonUnit: Exec arguments must be strings, paths, or numbers — got ${builtins.typeOf arg}."
      )
    );
  escapeSystemdExecArgs = lib.concatMapStringsSep " " escapeSystemdExecArg;

  mkDaemonUnit =
    spec:
    let
      name = spec.name or (throw "iroha.daemon.mkDaemonUnit: `name` (str) is required.");
      description = spec.description or name;
      command =
        spec.command
          or (throw "iroha.daemon.mkDaemonUnit: `command` (str — absolute program path; the caller resolves the package) is required.");
      args = spec.args or [ ];
      env = spec.env or { };
      keepAlive = spec.keepAlive or true;
      workingDir = spec.workingDir or null;
      after = spec.after or [ "network.target" ];
      afterExplicit = spec ? after;
      logDir = spec.logDir or null;
      systemdExtra = spec.systemdExtra or { };
      systemdUserExtra = spec.systemdUserExtra or { };
      launchdExtra = spec.launchdExtra or { };
      rawSchedule = spec.schedule or null;

      # ── schedule normalization (typed) ──────────────────────────────────
      # null                      -> null                          (daemon)
      # { interval = <int>; }     -> { interval = <int>; }         (periodic)
      # { calendar = <dual|bare>; } -> { calendar = { launchd = <attrs>;
      #                                  systemd = <str|null>; }; } (periodic;
      #                                  systemd = null marks the bare form)
      schedule =
        if rawSchedule == null then
          null
        else if !(builtins.isAttrs rawSchedule) then
          throw "iroha.daemon.mkDaemonUnit: `schedule` must be null, { interval = <seconds :: int>; }, or { calendar = <dual|bare>; } — got ${builtins.typeOf rawSchedule}."
        else if rawSchedule ? interval && rawSchedule ? calendar then
          throw "iroha.daemon.mkDaemonUnit: `schedule` takes exactly one of `interval` or `calendar` — got both."
        else if rawSchedule ? interval then
          if builtins.isInt rawSchedule.interval then
            { inherit (rawSchedule) interval; }
          else
            throw "iroha.daemon.mkDaemonUnit: `schedule.interval` must be an int (seconds) — got ${builtins.typeOf rawSchedule.interval}."
        else if rawSchedule ? calendar then
          let
            cal = rawSchedule.calendar;
            isDual = builtins.isAttrs cal && cal ? launchd && cal ? systemd;
          in
          if !(builtins.isAttrs cal) then
            throw "iroha.daemon.mkDaemonUnit: `schedule.calendar` must be attrs — either bare launchd StartCalendarInterval shape, or the dual form { launchd = <attrs>; systemd = <OnCalendar str>; } — got ${builtins.typeOf cal}."
          else if isDual then
            if !(builtins.isAttrs cal.launchd) then
              throw "iroha.daemon.mkDaemonUnit: dual `schedule.calendar.launchd` must be attrs (StartCalendarInterval shape) — got ${builtins.typeOf cal.launchd}."
            else if !(builtins.isString cal.systemd) then
              throw "iroha.daemon.mkDaemonUnit: dual `schedule.calendar.systemd` must be a systemd OnCalendar string — got ${builtins.typeOf cal.systemd}."
            else
              {
                calendar = {
                  inherit (cal) launchd systemd;
                };
              }
          else
            {
              calendar = {
                launchd = cal;
                systemd = null; # bare form: no systemd projection available
              };
            }
        else
          throw "iroha.daemon.mkDaemonUnit: `schedule` needs `interval` or `calendar` — got attrs with neither.";

      isPeriodic = schedule != null;

      bareCalendarThrow =
        projection:
        throw "iroha.daemon.mkDaemonUnit: schedule.calendar is launchd-shaped (bare attrs) — the ${projection} projection needs the dual form { launchd = <attrs>; systemd = \"<OnCalendar string>\"; }.";

      execStart = escapeSystemdExecArgs ([ command ] ++ args);

      intervalSec = "${toString schedule.interval}s";

      # ── systemd (NixOS system) ──────────────────────────────────────────
      systemd =
        {
          inherit description after;
          serviceConfig =
            {
              ExecStart = execStart;
            }
            // optionalAttrs (!isPeriodic) {
              Restart = if keepAlive then "always" else "on-failure";
            }
            // optionalAttrs isPeriodic { Type = "oneshot"; }
            // optionalAttrs (workingDir != null) { WorkingDirectory = workingDir; }
            // systemdExtra;
        }
        // optionalAttrs (env != { }) { environment = env; }
        // optionalAttrs (!isPeriodic) { wantedBy = [ "multi-user.target" ]; };

      systemdTimer =
        if !isPeriodic then
          null
        else if schedule ? interval then
          {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = intervalSec;
              OnUnitActiveSec = intervalSec;
            };
          }
        else if schedule.calendar.systemd == null then
          bareCalendarThrow "systemdTimer"
        else
          {
            wantedBy = [ "timers.target" ];
            timerConfig.OnCalendar = schedule.calendar.systemd;
          };

      # ── systemd --user (home-manager) ───────────────────────────────────
      systemdUser =
        {
          Unit = {
            Description = description;
          }
          # User-instance ordering only when the caller asked for it: the
          # default network.target does not exist in systemd --user and
          # would be a silently-inert dependency.
          // optionalAttrs (afterExplicit && after != [ ]) { After = after; };
          Service =
            {
              ExecStart = execStart;
            }
            // optionalAttrs (!isPeriodic) {
              Restart = if keepAlive then "always" else "on-failure";
            }
            // optionalAttrs isPeriodic { Type = "oneshot"; }
            // optionalAttrs (env != { }) { Environment = mapAttrsToList (k: v: "${k}=${v}") env; }
            // optionalAttrs (workingDir != null) { WorkingDirectory = workingDir; }
            // systemdUserExtra;
        }
        // optionalAttrs (!isPeriodic) { Install.WantedBy = [ "default.target" ]; };

      systemdUserTimer =
        if !isPeriodic then
          null
        else if schedule ? interval then
          {
            Unit.Description = "${description} timer";
            Timer = {
              OnBootSec = intervalSec;
              OnUnitActiveSec = intervalSec;
            };
            Install.WantedBy = [ "timers.target" ];
          }
        else if schedule.calendar.systemd == null then
          bareCalendarThrow "systemdUserTimer"
        else
          {
            Unit.Description = "${description} timer";
            Timer.OnCalendar = schedule.calendar.systemd;
            Install.WantedBy = [ "timers.target" ];
          };

      # ── launchd (nix-darwin daemons + home-manager agents) ──────────────
      launchdServiceConfig =
        {
          ProgramArguments = [ command ] ++ args;
          KeepAlive = if isPeriodic then false else keepAlive;
          RunAtLoad = !isPeriodic;
        }
        // optionalAttrs (env != { }) { EnvironmentVariables = env; }
        // optionalAttrs (workingDir != null) { WorkingDirectory = workingDir; }
        // optionalAttrs (logDir != null) {
          StandardOutPath = "${logDir}/${name}.log";
          StandardErrorPath = "${logDir}/${name}.err";
        }
        // optionalAttrs (isPeriodic && schedule ? interval) { StartInterval = schedule.interval; }
        // optionalAttrs (isPeriodic && schedule ? calendar) {
          StartCalendarInterval = schedule.calendar.launchd;
        }
        // launchdExtra;

      launchdDaemon = {
        serviceConfig = launchdServiceConfig;
      };

      launchdAgent = {
        enable = true;
        config = launchdServiceConfig;
      };

      meta = {
        inherit name;
        kind = if isPeriodic then "periodic" else "daemon";
      };
    in
    {
      inherit
        systemd
        systemdTimer
        systemdUser
        systemdUserTimer
        launchdDaemon
        launchdAgent
        meta
        ;
    };
in
{
  inherit mkDaemonUnit;
}
