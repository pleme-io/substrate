# kata.domains — typed fleet-DNS structure (promotion of the nix repo's
# lib/fleet-domains.nix, which was already generic: the private instance
# stays in the fleet repo as pure arguments).
#
# Every host has a PRIMARY fqdn at its location sub-zone
# (`<host>.<location>.<tld>`) and zero-or-more transport fqdns
# (`<host>.<transport>.<tld>` — resolvable only over that transport,
# e.g. tailscale MagicDNS).
#
# Exports (pure { lib }):
#
#   mkDomains :: {
#     tld                   :: str (required — typed throw);
#     locations             ? { }  (attrsOf str — host -> primary sub-zone);
#     transports            ? [ ]  (listOf str — overlay sub-zones);
#     tailnetMagicDnsSuffix ? null (nullOr str);
#     tailnetIps            ? { }  (attrsOf str — host -> tailnet IP);
#     sshUsers              ? { }  (attrsOf str — host -> ssh login user);
#     defaultSshUser        ? "root";
#   } -> {
#     <all inputs echoed>,
#     hosts        — sorted [host];
#     sites        — sorted [location];
#     fqdn         — host -> primary FQDN (typed throw on unknown host);
#     fqdnOn       — host -> transport -> FQDN;
#     allFqdns     — host -> [primary, ...transports];
#     zoneFqdn     — location -> "<loc>.<tld>";
#     byLocation   — { <loc> = [host...]; };
#     hostsIn      — location -> [host];
#     sshUserFor   — host -> sshUsers.<host> or defaultSshUser;
#     invariants   — throw-free suite { expr, expected } (locations values
#                    are strings; tailnetIps/sshUsers keys are known hosts;
#                    transports do not collide with locations);
#     registry     — { hostCount, siteCount, transports };
#   }
{ lib }:
let
  mkDomains =
    {
      tld ? throw "kata.domains.mkDomains: `tld` (str — the root zone, e.g. \"example.org\") is required.",
      locations ? { },
      transports ? [ ],
      tailnetMagicDnsSuffix ? null,
      tailnetIps ? { },
      sshUsers ? { },
      defaultSshUser ? "root",
    }:
    let
      hosts = builtins.attrNames locations;
      sites = lib.unique (builtins.attrValues locations);

      fqdn =
        host:
        if locations ? ${host} then
          "${host}.${locations.${host}}.${tld}"
        else
          throw "kata.domains.fqdn: unknown host '${host}' — add it to `locations`.";

      fqdnOn = host: transport: "${host}.${transport}.${tld}";

      allFqdns = host: [ (fqdn host) ] ++ map (fqdnOn host) transports;

      zoneFqdn = loc: "${loc}.${tld}";

      byLocation = builtins.foldl' (
        acc: host:
        let
          loc = locations.${host};
        in
        acc // { ${loc} = (acc.${loc} or [ ]) ++ [ host ]; }
      ) { } hosts;

      hostsIn = loc: byLocation.${loc} or [ ];

      sshUserFor = host: sshUsers.${host} or defaultSshUser;

      unknownKeys = m: builtins.filter (h: !(locations ? ${h})) (builtins.attrNames m);
    in
    {
      inherit
        tld
        locations
        transports
        tailnetMagicDnsSuffix
        tailnetIps
        sshUsers
        defaultSshUser
        hosts
        sites
        fqdn
        fqdnOn
        allFqdns
        zoneFqdn
        byLocation
        hostsIn
        sshUserFor
        ;

      invariants = {
        location-values-are-strings = {
          expr = builtins.all builtins.isString (builtins.attrValues locations);
          expected = true;
        };
        tailnet-ips-name-known-hosts = {
          expr = unknownKeys tailnetIps;
          expected = [ ];
        };
        ssh-users-name-known-hosts = {
          expr = unknownKeys sshUsers;
          expected = [ ];
        };
        transports-do-not-collide-with-locations = {
          expr = builtins.filter (t: builtins.elem t sites) transports;
          expected = [ ];
        };
      };

      registry = {
        hostCount = builtins.length hosts;
        siteCount = builtins.length sites;
        inherit transports;
      };
    };
in
{
  inherit mkDomains;
}
