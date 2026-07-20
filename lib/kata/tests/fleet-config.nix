# Tests — kata.fleet-config (THE BLANKS schema: strictness + defaults).
{
  lib,
  iroha,
  kata,
}:
let
  good = kata.validateFleet {
    name = "demo";
    domains.tld = "demo.io";
    nodes.rio = {
      class = "nixos";
      system = "x86_64-linux";
      tags = [ "k3s" ];
      deploy = { };
    };
    caches = [
      {
        url = "https://cache.demo.io";
        publicKey = "cache.demo.io-1:KEY";
      }
    ];
  };
in
{
  defaults-applied = {
    expr = {
      backend = good.secrets.backend;
      deployMethod = good.nodes.rio.deploy.method;
      hostname = good.nodes.rio.hostname;
      apps = good.apps;
      fleetKeys = good.trust.fleetKeys;
    };
    expected = {
      backend = "sops";
      deployMethod = "deploy-rs";
      hostname = null;
      apps = { };
      fleetKeys = [ ];
    };
  };
  # ── Liveness (status / statusReason) ─────────────────────────────────
  # Backward compatibility: an existing fleet.nix that has never heard of
  # `status` still validates, and every node in it is live.
  node-status-defaults-live = {
    expr = {
      status = good.nodes.rio.status;
      reason = good.nodes.rio.statusReason;
    };
    expected = {
      status = "live";
      reason = "";
    };
  };
  node-status-down-accepted = {
    expr =
      let
        n =
          (kata.validateFleet {
            name = "demo";
            nodes.plo = {
              class = "nixos";
              system = "x86_64-linux";
              status = "down";
              statusReason = "offline 95 days — far-away site";
            };
          }).nodes.plo;
      in
      {
        inherit (n) status statusReason;
      };
    expected = {
      status = "down";
      statusReason = "offline 95 days — far-away site";
    };
  };
  bad-node-status-rejected = {
    expr =
      (builtins.tryEval
        (kata.validateFleet {
          name = "demo";
          nodes.rio = {
            class = "nixos";
            system = "x86_64-linux";
            status = "banana";
          };
        }).nodes.rio.status
      ).success;
    expected = false;
  };
  name-required = {
    expr = (builtins.tryEval (kata.validateFleet { domains.tld = "x.io"; }).name).success;
    expected = false;
  };
  unknown-top-level-key-rejected = {
    expr =
      (builtins.tryEval
        (kata.validateFleet {
          name = "demo";
          nodez = { };
        }).name
      ).success;
    expected = false;
  };
  unknown-node-key-rejected = {
    expr =
      (builtins.tryEval
        (kata.validateFleet {
          name = "demo";
          nodes.rio = {
            class = "nixos";
            system = "x86_64-linux";
            clas = "typo";
          };
        }).nodes.rio.class
      ).success;
    expected = false;
  };
  bad-class-rejected = {
    expr =
      (builtins.tryEval
        (kata.validateFleet {
          name = "demo";
          nodes.rio = {
            class = "windows";
            system = "x86_64-linux";
          };
        }).nodes.rio.class
      ).success;
    expected = false;
  };
  bad-secrets-backend-rejected = {
    expr =
      (builtins.tryEval
        (kata.validateFleet {
          name = "demo";
          secrets.backend = "vault";
        }).secrets.backend
      ).success;
    expected = false;
  };
  cache-entries-typed = {
    expr = (builtins.head good.caches).url;
    expected = "https://cache.demo.io";
  };
  module-is-class-tagged = {
    expr = kata.fleetConfigModule._class;
    expected = "kata.fleet";
  };
  node-deploy-null-by-default = {
    expr =
      (kata.validateFleet {
        name = "demo";
        nodes.cid = {
          class = "darwin";
          system = "aarch64-darwin";
        };
      }).nodes.cid.deploy;
    expected = null;
  };
}
