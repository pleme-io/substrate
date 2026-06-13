# iroha.udev-tune — L2: a DEVICE-APPEAR-DRIVEN tuning MODULE emitter.
#
# Sibling to iroha.scheduled-job (timer-driven) and iroha.service-module
# (keep-alive-driven): this letter emits the THIRD system-work trigger — a
# device hotplug. A NIC links up, an NVMe shows up, a USB stick is plugged
# in; udev matches it and fires tuning. ~N fleet files hand-roll this shape:
# rio's `services.udev.extraRules` (per-NVMe queue tuning) PLUS its
# `i40e-tune@` oneshot template wired to `sys-subsystem-net-devices-%i.device`
# (`seibi nic-tune --driver i40e %i` on link-up). This letter is the typed
# surface those reach for — typed udev MATCH attrs rendered to a rule line,
# and the oneshot the rule triggers, in one class-tagged module.
#
# A rule has a typed `match` (the udev predicate) and exactly one of:
#   - `action`      — a verbatim `RUN+="<cmd>"` fired inline by udev; OR
#   - `tuneService` — names a oneshot the rule STARTS via
#                     `RUN+="${systemctl} start <tuneService>@<rule-name>"`
#                     (the rule name becomes the systemd instance %i), with
#                     `tuning.command` becoming that oneshot's ExecStart.
# The systemctl path is itself caller-provided (`systemctlPath`, default
# "/run/current-system/sw/bin/systemctl") because this file is pure { lib }
# and cannot resolve pkgs.systemd at render time.
#
# The MATCH renderer turns typed attrs into a udev rule predicate:
#   { SUBSYSTEM = "net"; KERNEL = "nvme0n1"; }      -> SUBSYSTEM=="net", KERNEL=="nvme0n1"
#   { ATTRS.driver = "i40e"; }                       -> ATTRS{driver}=="i40e"
#   { ATTR.queue.scheduler = "none"; }               -> ATTR{queue/scheduler}=="none"
# A nested attrs value renders the FIRST key as the udev brace key and joins
# any remaining path segments with "/" (the udev sysattr path separator), so
# `ATTRS.driver` → `ATTRS{driver}` and `ATTR.queue.scheduler` →
# `ATTR{queue/scheduler}`. Match keys are emitted in a STABLE order
# (lexicographic by top-level key) so two equal specs render byte-identical.
# Rules concatenate in lexicographic rule-NAME order for the same reason.
#
# COMPOSES iroha.mkOptionSurface for the enable + extraOptions skeleton
# (package = false, settings = null) and iroha.core.tag for class tagging.
# It does NOT emit a package option (udev rules + system oneshots run
# absolute paths the caller resolves) and it does NOT emit a darwin or
# home-manager projection (udev is Linux-only — this is a nixos-class-only
# letter).
#
# Exports (pure { lib }, zero pkgs — pkgs binds late as a module arg):
#
#   mkUdevTune :: {
#     name        :: str (required) — option-path leaf + rule-comment tag;
#     description :: str (required) — human description (enable option text);
#     namespace   ? "hardware"      — dotted option root; lands at <ns>.<name>;
#     enable      ? true            — emit the `enable` option (mkEnableOption);
#     extraOptions ? { } | (lib -> attrs) — extra typed option declarations
#                                     merged under the option root;
#     systemctlPath ? "/run/current-system/sw/bin/systemctl" — absolute
#                                     systemctl used to build a tuneService
#                                     RUN+= start command;
#     rules :: attrsOf ruleSpec (required, NON-EMPTY) where ruleSpec = {
#       match :: attrs (required, non-empty) — udev MATCH keys; nested attrs
#                render as udev brace keys (ATTRS.driver -> ATTRS{driver});
#       action      ? null (str) — a verbatim RUN+= command; OR
#       tuneService ? null (str) — name of a oneshot template to start when
#                                  matched (emits RUN+="<systemctl> start
#                                  <tuneService>@<rule-name>" + the oneshot);
#       tuning      ? null — required iff tuneService set; {
#         command :: str (required) — absolute ExecStart command line for the
#                                     emitted oneshot (the %i instance is the
#                                     rule name — caller embeds %i if needed);
#         after          ? [ ] (listOf str);
#         path           ? [ ] (listOf str) — systemd PATH= entries;
#         remainAfterExit ? true (bool) — oneshot RemainAfterExit;
#         serviceConfigExtra ? { } — raw serviceConfig passthrough;
#       };
#       exactly one of action / tuneService is required per rule.
#     };
#   } -> {
#     nixos :: class-tagged module (_class "nixos") —
#       options.<ns>.<name>.{ enable, …extraOptions };
#       config = mkIf cfg.enable {
#         services.udev.extraRules = <"# <name>\n<rule lines>\n">  (one line
#           per rule, lexicographic rule-name order, deterministic);
#         systemd.services = <the triggered tuning oneshots, keyed by the
#           tuneService template name "<tuneService>@", Type=oneshot,
#           RemainAfterExit=true, ExecStart=<tuning.command>>;  (empty when no
#           rule uses tuneService);
#       };
#     meta :: { name, optionPath, enablePath, ruleCount, kind = "udev-tune" };
#   }
#
# Throws (every message prefixed "iroha.udev-tune.mkUdevTune: "):
#   - `name` / `description` missing;
#   - `rules` missing, not attrs, or empty;
#   - a rule whose `match` is missing / not attrs / empty;
#   - a rule with NEITHER `action` nor `tuneService` (nothing to fire);
#   - a rule with BOTH `action` and `tuneService` (ambiguous);
#   - a `tuneService` rule with no `tuning` (or `tuning.command`).
{ lib }:
let
  core = import ./core.nix { inherit lib; };
  optionSurface = import ./option-surface.nix { inherit lib; };
  inherit (lib) optionalAttrs;

  # ── udev MATCH renderer ──────────────────────────────────────────────
  # A leaf string value renders `KEY=="value"`. A nested attrs value renders
  # the udev brace form: the FIRST attr key becomes the brace key and any
  # remaining path segments join with "/" — ATTRS.driver -> ATTRS{driver},
  # ATTR.queue.scheduler -> ATTR{queue/scheduler}. Keys are emitted in stable
  # lexicographic order so equal specs render byte-identically.
  renderMatchPair =
    key: value:
    if builtins.isString value then
      ''${key}=="${value}"''
    else if builtins.isAttrs value then
      let
        # Walk the single-branch path: collect (subKey-chain, leaf-string).
        descend =
          path: v:
          if builtins.isString v then
            { inherit path; leaf = v; }
          else if builtins.isAttrs v then
            let
              names = builtins.attrNames v;
              first = builtins.head names;
            in
            if names == [ ] then
              throw "iroha.udev-tune.mkUdevTune: match key '${key}' has an empty nested attrs — give it a leaf string value."
            else
              descend (path ++ [ first ]) v.${first}
          else
            throw "iroha.udev-tune.mkUdevTune: match key '${key}.${lib.concatStringsSep "." path}' must bottom out in a string — got ${builtins.typeOf v}.";
        walked = descend [ ] value;
        braceBody = lib.concatStringsSep "/" walked.path;
      in
      ''${key}{${braceBody}}=="${walked.leaf}"''
    else
      throw "iroha.udev-tune.mkUdevTune: match key '${key}' must be a string or a nested attrs (e.g. ATTRS.driver) — got ${builtins.typeOf value}.";

  renderMatch =
    match:
    lib.concatStringsSep ", " (
      lib.mapAttrsToList renderMatchPair match
    );

  mkUdevTune =
    args:
    let
      name = args.name or (throw "iroha.udev-tune.mkUdevTune: `name` (str) is required.");
      description =
        args.description
          or (throw "iroha.udev-tune.mkUdevTune: `description` (str) is required.");
      namespace = args.namespace or "hardware";
      enable = args.enable or true;
      extraOptions = args.extraOptions or { };
      systemctlPath = args.systemctlPath or "/run/current-system/sw/bin/systemctl";

      rawRules =
        args.rules
          or (throw "iroha.udev-tune.mkUdevTune: `rules` (attrsOf ruleSpec, non-empty) is required.");
      rules =
        if !(builtins.isAttrs rawRules) then
          throw "iroha.udev-tune.mkUdevTune: `rules` must be an attrset of rule specs — got ${builtins.typeOf rawRules}."
        else if rawRules == { } then
          throw "iroha.udev-tune.mkUdevTune: `rules` must be non-empty — a udev-tune module with no rules tunes nothing."
        else
          rawRules;

      # Stable lexicographic rule-name order (attrNames is already sorted).
      ruleNames = builtins.attrNames rules;

      # ── per-rule normalization (typed) ──────────────────────────────────
      # Returns { line :: str; tuneService :: null|{ name; tuning }; }
      normalizeRule =
        ruleName: rule:
        let
          rawMatch =
            rule.match
              or (throw "iroha.udev-tune.mkUdevTune: rule '${ruleName}' needs a `match` (attrs of udev match keys).");
          match =
            if !(builtins.isAttrs rawMatch) then
              throw "iroha.udev-tune.mkUdevTune: rule '${ruleName}'.match must be an attrset of udev match keys — got ${builtins.typeOf rawMatch}."
            else if rawMatch == { } then
              throw "iroha.udev-tune.mkUdevTune: rule '${ruleName}'.match must be non-empty — a rule with no match predicate fires on every device."
            else
              rawMatch;

          hasAction = (rule.action or null) != null;
          hasTuneService = (rule.tuneService or null) != null;

          matchStr = renderMatch match;

          fire =
            if hasAction && hasTuneService then
              throw "iroha.udev-tune.mkUdevTune: rule '${ruleName}' takes exactly one of `action` (verbatim RUN+=) or `tuneService` (oneshot to start) — got both."
            else if hasAction then
              {
                runCmd = rule.action;
                tune = null;
              }
            else if hasTuneService then
              let
                svc = rule.tuneService;
                tuning =
                  rule.tuning
                    or (throw "iroha.udev-tune.mkUdevTune: rule '${ruleName}' sets `tuneService` but has no `tuning` — the oneshot needs at least { command = <ExecStart>; }.");
                command =
                  tuning.command
                    or (throw "iroha.udev-tune.mkUdevTune: rule '${ruleName}'.tuning needs a `command` (str — absolute ExecStart for the '${svc}@' oneshot).");
              in
              {
                # Start the per-instance oneshot; the rule name is the %i.
                # `command` is seq-forced so a tuneService rule MISSING its
                # tuning.command throws on the rule-line path (the udev rule is
                # meaningless without the oneshot it starts), not only when the
                # systemd.services oneshot happens to be forced.
                runCmd = builtins.seq command "${systemctlPath} start ${svc}@${ruleName}";
                tune = {
                  inherit svc tuning;
                };
              }
            else
              throw "iroha.udev-tune.mkUdevTune: rule '${ruleName}' has neither `action` nor `tuneService` — nothing to fire when the device appears.";

          line = ''${matchStr}, RUN+="${fire.runCmd}"'';
        in
        {
          inherit line;
          tune = fire.tune;
        };

      normalized = lib.mapAttrs normalizeRule rules;

      # ── concatenated udev rule lines (deterministic, name-sorted) ───────
      ruleLines = lib.concatStringsSep "\n" (
        map (n: normalized.${n}.line) ruleNames
      );
      extraRules = "# ${name}\n${ruleLines}\n";

      # ── triggered tuning oneshots (keyed by "<tuneService>@") ───────────
      mkOneshot =
        tune:
        let
          t = tune.tuning;
          remainAfterExit = t.remainAfterExit or true;
          after = t.after or [ ];
          path = t.path or [ ];
          serviceConfigExtra = t.serviceConfigExtra or { };
        in
        {
          serviceConfig =
            {
              ExecStart = t.command;
              Type = "oneshot";
              RemainAfterExit = remainAfterExit;
            }
            // serviceConfigExtra;
        }
        // optionalAttrs (after != [ ]) { inherit after; }
        // optionalAttrs (path != [ ]) { inherit path; };

      tuningServices = lib.listToAttrs (
        lib.concatMap (
          n:
          let
            tune = normalized.${n}.tune;
          in
          lib.optional (tune != null) (lib.nameValuePair "${tune.svc}@" (mkOneshot tune))
        ) ruleNames
      );

      ruleCount = builtins.length ruleNames;

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
          config = lib.mkIf cfg.enable (
            {
              services.udev.extraRules = extraRules;
            }
            // optionalAttrs (tuningServices != { }) { systemd.services = tuningServices; }
          );
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
      meta = {
        inherit name optionPath enablePath ruleCount;
        kind = "udev-tune";
      };
    };
in
{
  inherit mkUdevTune;
}
