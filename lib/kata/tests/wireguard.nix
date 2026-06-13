# Tests — kata.wireguard (per-node projection over both link topologies).
{
  lib,
  iroha,
  kata,
}:
let
  registry = {
    # point-to-point
    alpha-beta = {
      interface = "wg-ab";
      profile = "mesh";
      mtu = 1420;
      a = {
        node = "alpha";
        address = "10.0.0.1/24";
        secrets = {
          privateKey = "alpha/wg/key";
          psk = "alpha-beta/psk";
        };
      };
      b = {
        node = "beta";
        address = "10.0.0.2/24";
        secrets.privateKey = "beta/wg/key";
      };
    };
    # k8s point-to-point (drives tls-sans)
    alpha-gamma = {
      interface = "wg-ag";
      profile = "k8s-control-plane";
      mtu = 1380;
      persistentKeepalive = 25;
      a = {
        node = "alpha";
        address = "10.1.0.1/24";
        secrets.privateKey = "alpha/wg2/key";
      };
      b = {
        node = "gamma";
        address = "10.1.0.2/24";
        secrets.privateKey = "gamma/wg/key";
      };
    };
    # hub-and-spoke, deployable (hub key locked)
    cloud = {
      profile = "egress";
      mtu = 1280;
      hub = {
        publicKey = "HUBKEY";
        address = "10.9.0.1/24";
        advertiseCidrs = [ "172.16.0.0/16" ];
        aws.region = "us-east-1";
      };
      spokes.alpha = {
        interface = "wg-cloud";
        address = "10.9.0.5/24";
        secrets = {
          privateKey = "alpha/cloud/key";
          psk = "alpha/cloud/psk";
        };
      };
    };
    # hub-and-spoke, NOT deployable (no locked hub key) — must be skipped
    pending = {
      profile = "egress";
      mtu = 1280;
      hub.address = "10.8.0.1/24";
      spokes.alpha = {
        interface = "wg-pending";
        address = "10.8.0.5/24";
        secrets.privateKey = "alpha/pending/key";
      };
    };
  };

  wg = kata.mkWireguardLinks { inherit registry; };
in
{
  links-for-node-p2p-and-spoke = {
    # alpha is on alpha-beta (a), alpha-gamma (a), cloud (spoke); pending skipped.
    expr = builtins.sort builtins.lessThan (map (l: l.linkName) (wg.linksForNode "alpha"));
    expected = [
      "alpha-beta"
      "alpha-gamma"
      "cloud"
    ];
  };
  link-self-peer-p2p = {
    expr =
      let
        l = builtins.head (builtins.filter (x: x.linkName == "alpha-beta") (wg.linksForNode "alpha"));
      in
      {
        selfNode = l.self.node;
        peerNode = l.peer.node;
        psk = l.pskSecret;
      };
    expected = {
      selfNode = "alpha";
      peerNode = "beta";
      psk = "alpha-beta/psk";
    };
  };
  link-spoke-peer-is-hub = {
    expr =
      let
        l = builtins.head (builtins.filter (x: x.linkName == "cloud") (wg.linksForNode "alpha"));
      in
      {
        peerNode = l.peer.node;
        iface = l.interface;
        psk = l.pskSecret;
      };
    expected = {
      peerNode = "hub";
      iface = "wg-cloud";
      psk = "alpha/cloud/psk";
    };
  };
  beta-side-b-peer-is-a = {
    expr =
      let
        l = builtins.head (wg.linksForNode "beta");
      in
      {
        selfNode = l.self.node;
        peerNode = l.peer.node;
      };
    expected = {
      selfNode = "beta";
      peerNode = "alpha";
    };
  };
  pending-link-skipped = {
    expr = builtins.any (l: l.linkName == "pending") (wg.linksForNode "alpha");
    expected = false;
  };
  secrets-for-node = {
    expr = builtins.sort builtins.lessThan (wg.secretsForNode "alpha");
    expected = [
      "alpha-beta/psk"
      "alpha/cloud/key"
      "alpha/cloud/psk"
      "alpha/wg/key"
      "alpha/wg2/key"
    ];
  };
  secrets-side-b-uses-side-a-psk = {
    # beta is side b of alpha-beta; psk comes from side a's canonical location.
    expr = builtins.sort builtins.lessThan (wg.secretsForNode "beta");
    expected = [
      "alpha-beta/psk"
      "beta/wg/key"
    ];
  };
  k8s-links-for-node = {
    expr = map (l: l.linkName) (wg.k8sLinksForNode "alpha");
    expected = [ "alpha-gamma" ];
  };
  tls-sans-for-node = {
    expr = wg.tlsSansForNode "alpha";
    expected = [ "--tls-san=10.1.0.1" ];
  };
  systemd-deps-for-node = {
    expr = builtins.sort builtins.lessThan (wg.systemdDepsForNode "alpha");
    expected = [
      "wireguard-wg-ab.service"
      "wireguard-wg-ag.service"
      "wireguard-wg-cloud.service"
    ];
  };
  link-names-for-node = {
    expr = builtins.sort builtins.lessThan (wg.linkNamesForNode "alpha");
    expected = [
      "alpha-beta"
      "alpha-gamma"
      "cloud"
    ];
  };
  hub-for-link = {
    expr = {
      cloud = (wg.hubForLink "cloud").region or (wg.hubForLink "cloud").aws.region;
      p2p = wg.hubForLink "alpha-beta";
    };
    expected = {
      cloud = "us-east-1";
      p2p = null;
    };
  };
  is-jit-link = {
    expr = {
      cloud = wg.isJitLink "cloud";
      p2p = wg.isJitLink "alpha-beta";
      missing = wg.isJitLink "nope";
    };
    expected = {
      cloud = true;
      p2p = false;
      missing = false;
    };
  };
  addr-from-cidr = {
    expr = wg.addrFromCIDR "10.100.1.2/24";
    expected = "10.100.1.2";
  };
  spoke-allowed-ips = {
    expr = wg.spokeAllowedIps registry.cloud;
    expected = [
      "10.9.0.1/32"
      "172.16.0.0/16"
    ];
  };
  node-not-on-any-link-empty = {
    expr = wg.linksForNode "ghost";
    expected = [ ];
  };
}
