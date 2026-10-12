{ inputs, lib, ... }: {
  imports = inputs.substrate.kata.selectNodeLayers {
    node = "alpha";
    layers = import ./layers.nix { inherit inputs lib; };
    selected = [
      "base"
      "server"
    ];
  };
}
