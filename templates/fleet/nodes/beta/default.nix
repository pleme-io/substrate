{ inputs, lib, ... }: {
  imports = inputs.substrate.kata.selectNodeLayers {
    node = "beta";
    layers = import ./layers.nix { inherit inputs lib; };
    selected = [ "base" ];
  };
}
