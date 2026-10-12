{ inputs }:
let
  lib = inputs.nixpkgs.lib;
  kata = inputs.substrate.kata;
  nodeLayers = import ./node-layers.nix { inherit inputs; };
  nodes = import ./nodes.nix { inherit inputs; };
  darwinNodes = import ./darwin-nodes.nix { inherit inputs; };
  specialArgs = { inherit inputs; };
in
kata.mkFleet {
  config = import ../fleet.nix;
  inherit inputs;
  universes = {
    nixosSystem = args: inputs.nixpkgs.lib.nixosSystem (args // { inherit specialArgs; });
    darwinSystem = args: inputs.nix-darwin.lib.darwinSystem (args // { inherit specialArgs; });
  };
  base.darwin = nodeLayers.darwinModules;
  profiles =
    lib.mapAttrs' (name: node: lib.nameValuePair "node/${name}" { imports = node.modules; }) nodes
    // lib.mapAttrs' (name: node: lib.nameValuePair "node/${name}" node.nodeDir) darwinNodes;
}
