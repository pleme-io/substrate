# iroha.resource-policy — L2: a typed CPU/memory/IO/task resource ENVELOPE
# rendered onto one or more systemd units, with eval-time assertions that
# the budget is sane.
#
# Node-budget breathe-L2 carving and sshd-survivability resource control
# share one shape: "hold THESE units inside THIS resource envelope —
# CPUQuota / CPUWeight / MemoryMax / MemoryHigh / TasksMax / IOWeight /
# AllowedCPUs / OOMScoreAdjust — and refuse a budget that is structurally
# nonsense (a TasksMax of 0, a CPUWeight outside systemd's 1..10000 band,
# a MemoryHigh above its MemoryMax)." iroha.service-module emits a WHOLE
# unit (ExecStart + lifecycle + hardening); this letter emits ONLY the
# resource-control serviceConfig keys for units OTHER modules already
# declare (sshd.service, a breathe-carved workload), overlaying them via
# `systemd.services.<unit>.serviceConfig`. It is the resource-envelope
# sibling of config-owner: config-owner authoritatively SETS a contended
# leaf; this letter renders a typed budget onto units + asserts sanity.
#
# Only NON-NULL fields are emitted — an unset envelope key never lands a
# `null` in serviceConfig (so the unit's own value, or systemd's default,
# survives). `cpuQuota` accepts an int (percent, rendered "<n>%") OR a
# verbatim string ("75%", or a multi-CPU "200%"); a string passes through
# untouched. Every other numeric field lands as authored.
#
# The sanity assertions are emitted as config.assertions (NixOS) — they
# are BEST-EFFORT eval-time checks, tier-honest mitigation not
# unrepresentability: a too-large CPUWeight is caught by a `Result::Err`-
# class assertion at build, not made unconstructible by the type. Per
# unit: TasksMax > 0 when set; CPUWeight in 1..10000 when set; IOWeight in
# 1..10000 when set; and MemoryHigh <= MemoryMax when BOTH are numeric-
# parseable (a "2G"/"1G" pair compares; an un-parseable pair is skipped,
# not failed — the parse is conservative).
#
# COMPOSES iroha.mkOptionSurface for the enable + extraOptions skeleton
# (package = false, settings = null) and iroha.core.tag for class tagging.
# pkgs never appears at import time — it binds late as a module argument.
# Darwin has no systemd resource-control analog, so NO darwin projection
# is emitted (launchd cannot express CPUQuota/MemoryMax/cgroup weights);
# the letter is NixOS-only by construction.
#
# Exports (pure { lib }, zero pkgs):
#
#   mkResourcePolicy :: {
#     name        :: str (required) — policy name + last option-path segment;
#     description :: str (required) — human description (enable option text);
#     namespace   ? "systemd"       — dotted option root; the option lands at
#                                     <namespace>.<name>;
#     enable      ? true            — whether the envelope is applied (the
#                                     enable option's default); when false the
#                                     serviceConfig overlay + assertions are
#                                     absent;
#     extraOptions ? { } | (lib -> attrs) — extra typed option declarations
#                                     merged under the option root (function
#                                     form receives lib);
#     units       :: attrsOf unitPolicy (required, non-empty) — keyed by the
#                                     systemd unit name (e.g. "sshd"); each
#                                     value is a unitPolicy. Typed throw if
#                                     missing, not an attrset, or empty;
#       unitPolicy = {
#         cpuQuota   ? null — str ("50%", "200%") | int (percent -> "<n>%");
#         cpuWeight  ? null — int (systemd 1..10000; asserted);
#         memoryMin  ? null — str ("64M") | int (bytes); a protected floor;
#         memoryMax  ? null — str ("2G") | int (bytes);
#         memoryHigh ? null — str ("1G") | int (bytes); asserted <= memoryMax
#                             when both numeric-parseable;
#         tasksMax   ? null — int (> 0; asserted);
#         ioWeight   ? null — int (systemd 1..10000; asserted);
#         allowedCPUs ? null — str cpuset ("0-3", "0,2");
#         oomScoreAdjust ? null — int (-1000..1000 per kernel; passed verbatim);
#       };
#   } -> {
#     nixos :: class-tagged module (_class "nixos") —
#       options.<ns>.<name>.{ enable, …extraOptions };
#       config = mkIf cfg.enable {
#         systemd.services = <per unit name: { serviceConfig =
#           { CPUQuota?; CPUWeight?; MemoryMax?; MemoryHigh?; TasksMax?;
#             IOWeight?; AllowedCPUs?; OOMScoreAdjust?; } — only NON-NULL
#           fields }; };
#         assertions = <per unit: tasksMax>0; cpuWeight in 1..10000;
#           ioWeight in 1..10000; memoryHigh<=memoryMax when parseable>;
#       };
#     meta :: { name; optionPath; enablePath; unitCount; kind = "resource-policy"; };
#   }
#
# Throws (every message prefixed "iroha.resource-policy.mkResourcePolicy: "):
#   - `name` / `description` missing;
#   - `units` missing, not an attrset, or empty;
#   - a unitPolicy that is not an attrset;
#   - a `cpuQuota` that is neither an int nor a string.
{ lib }:
let
  core = import ./core.nix { inherit lib; };
  optionSurface = import ./option-surface.nix { inherit lib; };
  inherit (lib) optionalAttrs;

  mkResourcePolicy =
    args:
    let
      name = args.name or (throw "iroha.resource-policy.mkResourcePolicy: `name` (str) is required.");
      description =
        args.description
          or (throw "iroha.resource-policy.mkResourcePolicy: `description` (str) is required.");
      namespace = args.namespace or "systemd";
      enable = args.enable or true;
      extraOptions = args.extraOptions or { };

      units =
        if !(args ? units) then
          throw "iroha.resource-policy.mkResourcePolicy: `units` (attrsOf unitPolicy — keyed by systemd unit name) is required."
        else if !(builtins.isAttrs args.units) then
          throw "iroha.resource-policy.mkResourcePolicy: `units` must be an attrset keyed by unit name, got ${builtins.typeOf args.units}."
        else if args.units == { } then
          throw "iroha.resource-policy.mkResourcePolicy: `units` must be non-empty — a resource policy that constrains no unit is a no-op."
        else
          args.units;

      unitNames = builtins.attrNames units;

      # ── cpuQuota: int percent -> "<n>%"; string passes through ──────────
      renderCpuQuota =
        unitName: q:
        if builtins.isInt q then
          "${toString q}%"
        else if builtins.isString q then
          q
        else
          throw "iroha.resource-policy.mkResourcePolicy: unit '${unitName}' `cpuQuota` must be an int (percent) or a string (\"50%\"), got ${builtins.typeOf q}.";

      # ── conservative byte-size parse for the MemoryHigh<=MemoryMax check ─
      # Accepts a bare int (bytes) or a "<n><suffix>" string where suffix is
      # one of K/M/G/T (binary, the systemd default for these keys). Returns
      # null when the value is un-parseable — the assertion then SKIPS that
      # unit (best-effort, never a false failure).
      sizeSuffixes = {
        K = 1024;
        M = 1024 * 1024;
        G = 1024 * 1024 * 1024;
        T = 1024 * 1024 * 1024 * 1024;
      };
      parseSize =
        v:
        if v == null then
          null
        else if builtins.isInt v then
          v
        else if !(builtins.isString v) then
          null
        else
          let
            m = builtins.match "([0-9]+)([KMGT]?)i?B?" v;
          in
          if m == null then
            null
          else
            let
              n = lib.toInt (builtins.elemAt m 0);
              suffix = builtins.elemAt m 1;
            in
            if suffix == "" then n else n * sizeSuffixes.${suffix};

      # ── per-unit serviceConfig overlay (only NON-NULL fields) ───────────
      unitServiceConfig =
        unitName: p:
        if !(builtins.isAttrs p) then
          throw "iroha.resource-policy.mkResourcePolicy: unit '${unitName}' policy must be an attrset, got ${builtins.typeOf p}."
        else
          let
            cpuQuota = p.cpuQuota or null;
            cpuWeight = p.cpuWeight or null;
            memoryMin = p.memoryMin or null;
            memoryMax = p.memoryMax or null;
            memoryHigh = p.memoryHigh or null;
            tasksMax = p.tasksMax or null;
            ioWeight = p.ioWeight or null;
            allowedCPUs = p.allowedCPUs or null;
            oomScoreAdjust = p.oomScoreAdjust or null;
          in
          { }
          // optionalAttrs (cpuQuota != null) { CPUQuota = renderCpuQuota unitName cpuQuota; }
          // optionalAttrs (cpuWeight != null) { CPUWeight = cpuWeight; }
          // optionalAttrs (memoryMin != null) { MemoryMin = memoryMin; }
          // optionalAttrs (memoryMax != null) { MemoryMax = memoryMax; }
          // optionalAttrs (memoryHigh != null) { MemoryHigh = memoryHigh; }
          // optionalAttrs (tasksMax != null) { TasksMax = tasksMax; }
          // optionalAttrs (ioWeight != null) { IOWeight = ioWeight; }
          // optionalAttrs (allowedCPUs != null) { AllowedCPUs = allowedCPUs; }
          // optionalAttrs (oomScoreAdjust != null) { OOMScoreAdjust = oomScoreAdjust; };

      systemdServices = lib.mapAttrs (unitName: p: {
        serviceConfig = unitServiceConfig unitName p;
      }) units;

      # ── best-effort sanity assertions (per unit) ────────────────────────
      unitAssertions =
        unitName: p:
        let
          cpuWeight = p.cpuWeight or null;
          tasksMax = p.tasksMax or null;
          ioWeight = p.ioWeight or null;
          memMax = parseSize (p.memoryMax or null);
          memHigh = parseSize (p.memoryHigh or null);
        in
        (lib.optional (tasksMax != null) {
          assertion = tasksMax > 0;
          message = "iroha.resource-policy '${name}': unit '${unitName}' tasksMax must be > 0, got ${toString tasksMax}.";
        })
        ++ (lib.optional (cpuWeight != null) {
          assertion = cpuWeight >= 1 && cpuWeight <= 10000;
          message = "iroha.resource-policy '${name}': unit '${unitName}' cpuWeight must be in 1..10000, got ${toString cpuWeight}.";
        })
        ++ (lib.optional (ioWeight != null) {
          assertion = ioWeight >= 1 && ioWeight <= 10000;
          message = "iroha.resource-policy '${name}': unit '${unitName}' ioWeight must be in 1..10000, got ${toString ioWeight}.";
        })
        ++ (lib.optional (memMax != null && memHigh != null) {
          assertion = memHigh <= memMax;
          message = "iroha.resource-policy '${name}': unit '${unitName}' memoryHigh must be <= memoryMax.";
        });

      assertions = lib.concatMap (unitName: unitAssertions unitName units.${unitName}) unitNames;

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

      configFragment =
        {
          config,
          ...
        }:
        let
          cfg = lib.getAttrFromPath optionPath config;
        in
        {
          config = lib.mkIf cfg.enable (
            {
              systemd.services = systemdServices;
            }
            // optionalAttrs (assertions != [ ]) { inherit assertions; }
          );
        };

      nixosModule = core.tag core.classes.nixos {
        imports = [
          surface.module
          configFragment
        ];
      };
    in
    # Force the typed validations at WHNF so a bad name/units throws at
    # construction time (name/description forced by their `or` throws on
    # meta access below; units forced here).
    builtins.seq (builtins.isAttrs units) {
      nixos = nixosModule;
      meta = {
        inherit name optionPath enablePath;
        unitCount = builtins.length unitNames;
        kind = "resource-policy";
      };
    };
in
{
  inherit mkResourcePolicy;
}
