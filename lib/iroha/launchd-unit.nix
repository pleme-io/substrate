# iroha.launchd-unit — L2: the PURE nix-darwin launchd unit renderer.
#
# The launchd analog of iroha.service-module's mkServiceUnit (systemd) and
# scheduled-job's mkScheduledUnit. Those render systemd attrs; this renders a
# nix-darwin `launchd.daemons.<name>` (or `.agents.<name>`) attrset from typed
# fields. A BESPOKE darwin module keeps its option surface + activation hooks
# and reaches for mkLaunchdUnit INSIDE its `config` block to farm only the
# repeating launchd unit SHAPE (Label / schedule / RunAtLoad / KeepAlive /
# std-paths / EnvironmentVariables / the exec form). nix-darwin's launchd
# idiom is UPSTREAM; this letter makes it a pleme-io-controlled vocabulary,
# consistent with the systemd letters.
#
# The exec form is EITHER the nix-darwin `command` shortcut (a top-level
# string nix-darwin splits into ProgramArguments — the caller owns escaping,
# typically via lib.escapeShellArgs) OR an explicit `programArguments` argv
# list (set as serviceConfig.ProgramArguments). Exactly one is required.
#
# Schedule is OPTIONAL (a launchd unit may be run-at-load-only, KeepAlive, or
# triggered): EITHER `startInterval` (int seconds -> StartInterval) OR
# `startCalendarInterval` (attrs / list-of-attrs -> StartCalendarInterval).
# At most one.
#
# Exports (pure { lib }, zero pkgs):
#
#   mkLaunchdUnit :: {
#     label :: str (required) — serviceConfig.Label (the launchd job label);
#     command ? null (str — nix-darwin top-level `command` shortcut) |
#       programArguments ? null (listOf str — serviceConfig.ProgramArguments);
#       exactly one;
#     startInterval ? null (int) | startCalendarInterval ? null (attrs|list);
#       at most one;
#     runAtLoad ? true (bool — serviceConfig.RunAtLoad);
#     keepAlive ? null (bool|attrs — serviceConfig.KeepAlive; omitted when null);
#     standardOutPath ? null (str); standardErrorPath ? null (str);
#     environment ? { } (attrsOf str — serviceConfig.EnvironmentVariables when
#       non-empty);
#     workingDirectory ? null (str — serviceConfig.WorkingDirectory);
#     serviceConfigExtra ? { } — raw serviceConfig passthrough (wins last);
#     daemonExtra ? { } — raw DAEMON-LEVEL passthrough (siblings of
#       serviceConfig — e.g. the `command` shortcut is itself daemon-level;
#       wins last);
#   } -> {
#     daemon :: launchd.daemons.<name> attrs
#       = (optional { command }) // { serviceConfig = { Label; RunAtLoad }
#           // optional { ProgramArguments, StartInterval|StartCalendarInterval,
#                         KeepAlive, StandardOutPath, StandardErrorPath,
#                         EnvironmentVariables, WorkingDirectory }
#           // serviceConfigExtra; } // daemonExtra;
#     scheduleKind :: "interval" | "calendar" | "none";
#   }
#
# Throws (prefixed "iroha.launchd-unit.mkLaunchdUnit: "):
#   - `label` missing;
#   - neither `command` nor `programArguments` given, or BOTH (ambiguous);
#   - BOTH `startInterval` and `startCalendarInterval` given;
#   - `startInterval` not an int.
{ lib }:
let
  inherit (lib) optionalAttrs;

  mkLaunchdUnit =
    args:
    let
      label = args.label or (throw "iroha.launchd-unit.mkLaunchdUnit: `label` (str) is required.");

      hasCommand = (args.command or null) != null;
      hasProgramArguments = (args.programArguments or null) != null;
      _execChecked =
        if hasCommand && hasProgramArguments then
          throw "iroha.launchd-unit.mkLaunchdUnit: takes exactly one of `command` (nix-darwin shortcut str) or `programArguments` (argv) — got both."
        else if !hasCommand && !hasProgramArguments then
          throw "iroha.launchd-unit.mkLaunchdUnit: needs one of `command` (str) or `programArguments` (listOf str)."
        else
          true;

      runAtLoad = args.runAtLoad or true;
      keepAlive = args.keepAlive or null;
      standardOutPath = args.standardOutPath or null;
      standardErrorPath = args.standardErrorPath or null;
      environment = args.environment or { };
      workingDirectory = args.workingDirectory or null;
      serviceConfigExtra = args.serviceConfigExtra or { };
      daemonExtra = args.daemonExtra or { };

      startInterval = args.startInterval or null;
      startCalendarInterval = args.startCalendarInterval or null;
      _scheduleChecked =
        if startInterval != null && startCalendarInterval != null then
          throw "iroha.launchd-unit.mkLaunchdUnit: takes at most one of `startInterval` or `startCalendarInterval` — got both."
        else if startInterval != null && !(builtins.isInt startInterval) then
          throw "iroha.launchd-unit.mkLaunchdUnit: `startInterval` must be an int (seconds) — got ${builtins.typeOf startInterval}."
        else
          true;
      scheduleKind =
        if startInterval != null then "interval" else if startCalendarInterval != null then "calendar" else "none";

      serviceConfig =
        {
          Label = label;
          RunAtLoad = runAtLoad;
        }
        // optionalAttrs hasProgramArguments { ProgramArguments = args.programArguments; }
        // optionalAttrs (startInterval != null) { StartInterval = startInterval; }
        // optionalAttrs (startCalendarInterval != null) { StartCalendarInterval = startCalendarInterval; }
        // optionalAttrs (keepAlive != null) { KeepAlive = keepAlive; }
        // optionalAttrs (standardOutPath != null) { StandardOutPath = standardOutPath; }
        // optionalAttrs (standardErrorPath != null) { StandardErrorPath = standardErrorPath; }
        // optionalAttrs (environment != { }) { EnvironmentVariables = environment; }
        // optionalAttrs (workingDirectory != null) { WorkingDirectory = workingDirectory; }
        // serviceConfigExtra;

      daemon =
        # seq the typed validations so a bad spec throws at construction.
        builtins.seq _execChecked (
          builtins.seq _scheduleChecked (
            optionalAttrs hasCommand { command = args.command; }
            // { inherit serviceConfig; }
            // daemonExtra
          )
        );
    in
    {
      inherit daemon scheduleKind;
    };
in
{
  inherit mkLaunchdUnit;
}
