# Tests — kata.kubeconfig (typed cluster-access facts -> kubeconfig artifact).
{
  lib,
  iroha,
  kata,
}:
let
  inherit (kata) mkKubeconfig;

  # Two clusters: rio = token auth + insecure-skip-tls; vm = clientCert + CA data.
  two = mkKubeconfig {
    clusters = {
      rio = {
        server = "https://rio:6443";
        auth = {
          kind = "token";
          tokenRef = "<TOKEN_PLACEHOLDER>";
        };
        insecureSkipTlsVerify = true;
      };
      vm = {
        server = "https://10.0.0.5:6443";
        auth = {
          kind = "clientCert";
          clientCertRef = "<CRT_PLACEHOLDER>";
          clientKeyRef = "<KEY_PLACEHOLDER>";
        };
        caData = "<CA_B64>";
        namespace = "kube-system";
        user = "vm-admin";
      };
    };
  };

  # Explicit current-context.
  pinned = mkKubeconfig {
    clusters = {
      rio.server = "https://rio:6443";
      rio.auth = {
        kind = "token";
        tokenRef = "T";
      };
      vm.server = "https://vm:6443";
      vm.auth = {
        kind = "token";
        tokenRef = "U";
      };
    };
    current = "vm";
  };

  # Single cluster, all defaults (caRef path, default namespace + user).
  single = mkKubeconfig {
    clusters.solo = {
      server = "https://solo:6443";
      auth = {
        kind = "token";
        tokenRef = "S";
      };
      caRef = "/etc/k8s/ca.crt";
    };
  };

  # Helpers: pull a list entry by its `name`.
  byName = entries: n: lib.findFirst (e: e.name == n) (throw "no ${n}") entries;
in
{
  # ── both clusters land with their servers ────────────────────────────
  clusters-carry-both-servers = {
    expr = {
      rio = (byName two.config.clusters "rio").cluster.server;
      vm = (byName two.config.clusters "vm").cluster.server;
    };
    expected = {
      rio = "https://rio:6443";
      vm = "https://10.0.0.5:6443";
    };
  };

  # ── TLS flags per cluster ────────────────────────────────────────────
  insecure-skip-tls-verify-reflected = {
    expr = (byName two.config.clusters "rio").cluster.insecure-skip-tls-verify;
    expected = true;
  };
  ca-data-reflected = {
    expr = (byName two.config.clusters "vm").cluster.certificate-authority-data;
    expected = "<CA_B64>";
  };
  ca-ref-reflected = {
    expr = (byName single.config.clusters "solo").cluster.certificate-authority;
    expected = "/etc/k8s/ca.crt";
  };
  no-tls-keys-when-unset = {
    # rio has insecure (no CA keys); vm has caData (no insecure key).
    expr = {
      rioHasCa = (byName two.config.clusters "rio").cluster ? certificate-authority-data;
      vmHasInsecure = (byName two.config.clusters "vm").cluster ? insecure-skip-tls-verify;
    };
    expected = {
      rioHasCa = false;
      vmHasInsecure = false;
    };
  };

  # ── user blocks carry the right auth structure (placeholders) ────────
  token-user-carries-token-placeholder = {
    expr = (byName two.config.users "rio").user;
    expected = {
      token = "<TOKEN_PLACEHOLDER>";
    };
  };
  cert-user-carries-cert-refs = {
    # user entry name comes from spec.user = "vm-admin".
    expr = (byName two.config.users "vm-admin").user;
    expected = {
      client-certificate-data = "<CRT_PLACEHOLDER>";
      client-key-data = "<KEY_PLACEHOLDER>";
    };
  };
  user-name-defaults-to-cluster-name = {
    expr = builtins.sort builtins.lessThan (map (e: e.name) single.config.users);
    expected = [ "solo" ];
  };

  # ── contexts pair cluster + user + namespace ─────────────────────────
  context-pairs-cluster-user-namespace = {
    expr = (byName two.config.contexts "vm").context;
    expected = {
      cluster = "vm";
      user = "vm-admin";
      namespace = "kube-system";
    };
  };
  namespace-defaults-to-default = {
    expr = (byName two.config.contexts "rio").context.namespace;
    expected = "default";
  };

  # ── current-context ──────────────────────────────────────────────────
  current-context-defaults-to-first-sorted = {
    # sorted keys of {rio, vm} → rio first.
    expr = two.config."current-context";
    expected = "rio";
  };
  current-context-explicit-honored = {
    expr = pinned.config."current-context";
    expected = "vm";
  };
  current-unknown-cluster-throws = {
    expr =
      (builtins.tryEval
        (mkKubeconfig {
          clusters.a = {
            server = "https://a:6443";
            auth = {
              kind = "token";
              tokenRef = "x";
            };
          };
          current = "ghost";
        }).config."current-context"
      ).success;
    expected = false;
  };

  # ── top-level shape ──────────────────────────────────────────────────
  config-apiversion-and-kind = {
    expr = {
      inherit (two.config) apiVersion kind;
    };
    expected = {
      apiVersion = "v1";
      kind = "Config";
    };
  };

  # ── meta + contexts list ─────────────────────────────────────────────
  meta-cluster-count-current-kind = {
    expr = two.meta;
    expected = {
      clusterCount = 2;
      current = "rio";
      kind = "kubeconfig";
    };
  };
  contexts-list-is-sorted-cluster-keys = {
    expr = two.contexts;
    expected = [ "rio" "vm" ];
  };

  # ── typed throws (lazy — force the field that throws) ────────────────
  missing-server-throws = {
    expr =
      (builtins.tryEval
        (lib.head
          (mkKubeconfig {
            clusters.a = {
              auth = {
                kind = "token";
                tokenRef = "x";
              };
            };
          }).config.clusters
        ).cluster.server
      ).success;
    expected = false;
  };
  unknown-auth-kind-throws = {
    expr =
      (builtins.tryEval
        (lib.head
          (mkKubeconfig {
            clusters.a = {
              server = "https://a:6443";
              auth.kind = "oauth";
            };
          }).config.users
        ).user
      ).success;
    expected = false;
  };
  missing-auth-throws = {
    expr =
      (builtins.tryEval
        (lib.head
          (mkKubeconfig {
            clusters.a.server = "https://a:6443";
          }).config.users
        ).user
      ).success;
    expected = false;
  };
  empty-clusters-throws = {
    expr = (builtins.tryEval (mkKubeconfig { clusters = { }; }).meta.clusterCount).success;
    expected = false;
  };
  missing-clusters-throws = {
    expr = (builtins.tryEval (mkKubeconfig { }).meta.clusterCount).success;
    expected = false;
  };
  clusters-not-attrs-throws = {
    expr = (builtins.tryEval (mkKubeconfig { clusters = [ ]; }).meta.clusterCount).success;
    expected = false;
  };
  cert-missing-key-ref-throws = {
    expr =
      (builtins.tryEval
        (lib.head
          (mkKubeconfig {
            clusters.a = {
              server = "https://a:6443";
              auth = {
                kind = "clientCert";
                clientCertRef = "crt";
              };
            };
          }).config.users
        ).user.client-key-data
      ).success;
    expected = false;
  };
}
