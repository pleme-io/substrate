# kata.ssh-aliases — ssh_config Host entries derived from a fleet domains
# value (promotion of the nix repo's lib/ssh-aliases.nix, which was already
# generic — `fleet` is a parameter, the logic is fleet-shape-only).
#
# Pairs with kata.mkDomains: feed it a mkDomains result and get the full
# attrset of ssh Host aliases for every node — four addressable identities
# each (bare MagicDNS name, <host>.local mDNS, primary FQDN, one per
# transport), all sharing { user = fleet.sshUserFor host;
# disableHostKeyChecking = true; }. The output is shaped exactly like
# blackmatter.components.ssh.extraHosts, so a consumer `// `s it straight in.
#
# Exports (pure { lib }):
#
#   mkSshAliases :: {
#     fleet     :: kata.mkDomains result (required — uses .hosts, .fqdn,
#                  .fqdnOn, .transports, .sshUserFor);
#     skipHosts ? [ ]  (listOf str — hostnames to omit, e.g. self);
#   } -> attrsOf { hostname, user, disableHostKeyChecking } — keyed by every
#        emitted identity string.
{ lib }:
let
  mkSshAliases =
    {
      fleet,
      skipHosts ? [ ],
    }:
    let
      hostsToEmit = builtins.filter (h: !(builtins.elem h skipHosts)) fleet.hosts;

      mkEntry = user: hostname: {
        inherit hostname user;
        disableHostKeyChecking = true;
      };

      forHost =
        host:
        let
          user = fleet.sshUserFor host;
          bare = { ${host} = mkEntry user host; };
          lan = { "${host}.local" = mkEntry user "${host}.local"; };
          primary = { ${fleet.fqdn host} = mkEntry user (fleet.fqdn host); };
          transportFqdns = builtins.listToAttrs (
            map (t: {
              name = fleet.fqdnOn host t;
              value = mkEntry user (fleet.fqdnOn host t);
            }) fleet.transports
          );
        in
        bare // lan // primary // transportFqdns;
    in
    builtins.foldl' (acc: h: acc // forHost h) { } hostsToEmit;
in
{
  inherit mkSshAliases;
}
