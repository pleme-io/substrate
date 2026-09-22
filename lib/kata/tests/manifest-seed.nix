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
        # Declared for the SAME reason as the two above (see the header
        # comment): the homeManager output writes launchd.agents, so a
        # suite that evaluates only .nixos is blind to it by construction.
        launchd.agents = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        # For the homeDirectory-aware homeManager path: home.file is
        # home-manager's actual file-materialization primitive, unlike
        # environment.etc which does not exist there at all.
        home.file = lib.mkOption {
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

  # The home-manager peer of evalSeed — same stub universe, imports
  # `.homeManager` instead of `.nixos`. `environment.etc` is shared
  # unchanged (home-manager implements it too), which is exactly the
  # property under test below.
  evalSeedHomeManager =
    seed:
    (lib.evalModules {
      modules = [
        universe
        { _module.args.pkgs = { }; }
        seed.homeManager
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
  manifest-lands-in-etc = {
    expr = tmplCfg.environment.etc."kata-manifest-seed/pleme-org-posture/10-template.yaml".text;
    expected = "apiVersion: v1\nkind: ConfigMap\n";
  };

  # ── ★★ THE PROPERTY THAT MAKES THIS A LOOP, RED-RUN AGAINST ITSELF ─────
  #
  # A committed manifest edit must change the restartTrigger, or systemd does
  # not restart the unit and the new manifest sits in /etc unread while the
  # cluster keeps the old object. That is the whole contract.
  #
  # ★ A test named `restart-trigger-is-the-manifest-path` used to sit here and
  # assert `expected = [ "/etc/kata-manifest-seed/…/10-template.yaml" ]` — i.e.
  # it PINNED the defect in place, green, while the comment above it described
  # the opposite intent. The path is byte-identical across every possible
  # content change, so the trigger never moved.
  #
  # Measured on plo before the fix: `pleme-io-github-repos-seed` last ran
  # 2026-09-10 08:12:07 while the generation that rewrote its manifest landed
  # 2026-09-11 16:58:03. `spec.suspend` read `true` on disk and `false` on the
  # live object for 32 hours, with the seed owning `f:suspend` and reporting
  # `serverside-applied`, exit 0.
  #
  # This case is written as a DIFFERENTIAL rather than an equality against a
  # literal hash, because an equality would pin whatever the implementation
  # happens to emit — which is precisely how the old case survived.
  restart-trigger-moves-with-the-content =
    let
      mk =
        text:
        (evalSeed (kata.mkManifestSeed {
          name = "trig";
          manifests."10-x" = text;
        })).systemd.services."trig-seed".restartTriggers;
      a = mk "kind: A\n";
      b = mk "kind: B\n";
    in
    {
      # same name, same key, same path — ONLY the content differs.
      expr = a != b && builtins.length a == 1;
      expected = true;
    };

  # And the negative half: identical content must NOT churn the unit, or every
  # rebuild restarts every seed and wakes the reconcile loop for nothing.
  restart-trigger-is-stable-when-content-is =
    let
      mk =
        _:
        (evalSeed (kata.mkManifestSeed {
          name = "trig";
          manifests."10-x" = "kind: A\n";
        })).systemd.services."trig-seed".restartTriggers;
    in
    {
      expr = mk 1 == mk 2;
      expected = true;
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

  # ══════════════════════════════════════════════════════════════════════
  # kata.k8s-seed's HOME-MANAGER (darwin) output, asserted through this
  # letter — same contract as the nixos suite above, ryn (Darwin engenho,
  # per-user) is the first real consumer (org-wide GitHub-repo
  # reconciliation, moved off plo). It is a launchd AGENT (`.config`), not
  # a darwinModule daemon — see the letter's header for why.
  # ══════════════════════════════════════════════════════════════════════

  hm-manifest-still-lands-in-etc = {
    # Proves extraConfig (environment.etc, where the manifest YAML the
    # script `kubectl apply -f`s actually lives) merges on the
    # home-manager side too, not just nixos — the exact thing that would
    # silently break the apply if extraConfig were dropped there.
    expr = (evalSeedHomeManager tmpl).environment.etc."kata-manifest-seed/pleme-org-posture/10-template.yaml".text;
    expected = "apiVersion: v1\nkind: ConfigMap\n";
  };

  hm-agent-uses-a-pleme-reverse-dns-label = {
    expr = (evalSeedHomeManager tmpl).launchd.agents."pleme-org-posture-seed".config.Label;
    expected = "io.pleme.pleme-org-posture-seed";
  };

  hm-agent-is-enabled = {
    expr = (evalSeedHomeManager tmpl).launchd.agents."pleme-org-posture-seed".enable;
    expected = true;
  };

  hm-runs-once-and-does-not-respawn = {
    # KeepAlive stays false: the retry bound lives INSIDE the script as a
    # bounded campaign (see the header note), so nothing above it should
    # ALSO be respawning the job — that would be two retry mechanisms
    # disagreeing about when to give up.
    expr =
      let
        cfg = (evalSeedHomeManager tmpl).launchd.agents."pleme-org-posture-seed".config;
      in
      {
        runAtLoad = cfg.RunAtLoad;
        keepAlive = cfg.KeepAlive;
      };
    expected = {
      runAtLoad = true;
      keepAlive = false;
    };
  };

  hm-script-carries-the-reachable-retry-bound = {
    # The same 900s/60 numbers the nixos unit gets from systemd options are,
    # on the home-manager side, literal numbers baked into the generated
    # script — this is the "made literal" the header note describes, so
    # assert the actual figures survive the translation rather than just
    # that SOME loop exists.
    expr =
      let
        script = lib.concatStringsSep " " (evalSeedHomeManager tmpl).launchd.agents."pleme-org-posture-seed".config.ProgramArguments;
      in
      lib.hasInfix "-lt 60" script && lib.hasInfix "+ 900" script;
    expected = true;
  };

  hm-apply-is-server-side-with-force = {
    # Same property as apply-is-server-side-with-force above, read off the
    # home-manager-wrapped script instead of the systemd one — the
    # manifest-seed logic itself (kubectl flags, CRD wait, namespace
    # ensure) is IDENTICAL on both platforms; only the supervisor wrapper
    # differs.
    expr =
      let
        script = lib.concatStringsSep " " (evalSeedHomeManager tmpl).launchd.agents."pleme-org-posture-seed".config.ProgramArguments;
      in
      lib.hasInfix "--server-side" script
      && lib.hasInfix "--force-conflicts" script
      && lib.hasInfix "wait --for=condition=established" script;
    expected = true;
  };

  hm-with-homeDirectory-uses-home-file-not-etc = {
    # The regression this exists to catch: environment.etc and
    # /run/secrets/* have no home-manager equivalent at all, so a caller
    # that passes homeDirectory must get a script referencing a path
    # actually materialized by `home.file`, not the nixos `/etc` one.
    expr =
      let
        withHome = kata.mkManifestSeed {
          name = "pleme-org-posture";
          manifests."10-template" = "apiVersion: v1\nkind: ConfigMap\n";
          homeDirectory = "/Users/op";
        };
        out = evalSeedHomeManager withHome;
        script = lib.concatStringsSep " " out.launchd.agents."pleme-org-posture-seed".config.ProgramArguments;
      in
      {
        scriptUsesHomePath = lib.hasInfix "/Users/op/.local/state/kata-manifest-seed/pleme-org-posture/10-template.yaml" script;
        scriptAvoidsEtc = !(lib.hasInfix "/etc/kata-manifest-seed" script);
        fileLandsUnderHomeFile = out.home.file.".local/state/kata-manifest-seed/pleme-org-posture/10-template.yaml".text;
      };
    expected = {
      scriptUsesHomePath = true;
      scriptAvoidsEtc = true;
      fileLandsUnderHomeFile = "apiVersion: v1\nkind: ConfigMap\n";
    };
  };

  hm-restart-trigger-moves-with-the-content = {
    # The home-manager peer of restart-trigger-moves-with-the-content: no
    # systemd restartTriggers field exists, so the property under test is
    # that the rendered PROGRAM (and therefore the plist home-manager
    # diffs on activation) changes when the manifest content changes.
    expr =
      let
        render = text: lib.concatStringsSep " " (evalSeedHomeManager (kata.mkManifestSeed {
          name = "trig";
          manifests."10-x" = text;
        })).launchd.agents."trig-seed".config.ProgramArguments;
      in
      render "kind: A\n" != render "kind: B\n";
    expected = true;
  };
}
