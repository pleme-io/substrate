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
# Sits ABOVE the iroha alphabet: composes `iroha.mkOptionSurface` for the
# enable-only option root and `iroha.tag` for the NixOS class tag, rather
# than hand-typing either. kata owns the SHAPE (sops -> oneshot -> kubectl);
# iroha owns the option/module mechanics.
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
#   }
#
# Throws (every message prefixed "kata.secret-seed.mkSecretSeed: "):
#   - `name` missing;
#   - `k8sNamespace` missing;
#   - `data` missing, not an attrset, or empty;
#   - a `data` entry that is not `{ sopsPath = <str>; }`.
{ lib }:
let
  iroha = import ../iroha { inherit lib; };

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

      surface = iroha.mkOptionSurface {
        inherit name namespace;
        description = "Seed the ${secretName} Kubernetes Secret in ${k8sNamespace} from SOPS-decrypted files (bootstrap tier).";
        optionName = name;
        package = false;
      };

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

      restartTriggers = map (k: sopsFile data.${k}.sopsPath) dataKeys;

      configModule =
        { config, lib, ... }:
        let
          cfg = lib.attrByPath surface.optionPath { } config;
        in
        {
          config = lib.mkIf cfg.enable {
            sops.secrets = sopsSecrets;
            systemd.services.${unitName} = {
              inherit description after wants;
              wantedBy = [ "multi-user.target" ];
              restartTriggers = restartTriggers;
              environment.KUBECONFIG = kubeconfig;
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                Restart = "on-failure";
                RestartSec = "5s";
              };
              inherit script;
            };
          };
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

      nixos = iroha.tag "nixos" module;

      meta = {
        inherit name secretName k8sNamespace;
        keys = dataKeys;
        kind = "secret-seed";
      };
    in
    {
      inherit nixos meta;
    };
in
{
  inherit mkSecretSeed;
}
