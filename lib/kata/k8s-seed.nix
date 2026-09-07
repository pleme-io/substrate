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
#     after       ? [ "k3s.service" ];
#     wants       ? [ "k3s.service" ];
#     restartTriggers ? [ ] — paths whose change re-runs the seed;
#     extraConfig ? { } — merged into the emitted module's `config`;
#     startLimitIntervalSec ? 900 / startLimitBurst ? 60 — see the note at the
#                     unit; the default is rio's hand-derived, REACHABLE bound;
#     meta        ? { } — passed through to the result verbatim;
#     errPrefix   ? "kata.k8s-seed.mkSeedUnit: " — prefix for this letter's
#                     throws, so a caller's errors name the CALLER's letter;
#   } -> { nixos :: class-tagged module; meta; unitName; optionPath; }
{ lib }:
let
  iroha = import ../iroha { inherit lib; };

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
      meta = spec.meta or { };

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
    in
    {
      nixos = iroha.tag "nixos" module;
      inherit meta unitName;
      optionPath = surface.optionPath;
    };
in
{
  inherit mkSeedUnit;
}
