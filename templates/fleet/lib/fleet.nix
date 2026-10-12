{ inputs, universes }:
let
  lib = inputs.nixpkgs.lib;
  kata = inputs.substrate.kata;
  nodeLayers = import ./node-layers.nix { inherit inputs; };
  nodes = import ./nodes.nix { inherit inputs; };
  darwinNodes = import ./darwin-nodes.nix { inherit inputs; };
in
kata.mkFleet {
  config = import ../fleet.nix;
  inherit inputs universes;
  base.darwin = nodeLayers.darwinModules;
  profiles =
    lib.mapAttrs' (name: node: lib.nameValuePair "node/${name}" { imports = node.modules; }) nodes
    // lib.mapAttrs' (name: node: lib.nameValuePair "node/${name}" node.nodeDir) darwinNodes;
}
