{ inputs }:
let
  inherit (import ./node-layers.nix { inherit inputs; }) mkNode;
  domains = inputs.substrate.kata.mkDomains (import ../fleet.nix).domains;
in
{
  alpha = mkNode {
    name = "alpha";
    hostname = domains.fqdn "alpha";
    nodeDir = ../nodes/alpha;
  };
}
