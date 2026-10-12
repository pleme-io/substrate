{ inputs }:
let
  lib = inputs.nixpkgs.lib;
  kata = inputs.substrate.kata;
  blanks = (import ../fleet.nix).nodes;

  layers = {
    pleme = [ ../modules/pleme/nixos ];
    secrets = [ inputs.sops-nix.nixosModules.sops ];
  };

  stacks = {
    fleet =
      { nodeDir, extraModules, ... }: layers.pleme ++ layers.secrets ++ [ nodeDir ] ++ extraModules;
    bare = { nodeDir, extraModules, ... }: extraModules ++ [ nodeDir ];
  };

  darwinModules = [
    ../modules/pleme/darwin
    inputs.sops-nix.darwinModules.sops
  ];

  declarer = kata.mkNodeDeclarer { inherit blanks stacks; };
in
{
  inherit layers stacks darwinModules;
  inherit (declarer) mkNode mkDarwinNode;
}
