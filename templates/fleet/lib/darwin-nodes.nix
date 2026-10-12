{ inputs }:
let
  inherit (import ./node-layers.nix { inherit inputs; }) mkDarwinNode;
in
{
  beta = mkDarwinNode {
    name = "beta";
    nodeDir = ../nodes/beta;
  };
}
