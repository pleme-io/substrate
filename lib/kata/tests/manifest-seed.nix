# Tests — kata.manifest-seed (a declared K8s manifest reconciled from nix onto
# a node's own cluster, as a typed module factory). Same harness shape as the
# secret-seed tests: the emitted `nixos` member is a class-tagged module, so
# eval it against a STUB universe declaring the option paths it writes into
# (environment.etc + systemd.services) and assert the resulting config.
#
# ── ★ THE STUB IS A MIRROR OF WHAT THE LETTER READS ───────────────────────
# The recurring failure recorded in nix/CLAUDE.md: when a module starts
# writing a new option, its stub universe gains it in the SAME change, or the
# suite goes blind — a suite that does not evaluate reports nothing at all,
# green. `environment.etc` is declared here because manifest-seed writes it.
{
  lib,
  iroha,
  kata,
}:
let
  universe =
    { lib, ... }:
    {
      options = {
        environment.etc = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        systemd.services = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
      };
    };

  evalSeed =
    seed:
    (lib.evalModules {
      modules = [
        universe
        { _module.args.pkgs = { }; }
        seed.nixos
      ];
    }).config;

  # Canonical: a CR that needs its CRD established first, in a namespace the
  # seed creates, with a pinned kubectl and engenho's loopback kubeconfig —
  # i.e. the plo InfrastructureTemplate shape this letter was built for.
  tmpl = kata.mkManifestSeed {
    name = "pleme-org-posture";
    namespace = "pleme.nixos.manifests";
    manifests."10-template" = "apiVersion: v1\nkind: ConfigMap\n";
    namespaces = [ "pleme-io-opensource" ];
    requireCrds = [ "infrastructuretemplates.pangea.io" ];
    kubeconfig = "/var/lib/engenho/kubeconfig";
    after = [ "engenho-daemon.service" ];
    wants = [ "engenho-daemon.service" ];
    kubectl = "/run/current-system/sw/bin/kubectl";
  };
  tmplCfg = evalSeed tmpl;
  tmplUnit = tmplCfg.systemd.services."pleme-org-posture-seed";

  # Minimal: two manifests, no namespaces, no CRDs, defaults everywhere.
  pair = kata.mkManifestSeed {
    name = "pair";
    manifests = {
      "00-first" = "kind: A\n";
      "10-second" = "kind: B\n";
    };
  };
  pairCfg = evalSeed pair;
  pairUnit = pairCfg.systemd.services."pair-seed";
in
{
  # ── the letter's own contract ──────────────────────────────────────────
  meta-kind = {
    expr = tmpl.meta.kind;
    expected = "manifest-seed";
  };

  # attrNames is sorted, so apply order is deterministic rather than
  # attrset-iteration luck. A consumer orders by naming (`00-`, `10-`).
  keys-are-sorted = {
    expr = pair.meta.keys;
    expected = [
      "00-first"
      "10-second"
    ];
  };

  # Order is a position question, so read it off the script text. `indexOf`
  # returns -1 when absent, so the `>= 0` legs are what stop "both missing"
  # from satisfying `first < second` vacuously — the guard-whose-operands-are-
  # equal-by-construction trap.
  applies-in-key-order = {
    expr =
      let
        at = needle: lib.lists.findFirstIndex (l: lib.hasInfix needle l) null (
          lib.splitString "\n" pairUnit.script
        );
        first = at "00-first";
        second = at "10-second";
      in
      first != null && second != null && first < second;
    expected = true;
  };

  # ── the manifest text reaches /etc, which is what makes it gitops ──────
  # The store path of this file is the restartTrigger; a committed manifest
  # edit changes it, which re-runs the seed on the node's next gitops
  # rebuild. Without the trigger the manifest sits on disk unread — the
  # exact defect measured on plo's engenho config on 2026-09-06.
  manifest-lands-in-etc = {
    expr = tmplCfg.environment.etc."kata-manifest-seed/pleme-org-posture/10-template.yaml".text;
    expected = "apiVersion: v1\nkind: ConfigMap\n";
  };

  restart-trigger-is-the-manifest-path = {
    expr = tmplUnit.restartTriggers;
    expected = [ "/etc/kata-manifest-seed/pleme-org-posture/10-template.yaml" ];
  };

  # ── server-side apply, and force-conflicts as the default ─────────────
  # Adopting an object something else applied first IS the transition; without
  # the flag the first converging apply conflicts on every field and the seed
  # fails permanently.
  apply-is-server-side-with-force = {
    expr =
      lib.hasInfix "--server-side" tmplUnit.script
      && lib.hasInfix "--field-manager=kata-manifest-seed" tmplUnit.script
      && lib.hasInfix "--force-conflicts" tmplUnit.script;
    expected = true;
  };

  force-conflicts-is-typed-off = {
    expr = lib.hasInfix "--force-conflicts" (
      (evalSeed (kata.mkManifestSeed {
        name = "shared";
        manifests.a = "kind: A\n";
        forceConflicts = false;
      })).systemd.services."shared-seed".script
    );
    expected = false;
  };

  # ── a CR before its CRD is a WAIT, not a 5-minute red ────────────────
  crd-wait-precedes-the-apply = {
    expr =
      let
        lines = lib.splitString "\n" tmplUnit.script;
        waitAt = lib.lists.findFirstIndex (l: lib.hasInfix "wait --for=condition=established" l) null lines;
        applyAt = lib.lists.findFirstIndex (l: lib.hasInfix "10-template.yaml" l) null lines;
      in
      waitAt != null && applyAt != null && waitAt < applyAt;
    expected = true;
  };

  no-crd-wait-when-none-required = {
    expr = lib.hasInfix "wait --for=condition=established" pairUnit.script;
    expected = false;
  };

  namespace-ensured-before-apply = {
    expr = lib.hasInfix "create namespace pleme-io-opensource" tmplUnit.script;
    expected = true;
  };

  # ── the shared engine's contract, asserted THROUGH this letter ────────
  # The retry bound is the reason the engine was lifted rather than copied;
  # a new seed kind must inherit it without its author doing anything.
  inherits-the-reachable-retry-bound = {
    expr = {
      interval = tmplUnit.startLimitIntervalSec;
      burst = tmplUnit.startLimitBurst;
    };
    expected = {
      interval = 900;
      burst = 60;
    };
  };

  inherits-the-oneshot-shape = {
    expr = tmplUnit.serviceConfig;
    expected = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  kubeconfig-reaches-the-unit = {
    expr = tmplUnit.environment.KUBECONFIG;
    expected = "/var/lib/engenho/kubeconfig";
  };

  # ── refusals: an empty apply must never report success ────────────────
  # Every one of these is the "absent result read as a successful answer"
  # class, which is the defect family this whole surface was hardened
  # against. A seed that applies nothing while exiting 0 is the worst of
  # them, because it looks converged.
  # ── ★ deepSeq, NOT `.meta.name` ─────────────────────────────────────────
  # `tryEval` forces to WHNF only, and `.meta.name` is just `name` — a field
  # that never touches `manifests`. Probing it made all four of these report
  # SUCCESS against inputs the letter does refuse: a refusal test that cannot
  # reach the refusal, which is the vacuous-guard class this suite exists to
  # catch. `deepSeq` forces the whole result, so the throw is actually reached.
  # Measured 2026-09-07: 4/4 green before this change, 4/4 red after — the
  # difference is the test, not the letter.
  missing-manifests-throws = {
    expr = (builtins.tryEval (builtins.deepSeq (kata.mkManifestSeed { name = "x"; }).meta true)).success;
    expected = false;
  };

  empty-manifests-throws = {
    expr =
      (builtins.tryEval (builtins.deepSeq (kata.mkManifestSeed {
        name = "x";
        manifests = { };
      }).meta true)).success;
    expected = false;
  };

  blank-manifest-throws = {
    expr =
      (builtins.tryEval (builtins.deepSeq (kata.mkManifestSeed {
        name = "x";
        manifests.a = "   \n";
      }).meta true)).success;
    expected = false;
  };

  non-string-manifest-throws = {
    expr =
      (builtins.tryEval (builtins.deepSeq (kata.mkManifestSeed {
        name = "x";
        manifests.a = { kind = "A"; };
      }).meta true)).success;
    expected = false;
  };

  missing-name-throws = {
    expr = (builtins.tryEval (builtins.deepSeq (kata.mkManifestSeed { manifests.a = "kind: A\n"; }).meta true)).success;
    expected = false;
  };
}
