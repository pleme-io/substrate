# iroha.service-module — L2: a full SYSTEM-class service MODULE emitter
#                          + the pure systemd keep-alive unit renderer it
#                          stands on.
#
# iroha.daemon (the L2 sibling) emits unit ATTRS for the dominant
# user-level keep-alive/periodic pattern and EXPLICITLY excludes the
# root/system power fields (Type=notify, EnvironmentFile, StateDirectory,
# RuntimeDirectory, User/Group, hardening, ExecStartPre/Post, oneshot
# RemainAfterExit, …). This letter is the missing surface those ~50 fleet
# files reach for: it emits a complete class-tagged MODULE — an option
# surface (enable + caller-typed extras) plus a full system
# `systemd.services.<name>` (NixOS) and a minimal `launchd.daemons.<name>`
# (nix-darwin) projection that DO carry those fields.
#
# TWO exports, layered (mirroring scheduled-job's mkScheduledUnit/mkScheduledJob):
#
#   mkServiceUnit — the PURE keep-alive systemd-service renderer (data ->
#     data). Takes already-resolved values (the caller owns the option
#     surface + reads its own cfg) and returns:
#       { service :: systemd.services.<x>; programArguments :: argv; }
#     This is the composable core: a BESPOKE module (one whose ExecStart is a
#     function of its own options + a generated config file, AND which emits
#     extra config — tmpfiles, home-manager bridges — alongside the unit;
#     toride-system, dns-split-horizon, vaultwarden) keeps its hand-authored
#     option surface + extra config and reaches for mkServiceUnit INSIDE its
#     `config` block to farm only the repeating system-service SHAPE
#     (serviceConfig composition / Type / Restart / hardening / ordering /
#     service-level passthrough) without surrendering its knobs. Systemd-only.
#
#   mkServiceModule — the FULL dual-platform MODULE wrapper. Composes
#     mkOptionSurface (enable + extraOptions) + core.tag for class tagging,
#     uses mkServiceUnit for the NixOS systemd half, and adds the launchd
#     projection. The surface for services whose ExecStart is STATIC at
#     construction time. It does NOT emit a package option (system services
#     run absolute paths the caller resolves) and it does NOT emit a
#     home-manager projection (these are system units).
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
# hardening + serviceConfigExtra merge INTO serviceConfig (wins last).
# serviceExtra merges onto the SERVICE-LEVEL attrs (siblings of serviceConfig
# — path, restartIfChanged, unitConfig; wins last). All default `{}`.
#
# COMPOSES iroha.mkOptionSurface for the enable + extraOptions skeleton
# (package = false, settings = null) and iroha.core.tag for class tagging.
#
# Exports (pure { lib }, zero pkgs — pkgs binds late as a module arg):
#
#   mkServiceUnit :: {
#     description :: str (required);
#     execStart   ? null (str) | command ? null (str) + args ? [ ] (listOf str);
#                                  exactly one of execStart / command;
#     type        ? "simple"   — any systemd Type: simple|exec|forking|oneshot|
#                                 dbus|notify|notify-reload|idle;
#     wants ? [ ]; requires ? [ ]; after ? [ "network.target" ]; before ? [ ];
#     environment ? { } (attrsOf str); environmentFile ? null (str);
#     stateDirectory ? null; runtimeDirectory ? null; workingDirectory ? null;
#     user ? null; group ? null;
#     restart ? "on-failure" (null OMITS Restart — a no-retry oneshot);
#     restartSec ? null (int|str); remainAfterExit ? null;
#     execStartPre ? [ ]; execStartPost ? [ ];
#     wantedBy ? [ "multi-user.target" ];
#     hardening ? { }; serviceConfigExtra ? { }; serviceExtra ? { };
#   } -> { service :: systemd.services.<x> attrs; programArguments :: argv; }
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
#     service     :: { … the mkServiceUnit spec fields above (minus
#                       description, which comes from the top-level arg) … };
#   } -> {
#     nixos :: class-tagged module (_class "nixos") —
#       options.<ns>.<name>.{ enable, …extraOptions };
#       config = mkIf cfg.enable { systemd.services.<name> = <unit.service>; };
#     darwin :: class-tagged module (_class "darwin") —
#       config = mkIf cfg.enable {
#         launchd.daemons.<name>.serviceConfig = {
#           ProgramArguments, KeepAlive = (type != "oneshot"), RunAtLoad = true,
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
# Throws (every message prefixed "iroha.service-module."):
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
          throw "iroha.service-module: Exec arguments must be strings, paths, or numbers — got ${builtins.typeOf arg}."
      )
    );
  escapeSystemdExecArgs = lib.concatMapStringsSep " " escapeSystemdExecArg;

  # The complete systemd `Type=` enum (was a 4-subset; widened to the full set
  # so the letter covers every real fleet unit — reconverge is Type=exec).
  validTypes = [
    "simple"
    "exec"
    "forking"
    "oneshot"
    "dbus"
    "notify"
    "notify-reload"
    "idle"
  ];

  # ── shared exec resolution (execStart XOR command + args) ─────────────
  resolveExec =
    spec:
    let
      hasExecStart = (spec.execStart or null) != null;
      hasCommand = (spec.command or null) != null;
    in
    if hasExecStart && hasCommand then
      throw "iroha.service-module: takes exactly one of `execStart` (verbatim line) or `command` (+ `args`) — got both."
    else if hasExecStart then
      {
        execStart = spec.execStart;
        programArguments = [
          "/bin/sh"
          "-c"
          spec.execStart
        ];
      }
    else if hasCommand then
      let
        argv = [ spec.command ] ++ (spec.args or [ ]);
      in
      {
        execStart = escapeSystemdExecArgs argv;
        programArguments = argv;
      }
    else
      throw "iroha.service-module: needs one of `execStart` (str) or `command` (str — absolute program path; the caller resolves the package).";

  # ── PURE keep-alive systemd-service renderer (data -> { service }) ────
  mkServiceUnit =
    spec:
    let
      description =
        spec.description
          or (throw "iroha.service-module.mkServiceUnit: `description` (str) is required.");
      exec = resolveExec spec;

      type = spec.type or "simple";
      _typeChecked =
        if builtins.elem type validTypes then
          type
        else
          throw "iroha.service-module: `type` must be one of ${lib.concatStringsSep ", " validTypes} — got '${toString type}'.";

      wants = spec.wants or [ ];
      requires = spec.requires or [ ];
      after = spec.after or [ "network.target" ];
      before = spec.before or [ ];
      environment = spec.environment or { };
      environmentFile = spec.environmentFile or null;
      stateDirectory = spec.stateDirectory or null;
      runtimeDirectory = spec.runtimeDirectory or null;
      workingDirectory = spec.workingDirectory or null;
      user = spec.user or null;
      group = spec.group or null;
      restart = spec.restart or "on-failure";
      restartSec = spec.restartSec or null;
      remainAfterExit = spec.remainAfterExit or null;
      execStartPre = spec.execStartPre or [ ];
      execStartPost = spec.execStartPost or [ ];
      wantedBy = spec.wantedBy or [ "multi-user.target" ];
      hardening = spec.hardening or { };
      serviceConfigExtra = spec.serviceConfigExtra or { };
      serviceExtra = spec.serviceExtra or { };

      serviceConfig =
        {
          ExecStart = exec.execStart;
          Type = _typeChecked;
        }
        # Restart defaults to "on-failure"; pass `restart = null` to OMIT it
        # entirely (a oneshot that must run exactly once, no retry —
        # k3s-kubeconfig-export). The default is unchanged for keep-alive units.
        // optionalAttrs (restart != null) { Restart = restart; }
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

      service =
        {
          inherit description;
          inherit serviceConfig;
        }
        // optionalAttrs (wants != [ ]) { inherit wants; }
        // optionalAttrs (requires != [ ]) { inherit requires; }
        // optionalAttrs (after != [ ]) { inherit after; }
        // optionalAttrs (before != [ ]) { inherit before; }
        // optionalAttrs (wantedBy != [ ]) { inherit wantedBy; }
        // optionalAttrs (environment != { }) { inherit environment; }
        // serviceExtra;
    in
    {
      inherit service;
      inherit (exec) programArguments;
      darwinKeepAlive = type != "oneshot";
    };

  # ── FULL dual-platform module wrapper ─────────────────────────────────
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

      unit = mkServiceUnit (service // { inherit description; });

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
          };
        };

      # ── launchd (nix-darwin daemon) — minimal projection ────────────────
      launchdServiceConfig =
        {
          ProgramArguments = unit.programArguments;
          KeepAlive = unit.darwinKeepAlive;
          RunAtLoad = true;
        }
        // optionalAttrs ((service.environment or { }) != { }) { EnvironmentVariables = service.environment; }
        // optionalAttrs ((service.workingDirectory or null) != null) { WorkingDirectory = service.workingDirectory; };

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
  inherit mkServiceUnit mkServiceModule;
}
