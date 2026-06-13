# kata.topology — project the fleet (domains + nodes + wireguard links) into
# nix-topology-shaped pure data, so the topology renderer reads the SAME
# source of truth instead of a hand-redeclared mesh.
#
# THE GAP this letter closes: the nix repo's parts/topology.nix hand-types a
# `nodes` block (deviceType + hardware.info + interfaces.<iface>.network) and
# a `networks` block (name + cidrv4) INLINE, divorced from the kata registry
# that already owns the fleet's hosts (kata.domains) and its WireGuard mesh
# (kata.wireguard). That inline mesh drifts the moment a node is added to
# domains, or a link to the registry, but not echoed into the renderer.
# This letter is the typed projection: feed it the SAME domains + per-node
# topology metadata + networks (+ optional wireguard result) and it emits
# the exact attrset oddlama/nix-topology consumes as its `nodes` / `networks`
# module data — kept as pure data so the consumer feeds it straight into the
# nix-topology module (the renderer stays in the fleet repo; only the SHAPE
# moves here).
#
# Composes kata.domains (for per-node `fqdn` + the host set the node keys
# must belong to) and, optionally, kata.wireguard (for node-to-node `edges`
# derived from linkNamesForNode — the mesh the renderer draws). Pure data,
# zero pkgs.
#
# Exports (pure { lib }, zero pkgs):
#
#   mkTopology :: {
#     domains   :: kata.mkDomains result (required — .hosts / .fqdn used);
#     nodes     :: attrsOf {            (per-node topology metadata; keys
#                    role ? null              SHOULD be domains hosts —
#                    location ? null          enforced by an invariant)
#                    tier ? null
#                    system ? null
#                    interfaces ? attrsOf {
#                      network ? null
#                      addresses ? [ str ]
#                    }
#                  };
#     networks  ? { }  (attrsOf { cidr ? null; name ? null; }) — the fleet
#                  networks/CIDRs the interfaces reference;
#     wireguard ? null (kata.mkWireguardLinks result | null) — when set,
#                  node-to-node link edges are derived from linkNamesForNode;
#   } -> {
#     topology   :: attrs — nix-topology-shaped pure data:
#                   { nodes = { <name> = {
#                       deviceType? ;          (role, when non-null)
#                       hardware?   = { info } (location, when non-null);
#                       interfaces  = { <iface> = { network?; addresses; }; };
#                       fqdn        = domains.fqdn <name>;
#                     }; };
#                     networks = { <name> = { cidrv4?; name; }; }; };
#     edges      :: [ { from, to, via } ] — node-to-node links derived from
#                   wireguard (each link projected from both endpoints'
#                   linkNamesForNode; deduped so a link is one undirected
#                   edge). [ ] when wireguard == null;
#     invariants :: attrsOf { expr, expected } — throw-free suite:
#                     nodes-are-domain-hosts (every `nodes` key is a
#                       domains host);
#                     interface-networks-are-declared (every interface
#                       `network` is a key of `networks`);
#     meta       :: { nodeCount, networkCount, kind = "topology" };
#   }
#
# Throws (every message prefixed "kata.topology.mkTopology: "):
#   - `domains` missing (required — the host set + fqdn source);
#   - `nodes` not an attrset.
{ lib }:
let
  mkTopology =
    args:
    let
      domains =
        args.domains
          or (throw "kata.topology.mkTopology: `domains` (a kata.mkDomains result — provides .hosts and .fqdn) is required.");
      rawNodes = args.nodes or { };
      nodes =
        if builtins.isAttrs rawNodes then
          rawNodes
        else
          throw "kata.topology.mkTopology: `nodes` must be an attrset of per-node topology metadata — got ${builtins.typeOf rawNodes}.";
      networks = args.networks or { };
      wireguard = args.wireguard or null;

      nodeNames = builtins.attrNames nodes;
      networkNames = builtins.attrNames networks;

      # ── nix-topology `nodes` projection ────────────────────────────────
      # role     -> deviceType   (only when non-null)
      # location -> hardware.info (only when non-null)
      # interfaces.<iface> -> { network?; addresses = addresses or [ ]; }
      # fqdn     -> domains.fqdn <name>  (the single source of truth)
      projectIface =
        iface:
        lib.optionalAttrs ((iface.network or null) != null) { inherit (iface) network; }
        // {
          addresses = iface.addresses or [ ];
        };

      projectNode =
        name: node:
        lib.optionalAttrs ((node.role or null) != null) { deviceType = node.role; }
        // lib.optionalAttrs ((node.location or null) != null) {
          hardware.info = node.location;
        }
        // {
          interfaces = lib.mapAttrs (_: projectIface) (node.interfaces or { });
          fqdn = domains.fqdn name;
        };

      topologyNodes = lib.mapAttrs projectNode nodes;

      # ── nix-topology `networks` projection ─────────────────────────────
      # cidr -> cidrv4 (only when non-null); name -> name (defaults to key).
      projectNetwork =
        netName: net:
        lib.optionalAttrs ((net.cidr or null) != null) { cidrv4 = net.cidr; }
        // {
          name = net.name or netName;
        };

      topologyNetworks = lib.mapAttrs projectNetwork networks;

      topology = {
        nodes = topologyNodes;
        networks = topologyNetworks;
      };

      # ── edges from wireguard ───────────────────────────────────────────
      # For every node, its link names; an edge per (node, linkName). The
      # same link surfaces from both endpoints, so dedupe to one undirected
      # edge by keying on the link name and recording the two distinct
      # endpoints that name it.
      linkEndpoints =
        if wireguard == null then
          { }
        else
          builtins.foldl' (
            acc: nodeName:
            builtins.foldl' (
              acc': linkName:
              acc' // { ${linkName} = (acc'.${linkName} or [ ]) ++ [ nodeName ]; }
            ) acc (wireguard.linkNamesForNode nodeName)
          ) { } nodeNames;

      # Only links with two distinct fleet endpoints become an edge (a link
      # whose far side is a hub or a non-`nodes` host yields a single
      # endpoint here and is skipped — edges are node-to-node).
      edges =
        if wireguard == null then
          [ ]
        else
          lib.concatLists (
            lib.mapAttrsToList (
              linkName: endpoints:
              let
                pair = builtins.sort builtins.lessThan (lib.unique endpoints);
              in
              if builtins.length pair == 2 then
                [
                  {
                    from = builtins.elemAt pair 0;
                    to = builtins.elemAt pair 1;
                    via = linkName;
                  }
                ]
              else
                [ ]
            ) linkEndpoints
          );

      # ── invariants (throw-free { expr, expected } suite) ───────────────
      nonHostNodes = builtins.filter (n: !(builtins.elem n domains.hosts)) nodeNames;

      undeclaredNetworks = lib.unique (
        lib.concatLists (
          lib.mapAttrsToList (
            _: node:
            lib.concatLists (
              lib.mapAttrsToList (
                _: iface:
                lib.optional (
                  (iface.network or null) != null && !(builtins.elem iface.network networkNames)
                ) iface.network
              ) (node.interfaces or { })
            )
          ) nodes
        )
      );
    in
    {
      inherit topology edges;

      invariants = {
        nodes-are-domain-hosts = {
          expr = nonHostNodes;
          expected = [ ];
        };
        interface-networks-are-declared = {
          expr = undeclaredNetworks;
          expected = [ ];
        };
      };

      meta = {
        nodeCount = builtins.length nodeNames;
        networkCount = builtins.length networkNames;
        kind = "topology";
      };
    };
in
{
  inherit mkTopology;
}
