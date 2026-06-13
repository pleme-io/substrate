# Tests — kata.secret-seed (sops-nix -> systemd-oneshot -> kubectl-apply
# K8s Secret bootstrap pattern, as a typed module factory). The emitted
# `nixos` member is a class-tagged module; eval it against a STUB universe
# declaring the option paths it touches (sops.secrets + systemd.services,
# attrsOf anything) and assert the resulting config.
{
  lib,
  iroha,
  kata,
}:
let
  # Stub universe: the surface module declares the <namespace>.<name>.enable
  # option root itself; we declare the side-effect option paths the config
  # half writes into.
  universe =
    { lib, ... }:
    {
      options = {
        sops.secrets = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        systemd.services = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
      };
    };

  stubPkgs = { };

  evalSeed =
    seed: extraModules:
    (lib.evalModules {
      modules = [
        universe
        { _module.args.pkgs = stubPkgs; }
        seed.nixos
      ]
      ++ extraModules;
    }).config;

  # Canonical multi-key seed, enabled by default (mirrors rio
  # seed-grafana-admin: two source keys into one Secret).
  grafana = kata.mkSecretSeed {
    name = "grafana-admin";
    namespace = "monitoring";
    k8sNamespace = "monitoring";
    data = {
      admin-user.sopsPath = "monitoring/grafana-admin-user";
      admin-password.sopsPath = "monitoring/grafana-admin-password";
    };
  };
  grafanaCfg = evalSeed grafana [ ];

  # Single-key seed with a distinct secretName + non-default secretType +
  # explicit after/wants + custom kubeconfig + pinned kubectl.
  oidc = kata.mkSecretSeed {
    name = "grafana-oidc";
    namespace = "monitoring";
    secretName = "grafana-oidc-secret";
    secretType = "kubernetes.io/tls";
    k8sNamespace = "monitoring";
    kubeconfig = "/etc/k8s/admin.conf";
    after = [ "k3s.service" "sops-install-secrets.service" ];
    wants = [ "k3s.service" "network-online.target" ];
    kubectl = "/run/current-system/sw/bin/kubectl";
    data.client-secret.sopsPath = "monitoring/grafana-oidc-client-secret";
  };
  oidcCfg = evalSeed oidc [ ];

  # Disabled seed (enable=false) — config half must be inert.
  disabled = kata.mkSecretSeed {
    name = "off";
    namespace = "services";
    enable = false;
    k8sNamespace = "pangea-system";
    data.token.sopsPath = "cloudflare/api-token";
  };
  disabledCfg = evalSeed disabled [ ];

  # mkModuleEvalCheck returns an attrset of named {expr,expected} cases —
  # spliced into the suite via // so the class tag + an option assert are
  # checked through iroha's own module-eval harness.
  moduleEvalCases = iroha.mkModuleEvalCheck {
    name = "grafana-seed";
    class = "nixos";
    modules = [ grafana.nixos ];
    universe = [ universe ];
    specialArgs.pkgs = stubPkgs;
    asserts = [
      {
        path = [ "monitoring" "grafana-admin" "enable" ];
        expected = true;
      }
    ];
  };
in
moduleEvalCases
// {
  # ── class tag (parse-time rejection of a mismatched class) ───────────
  nixos-is-class-tagged = {
    expr = grafana.nixos._class;
    expected = "nixos";
  };

  # ── enabled: the oneshot service shape ───────────────────────────────
  service-is-oneshot-remain-after-exit = {
    expr = {
      inherit (grafanaCfg.systemd.services.grafana-admin-seed.serviceConfig) Type RemainAfterExit;
    };
    expected = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };
  service-ordering-defaults = {
    expr = {
      inherit (grafanaCfg.systemd.services.grafana-admin-seed) after wants wantedBy;
    };
    expected = {
      after = [ "k3s.service" ];
      wants = [ "k3s.service" ];
      wantedBy = [ "multi-user.target" ];
    };
  };
  service-kubeconfig-env-default = {
    expr = grafanaCfg.systemd.services.grafana-admin-seed.environment.KUBECONFIG;
    expected = "/etc/rancher/k3s/k3s.yaml";
  };
  service-kubeconfig-env-custom = {
    expr = oidcCfg.systemd.services.grafana-oidc-seed.environment.KUBECONFIG;
    expected = "/etc/k8s/admin.conf";
  };
  service-after-wants-explicit = {
    expr = {
      inherit (oidcCfg.systemd.services.grafana-oidc-seed) after wants;
    };
    expected = {
      after = [ "k3s.service" "sops-install-secrets.service" ];
      wants = [ "k3s.service" "network-online.target" ];
    };
  };

  # ── the generated script: secretName, namespace, each key, idempotent ─
  script-contains-secret-name-and-namespace = {
    expr =
      let
        s = grafanaCfg.systemd.services.grafana-admin-seed.script;
      in
      lib.hasInfix "secret generic grafana-admin" s && lib.hasInfix "--namespace monitoring" s;
    expected = true;
  };
  script-contains-every-data-key = {
    expr =
      let
        s = grafanaCfg.systemd.services.grafana-admin-seed.script;
      in
      lib.hasInfix "--from-file=admin-user=/run/secrets/monitoring/grafana-admin-user" s
      && lib.hasInfix "--from-file=admin-password=/run/secrets/monitoring/grafana-admin-password" s;
    expected = true;
  };
  script-is-idempotent-apply = {
    # create --dry-run=client -o yaml | apply -f -  (the sanctioned shape)
    expr =
      let
        s = grafanaCfg.systemd.services.grafana-admin-seed.script;
      in
      lib.hasInfix "--dry-run=client" s && lib.hasInfix "apply -f -" s;
    expected = true;
  };
  script-uses-distinct-secret-name-and-type = {
    expr =
      let
        s = oidcCfg.systemd.services.grafana-oidc-seed.script;
      in
      lib.hasInfix "secret generic grafana-oidc-secret" s
      && lib.hasInfix "--type kubernetes.io/tls" s;
    expected = true;
  };
  script-pinned-kubectl = {
    expr = lib.hasInfix "/run/current-system/sw/bin/kubectl create secret" oidcCfg.systemd.services.grafana-oidc-seed.script;
    expected = true;
  };

  # ── sops.secrets: one entry per data key, owner root, deterministic path ─
  sops-one-entry-per-data-key = {
    expr = lib.attrNames grafanaCfg.sops.secrets;
    expected = [
      "monitoring/grafana-admin-password"
      "monitoring/grafana-admin-user"
    ];
  };
  sops-entry-shape = {
    expr = grafanaCfg.sops.secrets."monitoring/grafana-admin-user";
    expected = {
      owner = "root";
      mode = "0400";
      path = "/run/secrets/monitoring/grafana-admin-user";
    };
  };
  restart-triggers-are-the-sops-paths = {
    # dataKeys = attrNames data, which is sorted — password before user.
    expr = grafanaCfg.systemd.services.grafana-admin-seed.restartTriggers;
    expected = [
      "/run/secrets/monitoring/grafana-admin-password"
      "/run/secrets/monitoring/grafana-admin-user"
    ];
  };

  # ── disabled: config half inert ──────────────────────────────────────
  disabled-no-service = {
    expr = disabledCfg.systemd.services ? off-seed;
    expected = false;
  };
  disabled-no-sops = {
    expr = disabledCfg.sops.secrets == { };
    expected = true;
  };

  # ── meta ─────────────────────────────────────────────────────────────
  meta-shape = {
    expr = grafana.meta;
    expected = {
      name = "grafana-admin";
      secretName = "grafana-admin";
      k8sNamespace = "monitoring";
      keys = [ "admin-password" "admin-user" ];
      kind = "secret-seed";
    };
  };
  meta-secret-name-distinct = {
    expr = oidc.meta.secretName;
    expected = "grafana-oidc-secret";
  };

  # ── typed throws (lazy — force a field that forces the throw) ─────────
  missing-k8s-namespace-throws = {
    expr =
      (builtins.tryEval
        (kata.mkSecretSeed {
          name = "x";
          data.k.sopsPath = "a/b";
        }).meta.k8sNamespace
      ).success;
    expected = false;
  };
  empty-data-throws = {
    expr =
      (builtins.tryEval
        (kata.mkSecretSeed {
          name = "x";
          k8sNamespace = "ns";
          data = { };
        }).meta.keys
      ).success;
    expected = false;
  };
  missing-data-throws = {
    expr =
      (builtins.tryEval
        (kata.mkSecretSeed {
          name = "x";
          k8sNamespace = "ns";
        }).meta.keys
      ).success;
    expected = false;
  };
  bad-data-entry-throws = {
    expr =
      (builtins.tryEval
        (evalSeed
          (kata.mkSecretSeed {
            name = "x";
            k8sNamespace = "ns";
            data.k = "not-an-attrset";
          })
          [ ]
        ).systemd.services.x-seed.script
      ).success;
    expected = false;
  };
  missing-name-throws = {
    expr = (builtins.tryEval (kata.mkSecretSeed { k8sNamespace = "ns"; data.k.sopsPath = "a/b"; }).meta.name).success;
    expected = false;
  };
}
