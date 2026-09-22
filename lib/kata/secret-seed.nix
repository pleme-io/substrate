# kata.secret-seed — L1 fleet-standard: the sops-nix -> systemd-oneshot ->
# kubectl-apply Kubernetes Secret bootstrap pattern, as ONE typed module
# factory.
#
# THE GAP this letter closes: the bootstrap-tier "seed a K8s Secret from a
# SOPS-decrypted file on this physical node before any in-cluster secrets
# mechanism is up" pattern was hand-rolled three times on rio
# (seed-grafana-admin / seed-grafana-oidc / seed-rio-cloudflare-credentials)
# and copy-paste-DOCUMENTED as boilerplate in nodes/rio/CLAUDE.md — the
# textbook "second copy is a bug" (here, third). Each instance is the same
# shape: declare one sops.secrets per source key (mode 0400, owner root,
# decrypted to a file), a systemd oneshot ordered after k3s +
# sops-install-secrets, and an idempotent
# `kubectl create secret … --dry-run=client -o yaml | kubectl apply -f -`.
# This factory emits exactly that shape from typed data; the only bash is
# the generated, idempotent apply script (the one sanctioned bash per the
# org NO-SHELL law — it is GENERATED from typed fields, never authored).
#
# Sits ABOVE the iroha alphabet, THROUGH `kata.k8s-seed`: this letter owns the
# secret-specific half (the sops.secrets declarations and the generated
# `kubectl create secret … | kubectl apply -f -` script) and delegates the unit
# shape — option root, ordering, oneshot, and the reachable bootstrap retry
# bound — to the shared engine. `mkManifestSeed` is its sibling over the same
# engine. kata owns the SHAPE (sops -> oneshot -> kubectl); iroha owns the
# option/module mechanics.
#
# Pure { lib } at import. pkgs binds late — it never appears here; the
# emitted module reads `kubectl` from PATH via the consumer's `path`/wiring,
# and the spec's `kubectl` field is the binary placeholder the script
# invokes (consumer pins an absolute path if desired). No package is
# resolved at import or eval time.
#
# Exports (pure { lib }, zero pkgs):
#
#   mkSecretSeed :: {
#     name         :: str (required) — the seed unit (systemd.services.
#                     "<name>-seed") AND the k8s Secret metadata.name unless
#                     `secretName` is set; also the option leaf
#                     (<namespace>.<name>);
#     description ? "Seed <name> into Kubernetes" — systemd unit description;
#     namespace   ? "services" — option root: options.<namespace>.<name>.enable;
#     enable      ? true — initial value of the enable option (mkDefault);
#     secretName  ? name — the k8s Secret metadata.name;
#     k8sNamespace :: str (required) — the TARGET kubernetes namespace the
#                     Secret lands in (created idempotently first);
#     data         :: attrsOf { sopsPath :: str } (required, NON-EMPTY) —
#                     k8s Secret keys -> the SOPS secret name each maps to.
#                     For every entry the module declares
#                     `sops.secrets."<sopsPath>"` (owner root, mode 0400)
#                     materializing to a deterministic file path
#                     "/run/secrets/<sopsPath>" the oneshot reads via
#                     `--from-file=<k8sKey>=<file>`;
#     kubeconfig  ? "/etc/rancher/k3s/k3s.yaml" — KUBECONFIG for the apply;
#     secretType  ? "Opaque" — the k8s Secret `type` (--type=<>);
#     after       ? [ "k3s.service" ] — systemd ordering (the canonical rio
#                     shape also wants "sops-install-secrets.service" — pass
#                     it explicitly when you need it);
#     wants       ? [ "k3s.service" ];
#     kubectl     ? "kubectl" — the kubectl binary the script invokes; pin an
#                     absolute store path to avoid a PATH dependency;
#   } -> {
#     nixos :: class-tagged ("nixos") module (via iroha.tag) —
#               options.<namespace>.<name>.enable (mkEnableOption, default
#               `enable`) + config = mkIf cfg.enable {
#                 sops.secrets."<sopsPath>" = { owner="root"; mode="0400";
#                   path="/run/secrets/<sopsPath>"; }  (one per data entry),
#                 systemd.services."<name>-seed" = {
#                   description; after; wants; wantedBy=["multi-user.target"];
#                   restartTriggers = [ each sops path ];
#                   environment.KUBECONFIG = kubeconfig;
#                   serviceConfig = { Type="oneshot"; RemainAfterExit=true;
#                                     Restart="on-failure"; RestartSec="5s"; };
#                   script = <idempotent: ensure namespace, then
#                     kubectl create secret generic <secretName>
#                       --namespace <k8sNamespace> --type <secretType>
#                       --from-file=<k8sKey>=<file> …
#                       --dry-run=client -o yaml | kubectl apply -f - >; };
#               };
#     meta :: { name, secretName, k8sNamespace, keys = [<dataKeys sorted>],
#               kind = "secret-seed" };
#     homeManager :: class-tagged ("homeManager") module — the SAME shape as
#               `nixos` above, rendered as a `launchd.agents.<name>-seed` per
#               kata.k8s-seed's homeManager output (a per-user launchd agent,
#               not a root daemon — see that letter's header). `sops.secrets`
#               is unchanged: sops-nix ships a home-manager module exposing
#               the identical option.
#   }
#
# Throws (every message prefixed "kata.secret-seed.mkSecretSeed: "):
#   - `name` missing;
#   - `k8sNamespace` missing;
#   - `data` missing, not an attrset, or empty;
#   - a `data` entry that is not `{ sopsPath = <str>; }`.
{ lib }:
let
  k8sSeed = import ./k8s-seed.nix { inherit lib; };

  mkSecretSeed =
    spec:
    let
      name = spec.name or (throw "kata.secret-seed.mkSecretSeed: `name` (str) is required.");
      namespace = spec.namespace or "services";
      enable = spec.enable or true;
      secretName = spec.secretName or name;
      description = spec.description or "Seed ${name} into Kubernetes";
      k8sNamespace =
        spec.k8sNamespace
          or (throw "kata.secret-seed.mkSecretSeed: `k8sNamespace` (str — the target kubernetes namespace) is required for seed '${name}'.");
      kubeconfig = spec.kubeconfig or "/etc/rancher/k3s/k3s.yaml";
      # See the long note at the unit below. Overridable, but the default is
      # rio's hand-derived `bootstrapRetryBound`, not a fresh guess: 60
      # attempts at RestartSec=5s span 300s, well inside 900s, so the bound is
      # REACHABLE — a permanent fault reaches `failed` in ~5 min while a real
      # bootstrap still gets an hour of attempts. `0` would DISABLE the limit
      # rather than tighten it; pass a wider window instead.
      startLimitIntervalSec = spec.startLimitIntervalSec or 900;
      startLimitBurst = spec.startLimitBurst or 60;
      secretType = spec.secretType or "Opaque";
      after = spec.after or [ "k3s.service" ];
      wants = spec.wants or [ "k3s.service" ];
      kubectl = spec.kubectl or "kubectl";

      rawData =
        spec.data
          or (throw "kata.secret-seed.mkSecretSeed: `data` (attrsOf { sopsPath = <str>; }, non-empty) is required for seed '${name}'.");
      data =
        if !(builtins.isAttrs rawData) then
          throw "kata.secret-seed.mkSecretSeed: `data` must be an attrset { <k8sKey> = { sopsPath = <str>; }; } — got ${builtins.typeOf rawData} for seed '${name}'."
        else if rawData == { } then
          throw "kata.secret-seed.mkSecretSeed: `data` must be non-empty — a seed with no keys produces an empty Secret (seed '${name}')."
        else
          lib.mapAttrs (
            k: v:
            if !(builtins.isAttrs v) || !(v ? sopsPath) || !(builtins.isString v.sopsPath) then
              throw "kata.secret-seed.mkSecretSeed: data.${k} must be `{ sopsPath = <str>; }` — got ${builtins.typeOf v} for seed '${name}'."
            else
              { inherit (v) sopsPath; }
          ) rawData;

      dataKeys = lib.attrNames data; # attrNames is sorted — deterministic
      unitName = "${name}-seed";

      # Deterministic decrypted-file path per source secret. sops-nix lands
      # decrypted secrets under /run/secrets/<sopsPath> by default; we pin
      # that path so the oneshot reads a stable location and the
      # restartTrigger fires on rotation.
      sopsFile = sopsPath: "/run/secrets/${sopsPath}";

      # ── the one sanctioned bash: GENERATED + idempotent ────────────────
      # Per the kata/iroha law, the only bash a letter may emit is generated
      # from typed data. This is `kubectl create … --dry-run=client -o yaml |
      # kubectl apply -f -` so adds AND rotations converge with no diff.
      fromFileArgs = lib.concatMapStringsSep " " (
        k: "--from-file=${k}=${sopsFile data.${k}.sopsPath}"
      ) dataKeys;

      script = ''
        set -euo pipefail

        # Ensure the target namespace exists (idempotent — the consuming
        # HelmRelease may create it too, but we may run before flux reconciles).
        ${kubectl} create namespace ${k8sNamespace} \
          --dry-run=client -o yaml | ${kubectl} apply -f -

        # Idempotent Secret: create-dry-run rendered to yaml, then apply.
        # Re-running with rotated source files converges with no manual diff.
        ${kubectl} create secret generic ${secretName} \
          --namespace ${k8sNamespace} \
          --type ${secretType} \
          ${fromFileArgs} \
          --dry-run=client -o yaml | ${kubectl} apply -f -

        echo "kata-secret-seed: reconciled secret ${k8sNamespace}/${secretName}"
      '';

      sopsSecrets = lib.listToAttrs (
        map (
          k:
          lib.nameValuePair data.${k}.sopsPath {
            owner = "root";
            mode = "0400";
            path = sopsFile data.${k}.sopsPath;
          }
        ) dataKeys
      );

      # ── the unit shape comes from kata.k8s-seed, NOT from here ───────────
      # This letter owns the SCRIPT and the sops declarations; the oneshot,
      # the ordering, the option root and the reachable bootstrap retry bound
      # are the shared engine's. Byte-parity across that move is gated by
      # `kata-secret-seed-parity` — the 337 secret declarations on 18 nodes
      # are why the engine had to be lifted without moving a single byte of
      # this letter's output.
      seed = k8sSeed.mkSeedUnit {
        inherit
          name
          namespace
          enable
          description
          script
          kubeconfig
          after
          wants
          startLimitIntervalSec
          startLimitBurst
          ;
        optionDescription = "Seed the ${secretName} Kubernetes Secret in ${k8sNamespace} from SOPS-decrypted files (bootstrap tier).";
        # ── ★★ KNOWN DEFECT, NOT YET FIXED: `pending-secret-seed-rotation-trigger`
        #
        # `sopsFile` is `sopsPath: "/run/secrets/${sopsPath}"` (:141) — a STABLE
        # runtime path, byte-identical across every rotation of the secret it
        # names. So `X-Restart-Triggers` never moves, systemd never restarts the
        # unit, and **a rotated secret never reaches the cluster**: sops-nix
        # rewrites /run/secrets/<path> at activation while the Kubernetes Secret
        # keeps the old value, silently and indefinitely.
        #
        # This is the SAME defect measured and fixed in the sibling letter on
        # 2026-09-11 (`kata/manifest-seed.nix`, where the trigger was likewise a
        # stable /etc path and a seed had not delivered for 32 hours while
        # reporting `serverside-applied`, exit 0). It is left unfixed here only
        # because the session that found it was ending and secret seeding is not
        # a thing to change without time to verify — NOT because it is benign.
        #
        # ★ Why the manifest fix does not transplant: there, the manifest TEXT is
        # in nix, so the trigger became `builtins.hashString "sha256"` of the
        # content. Here the value is ENCRYPTED and is not available at eval time,
        # so there is nothing to hash. The fix is to trigger on the sops SOURCE
        # file's store path instead — coarse (any edit to secrets.yaml re-runs
        # every seed reading it) but correct, and coarse-and-correct beats
        # precise-and-never.
        #
        # ★ THREE LIVE CONSUMERS, so this is not hypothetical:
        #   nix/nodes/plo/github-org-posture-secret.nix   ← the GitHub App key
        #   nix/nodes/rio/akeyless-dev-operator-secret.nix
        #   nix/nodes/rio/discord-bot-secret.nix
        # The first one carries the credential that `pangea-operator`'s GitHub
        # provider authenticates with. Rotating that key today would leave the
        # cluster on the old one with every surface reporting success.
        #
        # Detection recipe, until it is fixed: compare the unit's
        # `InactiveExitTimestamp` against the activation time of the generation
        # that changed the secret. If the unit is older, nothing was delivered.
        restartTriggers = map (k: sopsFile data.${k}.sopsPath) dataKeys;
        extraConfig.sops.secrets = sopsSecrets;
        errPrefix = "kata.secret-seed.mkSecretSeed: ";
        meta = {
          inherit name secretName k8sNamespace;
          keys = dataKeys;
          kind = "secret-seed";
        };
      };

      inherit (seed) nixos homeManager meta;
    in
    {
      inherit nixos homeManager meta;
    };
in
{
  inherit mkSecretSeed;
}
