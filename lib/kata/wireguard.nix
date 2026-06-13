# kata.wireguard — per-node WireGuard projection over a typed link registry
# (promotion of the nix repo's lib/vpn.nix, already generic — the registry
# was the only fleet-specific input, now a parameter).
#
# A link registry is an attrsOf link, where a link is one of two shapes:
#   point-to-point : { a, b, interface, profile, mtu, persistentKeepalive? }
#                    a/b = { node, address, secrets = { privateKey, psk? },
#                            persistentKeepalive? }
#   hub-and-spoke  : { hub = { publicKey?, address, advertiseCidrs?, aws? },
#                      spokes = attrsOf { interface, address, secrets =
#                        { privateKey, psk? }, persistentKeepalive? },
#                      profile, mtu, persistentKeepalive? }
# A hub-and-spoke link is only "deployable" once hub.publicKey is locked;
# until then projections skip it (no half-declared interface or secret).
#
# Every per-node helper returns the SAME shape regardless of topology, so
# the WireGuard module consumer (blackmatter-vpn) needs no shape change.
#
# Exports (pure { lib }):
#
#   mkWireguardLinks :: { registry :: attrsOf link } -> {
#     linksForNode     :: nodeName -> [ { linkName, interface, profile, mtu,
#                          self, peer, pskSecret, persistentKeepalive } ];
#     secretsForNode   :: nodeName -> [ sopsPath ] (privateKey + psk);
#     k8sLinksForNode  :: nodeName -> links whose profile has the "k8s-" prefix;
#     tlsSansForNode   :: nodeName -> [ "--tls-san=<ip>" ] for k8s links;
#     systemdDepsForNode :: nodeName -> [ "wireguard-<iface>.service" ];
#     linkNamesForNode :: nodeName -> [ linkName ];
#     hubForLink       :: linkName -> hub block | null;
#     isJitLink        :: linkName -> bool (hub-and-spoke == JIT-eligible);
#     addrFromCIDR     :: cidr -> bare IP;
#     spokeAllowedIps  :: link -> [ "<hubIp>/32", ...advertiseCidrs ];
#   }
{ lib }:
let
  mkWireguardLinks =
    { registry }:
    let
      vpnLinks = registry;

      addrFromCIDR' = cidr: builtins.head (lib.splitString "/" cidr);

      isHubAndSpoke = link: link ? hub && link ? spokes;
      isPointToPoint = link: link ? a && link ? b;

      spokeForNode =
        link: nodeName:
        let
          matches = lib.filter (sp: sp ? node && sp.node == nodeName) (
            lib.mapAttrsToList (name: spoke: spoke // { node = name; }) link.spokes
          );
        in
        if matches == [ ] then null else lib.head matches;

      isLinkDeployable =
        link: if isHubAndSpoke link then (link.hub.publicKey or null) != null else true;

      projectLink =
        nodeName: linkName: link:
        if !(isLinkDeployable link) then
          [ ]
        else if isHubAndSpoke link then
          let
            spoke = spokeForNode link nodeName;
          in
          if spoke == null then
            [ ]
          else
            [
              {
                inherit linkName;
                interface = spoke.interface;
                inherit (link) profile mtu;
                self = spoke;
                peer = link.hub // { node = "hub"; };
                pskSecret = spoke.secrets.psk or null;
                persistentKeepalive = spoke.persistentKeepalive or (link.persistentKeepalive or null);
              }
            ]
        else if isPointToPoint link then
          let
            isSideA = link.a.node == nodeName;
            isSideB = link.b.node == nodeName;
            pskSecret = if link.a ? secrets && link.a.secrets ? psk then link.a.secrets.psk else null;
            linkKeepalive = link.persistentKeepalive or null;
          in
          if isSideA then
            [
              {
                inherit linkName pskSecret;
                inherit (link) interface profile mtu;
                self = link.a;
                peer = link.b;
                persistentKeepalive = link.a.persistentKeepalive or linkKeepalive;
              }
            ]
          else if isSideB then
            [
              {
                inherit linkName pskSecret;
                inherit (link) interface profile mtu;
                self = link.b;
                peer = link.a;
                persistentKeepalive = link.b.persistentKeepalive or linkKeepalive;
              }
            ]
          else
            [ ]
        else
          [ ];

      projectLinkLite =
        nodeName: linkName: link:
        if !(isLinkDeployable link) then
          [ ]
        else if isHubAndSpoke link then
          let
            spoke = spokeForNode link nodeName;
          in
          if spoke == null then [ ] else [ { inherit (link) profile; self = spoke; } ]
        else if isPointToPoint link then
          let
            isSideA = link.a.node == nodeName;
            isSideB = link.b.node == nodeName;
          in
          if isSideA then
            [ { inherit (link) profile; self = link.a; } ]
          else if isSideB then
            [ { inherit (link) profile; self = link.b; } ]
          else
            [ ]
        else
          [ ];
    in
    {
      linksForNode = nodeName: lib.concatLists (lib.mapAttrsToList (projectLink nodeName) vpnLinks);

      secretsForNode =
        nodeName:
        lib.concatLists (
          lib.mapAttrsToList (
            linkName: link:
            if !(isLinkDeployable link) then
              [ ]
            else if isHubAndSpoke link then
              let
                spoke = spokeForNode link nodeName;
              in
              if spoke == null then
                [ ]
              else
                [ spoke.secrets.privateKey ] ++ (lib.optional (spoke.secrets ? psk) spoke.secrets.psk)
            else if isPointToPoint link then
              let
                isSideA = link.a.node == nodeName;
                isSideB = link.b.node == nodeName;
              in
              if isSideA then
                [ link.a.secrets.privateKey ]
                ++ (lib.optional (link.a ? secrets && link.a.secrets ? psk) link.a.secrets.psk)
              else if isSideB then
                [ link.b.secrets.privateKey ]
                ++ (lib.optional (link.a ? secrets && link.a.secrets ? psk) link.a.secrets.psk)
              else
                [ ]
            else
              [ ]
          ) vpnLinks
        );

      k8sLinksForNode =
        nodeName:
        builtins.filter (l: lib.hasPrefix "k8s-" l.profile) (
          lib.concatLists (lib.mapAttrsToList (projectLink nodeName) vpnLinks)
        );

      tlsSansForNode =
        nodeName:
        let
          k8sLinks = builtins.filter (l: lib.hasPrefix "k8s-" l.profile) (
            lib.concatLists (lib.mapAttrsToList (projectLinkLite nodeName) vpnLinks)
          );
        in
        map (l: "--tls-san=${addrFromCIDR' l.self.address}") k8sLinks;

      systemdDepsForNode =
        nodeName:
        let
          ifaces = lib.concatLists (
            lib.mapAttrsToList (
              linkName: link:
              if !(isLinkDeployable link) then
                [ ]
              else if isHubAndSpoke link then
                let
                  spoke = spokeForNode link nodeName;
                in
                if spoke == null then [ ] else [ spoke.interface ]
              else if isPointToPoint link then
                let
                  isSideA = link.a.node == nodeName;
                  isSideB = link.b.node == nodeName;
                in
                if isSideA || isSideB then [ link.interface ] else [ ]
              else
                [ ]
            ) vpnLinks
          );
        in
        map (iface: "wireguard-${iface}.service") ifaces;

      linkNamesForNode =
        nodeName:
        lib.concatLists (
          lib.mapAttrsToList (
            linkName: link:
            if !(isLinkDeployable link) then
              [ ]
            else if isHubAndSpoke link then
              let
                spoke = spokeForNode link nodeName;
              in
              if spoke == null then [ ] else [ linkName ]
            else if isPointToPoint link then
              let
                isSideA = link.a.node == nodeName;
                isSideB = link.b.node == nodeName;
              in
              if isSideA || isSideB then [ linkName ] else [ ]
            else
              [ ]
          ) vpnLinks
        );

      hubForLink =
        linkName:
        let
          link = vpnLinks.${linkName} or null;
        in
        if link == null then null else if isHubAndSpoke link then link.hub else null;

      isJitLink =
        linkName:
        let
          link = vpnLinks.${linkName} or null;
        in
        link != null && isHubAndSpoke link;

      addrFromCIDR = addrFromCIDR';

      spokeAllowedIps =
        link:
        let
          hubAddr = "${addrFromCIDR' link.hub.address}/32";
          extras = link.hub.advertiseCidrs or [ ];
        in
        [ hubAddr ] ++ extras;
    };
in
{
  inherit mkWireguardLinks;
}
