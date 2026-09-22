# kata.k8s-seed — L1 fleet-standard: the ONE systemd-oneshot shape that
# reconciles a declared Kubernetes object from a physical node, shared by
# every seed letter.
#
# THE GAP this letter closes: `kata.secret-seed` already owned this shape, and
# owned it well — the option surface, the boot ordering, the KUBECONFIG
# binding, and (load-bearing) the REACHABLE bootstrap retry bound whose
# absence once burned 10,857 restarts over 15 hours on rio while
# `systemctl --failed` listed nothing. Then a second consumer arrived that
# needed all of that and differed only in WHAT it applies: a full manifest
# rather than a Secret assembled from `--from-file` arguments.
#
# Copying the unit would have copied the retry bound as a value rather than as
# a shared engine, which is the exact failure mode the bound's own comment
# describes: "the hand-written version protected only the units on the node
# whose author knew to reference it". So the engine is lifted here and both
# letters render through it. A third seed kind inherits the bound by
# construction rather than by remembering.
#
# ── ★ WHAT IS GENERIC vs WHAT IS THE SEED KIND'S OWN ──────────────────────
# Generic (here): the option root, the unit name, ordering, wantedBy, the
# retry bound, `Type=oneshot` + `RemainAfterExit` + `Restart=on-failure`, the
# KUBECONFIG environment, restartTriggers plumbing, the "nixos" class tag.
# The seed kind's own: the generated script, and any extra config the kind
# needs (secret-seed contributes `sops.secrets`; manifest-seed contributes
# `environment.etc`).
#
# Pure { lib } at import. No package is resolved here — `kubectl` arrives as a
# string the caller's script interpolates.
#
# ── ★ THE HOME-MANAGER (darwin) OUTPUT — one script, two supervisors ──────
# Added when ryn took over org-wide GitOps reconciliation from plo: the same
# seed shape (a bounded-retry reconcile that gives up rather than loops
# forever) is needed on ryn's Darwin engenho, and systemd does not exist
# there. `nixos` above stays byte-for-byte unchanged; `homeManager` is
# additive.
#
# ★ IT IS A HOME-MANAGER AGENT (`launchd.agents`), NOT A DARWINMODULE DAEMON
# (`launchd.daemons`) — and that is not a naming detail, it is a placement
# fact about the actual node. Checked against ryn's live config before
# writing this: `pleme.engenho.pangeaStack` (the operator + postgres this
# seed's CR depends on) is a home-manager module under
# `home-manager.users."luis.d"`, engenho's own kubeconfig lives at
# `~/.kube/configs/engenho` (a HOME path), and engenho itself runs as the
# LOGGED-IN USER's launchd agent, not a root daemon. A system-level
# `launchd.daemons` entry would run as root, which cannot read any of that
# without a second, unnecessary credential-copying step. plo's `.nixos`
# output is root/system because plo's engenho genuinely IS a NixOS system
# service; ryn's engenho genuinely is a per-user one — the two platforms
# differ in KIND here, not just in which supervisor renders the unit.
# `iroha.launchd-unit.mkLaunchdUnit`'s own header already anticipated this
# split: its `serviceConfig` return (the bare plist, no daemon wrapper) is
# "what a home-manager `launchd.agents.<name>.config` expects" — that field,
# not `.daemon`, is what this output uses.
#
# launchd has no unit-dependency ordering (`after`/`wants` are accepted for
# interface parity and otherwise UNUSED on this side — a dependency that
# isn't up yet just fails an attempt, which the retry loop already tolerates)
# and no native "N starts within T seconds, then stay failed" circuit
# breaker the way `StartLimitIntervalSec`/`StartLimitBurst` give systemd. So
# the retry bound moves INTO the generated script as a bounded attempt loop
# — up to `startLimitBurst` tries, `5s` apart (matching the hardcoded
# `RestartSec` above), bailing early if `startLimitIntervalSec` wall-clock
# elapses first. This is the same reduction the systemd bound's own comment
# already makes by hand ("60 attempts at 5s span 300s, comfortably inside a
# 900s window") — not a new algorithm, the existing mental model made literal
# for a platform with no supervisor-level equivalent. One launchd
# `RunAtLoad`-triggered invocation IS one bounded campaign; there is no
# `KeepAlive` respawn to layer a second retry mechanism on top of.
#
# `restartTriggers` has no systemd unit to bump — home-manager's launchd
# activation diffs each agent's rendered plist and reloads only the ones
# that changed, so folding each trigger value into the script text (as an
# inert `: # seed-trigger=<value>` line) is sufficient: the derivation
# content moves, the plist moves, home-manager reloads it on the next
# `switch`/`rebuild`. No bespoke trigger plumbing needed on this side,
# unlike systemd's explicit `X-Restart-Triggers`.
#
# Exports:
#
#   mkSeedUnit :: {
#     name        :: str (required) — the option leaf and `<name>-seed` unit;
#     namespace   ? "services" — option root: options.<namespace>.<name>.enable;
#     enable      ? true — initial value of that option (mkDefault);
#     description :: str (required) — the systemd unit description;
#     optionDescription :: str (required) — the enable option's description;
#     script      :: str (required, non-empty) — the generated unit body;
#     kubeconfig  ? "/etc/rancher/k3s/k3s.yaml" — KUBECONFIG for the unit;
#     after       ? [ "k3s.service" ] — nixos only, informational on darwin;
#     wants       ? [ "k3s.service" ] — nixos only, informational on darwin;
#     restartTriggers ? [ ] — values whose change re-runs the seed (a path on
#                     nixos; ANY string on the homeManager side — see above);
#     extraConfig ? { } — merged into the emitted module's `config` on BOTH
#                     outputs (secret-seed's `sops.secrets` and
#                     manifest-seed's `environment.etc` each have a
#                     home-manager implementation too);
#     homeDirectory ? null — REQUIRED to get anything meaningful out of
#                     `.homeManager` whenever a caller's script/extraConfig
#                     touch a filesystem path: NixOS's `/etc` and sops-nix's
#                     `/run/secrets/*` have NO home-manager equivalent (they
#                     are root/system paths; home-manager materializes
#                     everything under $HOME), so a caller whose script
#                     embeds one of those must pass a HOME-RELATIVE
#                     replacement via `homeManagerScript`/
#                     `homeManagerExtraConfig` below, and needs
#                     `homeDirectory` to compute it. Also becomes the default
#                     `logDir` (`<homeDirectory>/Library/Logs`) — `/var/log`
#                     is root-owned and a per-user launchd agent cannot
#                     write there;
#     homeManagerScript ? script — the script text for the `.homeManager`
#                     output specifically, when it must differ from `script`
#                     (a different file path baked into the command). Falls
#                     back to `script` unchanged, which is correct whenever
#                     the caller's script has nothing platform-specific in it;
#     homeManagerExtraConfig ? extraConfig — same idea, for the config
#                     merged alongside the launchd agent (e.g. `home.file`
#                     instead of `environment.etc`);
#     logDir      ? "/var/log", or "<homeDirectory>/Library/Logs" when
#                     `homeDirectory` is set — homeManager only:
#                     stdout/stderr go to `<logDir>/<name>-seed.{log,err}`;
#     startLimitIntervalSec ? 900 / startLimitBurst ? 60 — see the note at the
#                     unit; the default is rio's hand-derived, REACHABLE bound;
#     meta        ? { } — passed through to the result verbatim;
#     errPrefix   ? "kata.k8s-seed.mkSeedUnit: " — prefix for this letter's
#                     throws, so a caller's errors name the CALLER's letter;
#   } -> {
#     nixos :: class-tagged module; homeManager :: class-tagged module;
#     meta; unitName; optionPath;
#   }
{ lib }:
let
  iroha = import ../iroha { inherit lib; };
  launchdUnit = import ../iroha/launchd-unit.nix { inherit lib; };

  mkSeedUnit =
    spec:
    let
      errPrefix = spec.errPrefix or "kata.k8s-seed.mkSeedUnit: ";
      req =
        field: kind:
        spec.${field} or (throw "${errPrefix}`${field}` (${kind}) is required.");

      name = req "name" "str";
      description = req "description" "str";
      optionDescription = req "optionDescription" "str";

      rawScript = req "script" "str";
      # A seed whose script is empty is a unit that reports success having
      # reconciled nothing — the "absent result read as a successful answer"
      # class. Refuse it at eval rather than emit a green no-op.
      script =
        if !(builtins.isString rawScript) then
          throw "${errPrefix}`script` must be a string — got ${builtins.typeOf rawScript} for seed '${name}'."
        else if lib.trim rawScript == "" then
          throw "${errPrefix}`script` must be non-empty — an empty seed unit reports success having reconciled nothing (seed '${name}')."
        else
          rawScript;

      namespace = spec.namespace or "services";
      enable = spec.enable or true;
      kubeconfig = spec.kubeconfig or "/etc/rancher/k3s/k3s.yaml";
      after = spec.after or [ "k3s.service" ];
      wants = spec.wants or [ "k3s.service" ];
      restartTriggers = spec.restartTriggers or [ ];
      extraConfig = spec.extraConfig or { };
      startLimitIntervalSec = spec.startLimitIntervalSec or 900;
      startLimitBurst = spec.startLimitBurst or 60;
      homeDirectory = spec.homeDirectory or null;
      logDir = spec.logDir or (if homeDirectory != null then "${homeDirectory}/Library/Logs" else "/var/log");
      meta = spec.meta or { };

      # Fall back to the shared values unchanged — correct whenever a
      # caller's script/extraConfig has nothing platform-specific baked in
      # (e.g. secret-seed's grafana-admin test fixtures, which touch no
      # `/etc` path at all).
      hmScriptOverride =
        let raw = spec.homeManagerScript or script; in
        if !(builtins.isString raw) then
          throw "${errPrefix}`homeManagerScript` must be a string — got ${builtins.typeOf raw} for seed '${name}'."
        else if lib.trim raw == "" then
          throw "${errPrefix}`homeManagerScript` must be non-empty (seed '${name}')."
        else
          raw;
      homeManagerExtraConfig = spec.homeManagerExtraConfig or extraConfig;

      unitName = "${name}-seed";

      surface = iroha.mkOptionSurface {
        inherit name namespace;
        description = optionDescription;
        optionName = name;
        package = false;
      };

      configModule =
        { config, lib, ... }:
        let
          cfg = lib.attrByPath surface.optionPath { } config;
        in
        {
          config = lib.mkIf cfg.enable (
            lib.recursiveUpdate extraConfig {
              systemd.services.${unitName} = {
                inherit description after wants;
                wantedBy = [ "multi-user.target" ];
                inherit restartTriggers;
                environment.KUBECONFIG = kubeconfig;

                # ── ★ THE BOOTSTRAP RETRY BOUND, AS A TYPE RATHER THAN A COMMENT
                # `Restart = on-failure` with `RestartSec = 5s` and NO start limit
                # inherits systemd's default 5-starts-per-10s, which 5s spacing
                # can never fill — so the limit is UNREACHABLE and a seed whose
                # failure is PERMANENT retries forever, in `activating`, a state
                # `systemctl --failed` does not list.
                #
                # THE WORST MEASURED INSTANCE of that class in the fleet was this
                # engine's own output. On rio, 2026-08-01: `seed-grafana-oidc`
                # and `seed-grafana-admin` sat at NRestarts=10854 / 10857 — ~15
                # hours at 12 restarts/minute, each attempt spawning a
                # tatara-script and hitting the API server. They stayed
                # `activating`, never `failed`, so they appeared in no
                # failed-unit list and raised nothing. And the cause was
                # unfixable by retrying: namespace `monitoring` had been stuck
                # `Terminating` since 2026-07-26 behind a VictoriaMetrics
                # finalizer deadlock, and Kubernetes forbids creating content in
                # a terminating namespace — so all 10,857 attempts were
                # guaranteed to fail before they ran.
                #
                # 900s / 60 is not a fresh guess: it is the `bootstrapRetryBound`
                # an operator had already derived BY HAND in
                # nix/nodes/rio/configuration.nix, and it is reachable — 60
                # attempts at 5s span 300s, comfortably inside a 900s window, so
                # a permanent fault reaches `failed` in ~5 minutes while a
                # bootstrap that legitimately waits for the API server to come
                # up still gets a full hour's worth of attempts. The reason a
                # seed needs a WIDE bound (unlike an ordinary daemon's 3/300) is
                # exactly that: transient unavailability at boot is normal here,
                # so the bound must separate "still coming up" from "will never
                # work".
                #
                # Living in the SHARED engine is the point. The hand-written
                # version protected only the units on the node whose author knew
                # to reference it — and the two grafana seeds that burned 15
                # hours were generated, not hand-written. Every seed kind that
                # renders through here inherits the bound whether or not its
                # author knew it existed.
                #
                # Beware the inverse footgun this replaces: `StartLimitIntervalSec
                # = 0` DISABLES rate limiting rather than tightening it, which is
                # how `fluxcd-bootstrap` silently opted out of the shared bound
                # and was caught only by evaluating the result ("0s/60" against
                # its siblings' "900s/60"), never by reading the diff.
                #
                # [Unit] keys, at the service level: in serviceConfig they render
                # into [Service], where systemd logs "Unknown key name" and
                # IGNORES them — a bound that reads as set and enforces nothing.
                # mkDefault: a node may deliberately widen or disable this (see
                # nix's `pleme.power.lifelineRestart`). A hard value collides.
                startLimitIntervalSec = lib.mkDefault startLimitIntervalSec;
                startLimitBurst = lib.mkDefault startLimitBurst;

                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  Restart = "on-failure";
                  RestartSec = "5s";
                };
                inherit script;
              };
            }
          );
        };

      # ── The darwin script: the retry bound made literal ───────────────────
      # One `RunAtLoad` invocation = one bounded campaign of up to
      # `startLimitBurst` attempts, `5s` apart (matching `RestartSec` above),
      # bailing early on the `startLimitIntervalSec` wall-clock — see the
      # header note for why this reduction is faithful to the systemd bound
      # rather than a new algorithm. `restartTriggers` fold in as inert
      # comment lines purely so the script TEXT (and therefore the rendered
      # plist) changes when they do; nix-darwin's own activation reloads a
      # job whose plist changed, which is what stands in for systemd's
      # `X-Restart-Triggers` here.
      hmTriggerLines = lib.concatMapStringsSep "\n" (t: ": # seed-trigger=${t}") restartTriggers;

      hmScript = ''
        set -uo pipefail
        ${hmTriggerLines}
        export KUBECONFIG=${lib.escapeShellArg kubeconfig}

        _attempt=0
        _deadline=$(( $(date +%s) + ${toString startLimitIntervalSec} ))
        while [ "$_attempt" -lt ${toString startLimitBurst} ]; do
          _attempt=$(( _attempt + 1 ))
          if (
            ${hmScriptOverride}
          ); then
            exit 0
          fi
          if [ "$(date +%s)" -ge "$_deadline" ]; then
            break
          fi
          sleep 5
        done
        echo "${unitName}: giving up after $_attempt attempt(s) — bootstrap retry bound (${toString startLimitBurst}/${toString startLimitIntervalSec}s) exceeded" >&2
        exit 1
      '';

      hmConfigModule =
        { config, lib, ... }:
        let
          cfg = lib.attrByPath surface.optionPath { } config;
          rendered = launchdUnit.mkLaunchdUnit {
            label = "io.pleme.${unitName}";
            programArguments = [
              "/bin/bash"
              "-c"
              hmScript
            ];
            runAtLoad = true;
            keepAlive = false;
            standardOutPath = "${logDir}/${unitName}.log";
            standardErrorPath = "${logDir}/${unitName}.err";
          };
        in
        {
          # `extraConfig` merges here too, NOT just on the nixos side —
          # manifest-seed's `environment.etc.*` (where the manifest YAML
          # actually lands for `kubectl apply -f` to read) is a home-manager
          # option as well, and secret-seed's `sops.secrets` likewise has a
          # home-manager implementation (sops-nix's homeManagerModule). A
          # caller whose `extraConfig` genuinely names a nixos-only option
          # gets a clear eval error naming it when `.homeManager` is
          # imported — an honest failure, not a silent gap, and no reason to
          # special-case away.
          #
          # `launchd.agents.<name>.config`, NOT `.daemon` — see the header
          # note on why this is an HM agent rather than a darwinModule daemon.
          #
          # `homeManagerExtraConfig`, NOT `extraConfig` — `environment.etc`
          # and `sops.secrets` paths like `/run/secrets/*` are NixOS/system
          # concepts with no home-manager equivalent; a caller whose script
          # touches either must supply the home-relative replacement here.
          config = lib.mkIf cfg.enable (
            lib.recursiveUpdate homeManagerExtraConfig {
              launchd.agents.${unitName} = {
                enable = true;
                config = rendered.serviceConfig;
              };
            }
          );
        };

      # The enable option defaults to `enable` (mkDefault so a node can flip
      # it). mkOptionSurface emits mkEnableOption (default false); layer the
      # configured default on top via the option root.
      enableDefaultModule = {
        config = lib.setAttrByPath (surface.optionPath ++ [ "enable" ]) (lib.mkDefault enable);
      };

      module = {
        imports = [
          surface.module
          configModule
        ]
        ++ lib.optional enable enableDefaultModule;
      };

      homeManagerModule = {
        imports = [
          surface.module
          hmConfigModule
        ]
        ++ lib.optional enable enableDefaultModule;
      };
    in
    {
      nixos = iroha.tag "nixos" module;
      # ★ DELIBERATELY UNTAGGED — measured 2026-09-22 wiring ryn's real
      # consumer. `iroha.classes.homeManager` ("homeManager") exists and two
      # OTHER letters already produce it (package-module.nix, gitops.nix),
      # but neither has ever been imported into a real
      # `home-manager.users.<name>.imports` on a nix-darwin host — this was
      # the first, and it threw:
      #
      #   The module `<iroha:tag:homeManager>` (class: "homeManager") cannot
      #   be imported into a module evaluation that expects class "darwin".
      #
      # This flake's pinned home-manager does not give
      # `home-manager.users.<name>`'s module list its own classed
      # `evalModules` call — it flattens into the SAME class="darwin"
      # evaluation the whole nix-darwin system tree runs under. A module
      # whose `_class` is anything other than `null` or `"darwin"` is
      # therefore rejected the instant it lands in that list, regardless of
      # which string iroha's registry uses. Per lib/modules.nix's own check
      # (`m._class == null || m._class == class`), a module with NO `_class`
      # passes under ANY expected class — so returning the bare module here,
      # not `iroha.tag "homeManager" ...`, is what actually works in a real
      # nix-darwin + home-manager tree.
      #
      # `pending-iroha: classes.homeManager is asserted but its check does
      # not hold against this fleet's real home-manager integration — the
      # two existing producers (package-module.nix, gitops.nix) are untested
      # against a live consumer and should be re-verified the same way.`
      homeManager = homeManagerModule;
      inherit meta unitName;
      optionPath = surface.optionPath;
    };
in
{
  inherit mkSeedUnit;
}
