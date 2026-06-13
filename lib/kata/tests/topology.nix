# Tests — kata.topology (fleet -> nix-topology-shaped pure data + edges +
# invariants). Pure data letter: no module eval, just the projection.
{
  lib,
  iroha,
  kata,
}:
let
  domains = kata.mkDomains {
    tld = "demo.io";
    locations = {
      rio = "bristol";
      plo = "natal";
      cid = "mobile";
    };
    transports = [ "tailscale" ];
    sshUsers.rio = "ops";
    defaultSshUser = "admin";
  };

  nodes = {
    rio = {
      role = "server";
      location = "Bristol TN";
      tier = "home";
      system = "x86_64-linux";
      interfaces.enp3s0 = {
        network = "bristol-lan";
        addresses = [ "192.168.1.10" ];
      };
    };
    plo = {
      role = "server";
      location = "Natal RN";
      interfaces.enp5s0.network = "natal-lan";
    };
    # cid carries no role/location and an interface with no network — proves
    # the optional fields are omitted, not emitted as null.
    cid = {
      interfaces.en0 = { };
    };
  };

  networks = {
    bristol-lan = {
      cidr = "192.168.1.0/24";
      name = "Bristol LAN";
    };
    natal-lan.cidr = "192.168.50.0/24";
  };

  # Fake wireguard result: rio<->plo (p2p), rio<->cid (p2p). linkNamesForNode
  # is the only surface mkTopology consumes.
  wg = kata.mkWireguardLinks {
    registry = {
      rio-plo = {
        interface = "wg-rp";
        profile = "mesh";
        mtu = 1420;
        a = {
          node = "rio";
          address = "10.0.0.1/24";
          secrets.privateKey = "rio/wg/key";
        };
        b = {
          node = "plo";
          address = "10.0.0.2/24";
          secrets.privateKey = "plo/wg/key";
        };
      };
      rio-cid = {
        interface = "wg-rc";
        profile = "mesh";
        mtu = 1420;
        a = {
          node = "rio";
          address = "10.0.1.1/24";
          secrets.privateKey = "rio/wg2/key";
        };
        b = {
          node = "cid";
          address = "10.0.1.2/24";
          secrets.privateKey = "cid/wg/key";
        };
      };
    };
  };

  t = kata.mkTopology {
    inherit domains nodes networks;
    wireguard = wg;
  };

  noWg = kata.mkTopology { inherit domains nodes networks; };
in
{
  # ── node projection: fqdn from domains, role->deviceType, location->info ─
  node-fqdn-from-domains = {
    expr = t.topology.nodes.rio.fqdn;
    expected = "rio.bristol.demo.io";
  };
  node-role-becomes-deviceType = {
    expr = t.topology.nodes.rio.deviceType;
    expected = "server";
  };
  node-location-becomes-hardware-info = {
    expr = t.topology.nodes.rio.hardware.info;
    expected = "Bristol TN";
  };
  node-interfaces-carry-network-and-addresses = {
    expr = t.topology.nodes.rio.interfaces.enp3s0;
    expected = {
      network = "bristol-lan";
      addresses = [ "192.168.1.10" ];
    };
  };
  # cid: no role -> no deviceType; no location -> no hardware; iface no
  # network -> network key absent, addresses defaulted to [ ].
  node-optional-fields-omitted-not-null = {
    expr = {
      hasDeviceType = t.topology.nodes.cid ? deviceType;
      hasHardware = t.topology.nodes.cid ? hardware;
      ifaceHasNetwork = t.topology.nodes.cid.interfaces.en0 ? network;
      ifaceAddresses = t.topology.nodes.cid.interfaces.en0.addresses;
      fqdn = t.topology.nodes.cid.fqdn;
    };
    expected = {
      hasDeviceType = false;
      hasHardware = false;
      ifaceHasNetwork = false;
      ifaceAddresses = [ ];
      fqdn = "cid.mobile.demo.io";
    };
  };
  node-interface-missing-network-defaults-addresses = {
    expr = t.topology.nodes.plo.interfaces.enp5s0;
    expected = {
      network = "natal-lan";
      addresses = [ ];
    };
  };

  # ── network projection: cidr->cidrv4, name defaults to key ──────────────
  network-cidr-becomes-cidrv4 = {
    expr = t.topology.networks.bristol-lan;
    expected = {
      cidrv4 = "192.168.1.0/24";
      name = "Bristol LAN";
    };
  };
  network-name-defaults-to-key = {
    expr = t.topology.networks.natal-lan;
    expected = {
      cidrv4 = "192.168.50.0/24";
      name = "natal-lan";
    };
  };

  # ── edges derived from wireguard (undirected, deduped, sorted endpoints) ─
  edges-derived-from-wireguard = {
    expr = builtins.sort (a: b: a.via < b.via) t.edges;
    expected = [
      {
        from = "cid";
        to = "rio";
        via = "rio-cid";
      }
      {
        from = "plo";
        to = "rio";
        via = "rio-plo";
      }
    ];
  };
  edges-empty-without-wireguard = {
    expr = noWg.edges;
    expected = [ ];
  };

  # ── invariants pass on a good config ────────────────────────────────────
  invariants-pass-for-good-config = {
    expr = (iroha.mkEvalChecks { name = "t"; tests = t.invariants; }).passed;
    expected = true;
  };
  # node key not a domain host -> fails
  invariants-fail-on-non-host-node = {
    expr =
      (iroha.mkEvalChecks {
        name = "bad";
        tests =
          (kata.mkTopology {
            inherit domains networks;
            nodes = nodes // {
              ghost = {
                interfaces.eth0.network = "bristol-lan";
              };
            };
          }).invariants;
      }).passed;
    expected = false;
  };
  # interface network not declared in `networks` -> fails
  invariants-fail-on-undeclared-network = {
    expr =
      (iroha.mkEvalChecks {
        name = "bad";
        tests =
          (kata.mkTopology {
            inherit domains networks;
            nodes = {
              rio = {
                interfaces.enp3s0.network = "phantom-lan";
              };
            };
          }).invariants;
      }).passed;
    expected = false;
  };

  # ── meta counts ─────────────────────────────────────────────────────────
  meta-counts = {
    expr = t.meta;
    expected = {
      nodeCount = 3;
      networkCount = 2;
      kind = "topology";
    };
  };
  meta-network-count-zero-when-no-networks = {
    expr =
      (kata.mkTopology {
        inherit domains;
        nodes = { };
      }).meta;
    expected = {
      nodeCount = 0;
      networkCount = 0;
      kind = "topology";
    };
  };

  # ── throws ──────────────────────────────────────────────────────────────
  missing-domains-throws = {
    # `domains` is consumed lazily (only via .fqdn in node projection) — force
    # a path that touches it: the topology of a one-node fleet calls fqdn.
    expr =
      (builtins.tryEval (
        builtins.deepSeq
          (kata.mkTopology {
            nodes.rio = { };
          }).topology
          true
      )).success;
    expected = false;
  };
  nodes-non-attrs-throws = {
    # the type-check throw lives inside `nodes`; force it via meta.nodeCount
    # (which evaluates builtins.attrNames nodes).
    expr =
      (builtins.tryEval
        (kata.mkTopology {
          inherit domains;
          nodes = [ "rio" ];
        }).meta.nodeCount
      ).success;
    expected = false;
  };

  # ── defaults: nodes/networks/wireguard all omittable ────────────────────
  empty-fleet-projects-empty = {
    expr =
      let
        e = kata.mkTopology { inherit domains; };
      in
      {
        nodes = e.topology.nodes;
        networks = e.topology.networks;
        edges = e.edges;
      };
    expected = {
      nodes = { };
      networks = { };
      edges = [ ];
    };
  };
}
