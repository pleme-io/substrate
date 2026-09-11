# kata.manifest-seed — L1 fleet-standard: a declared Kubernetes MANIFEST
# reconciled onto a node's own cluster from nix, as ONE typed module factory.
#
# THE GAP this letter closes: ★★ GITOPS-NATIVE says every mutation is a commit
# a reconciler converges on, and that an imperative `kubectl apply` is an
# anti-pattern once a loop owns the target. On a node whose cluster has no Flux
# — plo's engenho — there was no loop to hand a manifest to, so manifests got
# hand-applied by an operator at a terminal. Measured 2026-09-07: the
# `InfrastructureTemplate` CR that reconciles 1005 GitHub repositories was
# hand-applied with `kubectl apply --server-side` for an entire session. It
# existed only in a shell history.
#
# This letter makes the node's OWN gitops loop that reconciler. The manifest is
# a store path derived from committed nix, so the chain is:
#
#   commit -> push -> the node's `pleme.gitops` loop pulls -> rebuild
#     -> the manifest's store path changes -> the seed unit re-runs -> applied
#
# which is a commit converged by a loop, not a command. The manifest is the
# authority; the cluster converges on it. Nothing is hand-applied, and a
# hand-poked field is reverted on the next tick — which is the point of
# writing the FULL manifest rather than a patch.
#
# ── ★ WHY SERVER-SIDE APPLY, AND WHY FORCE-CONFLICTS IS THE CORRECT DEFAULT
# `--server-side` because a controller writes `status` on the same object; a
# client-side apply's last-applied annotation fights that, while SSA's
# per-field ownership does not (the seed owns spec, the controller owns
# status, and they never collide).
#
# `--force-conflicts` because the object this letter takes over is, by
# construction, one that something else applied first — an operator at a
# terminal, with `kubectl`'s own field manager. Without the flag the first
# converging apply reports a conflict on every field and the seed fails
# permanently: gitops would be unable to adopt the very object it is being
# introduced to own. Taking ownership from a hand-applier is the intended
# transition, not an override of a peer — so it is the default, and typed so a
# consumer sharing an object with another controller can turn it off.
#
# ── ★ A CR BEFORE ITS CRD IS A HARD FAILURE, NOT A WAIT ────────────────────
# `kubectl apply` of a custom resource whose CRD is not yet established fails
# outright ("no matches for kind"). Under the shared engine's retry bound that
# becomes a unit that reddens ~5 minutes into a boot where the CRD was simply
# 20 seconds behind. `requireCrds` emits one bounded `kubectl wait
# --for=condition=established` per CRD before the applies — a wait, not a
# retry, so ordinary boot ordering stops presenting as a fault.
#
# Pure { lib } at import; `pkgs` never appears. The manifest TEXT is the
# caller's — a consumer that wants YAML generated from typed data builds it
# with a typed emitter (NIX-AST / a typed renderer) and passes the result, so
# no `format!()`-of-YAML lives here.
#
# Exports:
#
#   mkManifestSeed :: {
#     name        :: str (required) — the option leaf and `<name>-seed` unit;
#     manifests   :: attrsOf str (required, NON-EMPTY) — logical name -> the
#                     full YAML text of one manifest. Rendered to
#                     /etc/kata-manifest-seed/<name>/<key>.yaml and applied in
#                     `attrNames` order (sorted, so the apply order is
#                     deterministic rather than attrset-iteration luck);
#     namespaces  ? [ ] — namespaces created (idempotently) before the applies;
#     requireCrds ? [ ] — CRDs waited on (`condition=established`) first;
#     crdTimeout  ? 120 — seconds per CRD wait;
#     fieldManager ? "kata-manifest-seed" — the SSA field manager;
#     forceConflicts ? true — see the note above;
#     serverSide  ? true;
#     description ? "Reconcile the <name> Kubernetes manifests";
#     namespace   ? "services" / enable ? true / kubeconfig / after / wants /
#     kubectl / startLimitIntervalSec / startLimitBurst — as kata.k8s-seed;
#   } -> { nixos :: class-tagged module; meta = { name, kind, keys,
#          namespaces, requireCrds }; unitName; optionPath; }
#
# Throws (every message prefixed "kata.manifest-seed.mkManifestSeed: "):
#   - `name` missing;
#   - `manifests` missing, not an attrset, or empty;
#   - a `manifests` entry that is not a string, or is blank.
{ lib }:
let
  k8sSeed = import ./k8s-seed.nix { inherit lib; };

  errPrefix = "kata.manifest-seed.mkManifestSeed: ";

  mkManifestSeed =
    spec:
    let
      name = spec.name or (throw "${errPrefix}`name` (str) is required.");

      rawManifests =
        spec.manifests
          or (throw "${errPrefix}`manifests` (attrsOf str, non-empty) is required for seed '${name}'.");

      # ── ★ THE PER-ENTRY VALIDATION IS FORCED, NOT LAZY ──────────────────
      # `lib.mapAttrs` is lazy per value, so `attrNames` forces the attrset's
      # NAMES and never its values — which deferred every per-manifest refusal
      # to whenever the script happened to be built. Measured 2026-09-07: a
      # blank manifest and a non-string manifest both passed a `tryEval` of
      # the factory's own result. The `deepSeq` makes the refusal fire when
      # the letter is CALLED, which is the tier the doc header claims
      # (eval-rejected at the call), rather than at some later forcing nobody
      # can point at.
      manifests = builtins.deepSeq manifestsLazy manifestsLazy;

      manifestsLazy =
        if !(builtins.isAttrs rawManifests) then
          throw "${errPrefix}`manifests` must be an attrset { <key> = <yaml text>; } — got ${builtins.typeOf rawManifests} for seed '${name}'."
        else if rawManifests == { } then
          throw "${errPrefix}`manifests` must be non-empty — a seed with no manifests reports success having applied nothing (seed '${name}')."
        else
          lib.mapAttrs (
            k: v:
            if !(builtins.isString v) then
              throw "${errPrefix}manifests.${k} must be the manifest's YAML text (str) — got ${builtins.typeOf v} for seed '${name}'."
            else if lib.trim v == "" then
              throw "${errPrefix}manifests.${k} is blank — an empty manifest applies nothing while the unit reports success (seed '${name}')."
            else
              v
          ) rawManifests;

      # attrNames is sorted, so the apply order is deterministic rather than
      # whatever order the attrset happens to iterate in. A consumer that needs
      # a specific order names its keys to sort that way (`00-crd`, `10-cr`).
      keys = lib.attrNames manifests;

      namespaces = spec.namespaces or [ ];
      requireCrds = spec.requireCrds or [ ];
      crdTimeout = spec.crdTimeout or 120;
      fieldManager = spec.fieldManager or "kata-manifest-seed";
      forceConflicts = spec.forceConflicts or true;
      serverSide = spec.serverSide or true;
      kubectl = spec.kubectl or "kubectl";
      description = spec.description or "Reconcile the ${name} Kubernetes manifests";

      etcDir = "kata-manifest-seed/${name}";
      manifestPath = k: "/etc/${etcDir}/${k}.yaml";

      applyFlags = lib.concatStringsSep " " (
        lib.optional serverSide "--server-side"
        ++ lib.optional serverSide "--field-manager=${fieldManager}"
        ++ lib.optional (serverSide && forceConflicts) "--force-conflicts"
      );

      # ── the one sanctioned bash: GENERATED from typed fields, no logic ────
      # Straight-line: wait for CRDs, ensure namespaces, apply each manifest.
      # No conditionals and no loops over dynamic input — every line below is
      # emitted from a typed field, which is what the NO-SHELL law permits.
      crdWaits = lib.concatMapStringsSep "\n" (crd: ''
        ${kubectl} wait --for=condition=established --timeout=${toString crdTimeout}s crd/${crd}
      '') requireCrds;

      nsEnsures = lib.concatMapStringsSep "\n" (ns: ''
        ${kubectl} create namespace ${ns} --dry-run=client -o yaml | ${kubectl} apply -f -
      '') namespaces;

      applies = lib.concatMapStringsSep "\n" (k: ''
        ${kubectl} apply ${applyFlags} -f ${manifestPath k}
      '') keys;

      script = ''
        set -euo pipefail

        ${lib.optionalString (requireCrds != [ ]) ''
          # A CR applied before its CRD is established fails outright rather
          # than waiting, so wait explicitly: ordinary boot ordering must not
          # present as a permanent fault.
          ${crdWaits}
        ''}
        ${lib.optionalString (namespaces != [ ]) nsEnsures}
        ${applies}

        echo "kata-manifest-seed: reconciled ${toString (builtins.length keys)} manifest(s) for ${name}"
      '';

      seed = k8sSeed.mkSeedUnit {
        inherit name description script;
        namespace = spec.namespace or "services";
        enable = spec.enable or true;
        optionDescription = "Reconcile the ${name} Kubernetes manifests declared in nix onto this node's cluster (gitops-native: the manifest is the authority).";
        kubeconfig = spec.kubeconfig or "/etc/rancher/k3s/k3s.yaml";
        after = spec.after or [ "k3s.service" ];
        wants = spec.wants or [ "k3s.service" ];
        startLimitIntervalSec = spec.startLimitIntervalSec or 900;
        startLimitBurst = spec.startLimitBurst or 60;

        # ── ★★ THE TRIGGER IS THE CONTENT, NOT THE PATH ─────────────────────
        #
        # This is what makes the loop gitops: a committed manifest edit changes
        # the trigger, which re-runs the unit on the rebuild the node's gitops
        # loop performs. Without it a manifest change sits on disk unread.
        #
        # ★ CORRECTED 2026-09-11, and the bug was this exact line. It read
        # `map (k: manifestPath k) keys` while the comment above it said "the
        # store path of every manifest" — but `manifestPath` returns
        # `/etc/kata-manifest-seed/<name>/<key>.yaml`, a STABLE string that is
        # byte-identical across every possible content change. So
        # `X-Restart-Triggers` never moved, systemd never restarted the unit,
        # and the manifest updated in /etc while the cluster kept the old
        # object — forever. The guard was decorative, and it failed in exactly
        # the way its own comment predicted it would if absent.
        #
        # MEASURED on plo: `pleme-io-github-repos-seed` last ran
        # 2026-09-10 08:12:07 while generation 1366 landed 2026-09-11 16:58:03
        # and rewrote the manifest correctly. `spec.suspend` read `false` on the
        # live object and `true` on disk, with the seed owning `f:suspend` in
        # managedFields and reporting `serverside-applied`, exit 0. Every
        # surface said success; nothing had been delivered for 32 hours.
        #
        # This is almost certainly why the roteador CRs drifted to names the
        # chart stopped producing: deliveries silently stop happening, and a
        # write-once mechanism is indistinguishable from a converging one until
        # you compare timestamps.
        #
        # ★ Why a hash and not the text: `pkgs` is deliberately out of scope in
        # this file (see the header), so `writeText` is unavailable, and putting
        # the text itself in restartTriggers writes every manifest verbatim into
        # the X-Restart-Triggers store entry — ~27 KB per router CR here. The
        # hash is a pure function of the content, changes iff the content
        # changes, and stays one line long.
        restartTriggers = map (k: builtins.hashString "sha256" manifests.${k}) keys;

        extraConfig.environment.etc = lib.listToAttrs (
          map (
            k:
            lib.nameValuePair "${etcDir}/${k}.yaml" {
              text = manifests.${k};
              mode = "0444";
            }
          ) keys
        );

        inherit errPrefix;
        meta = {
          inherit
            name
            keys
            namespaces
            requireCrds
            ;
          kind = "manifest-seed";
        };
      };
    in
    seed;
in
{
  inherit mkManifestSeed;
}
