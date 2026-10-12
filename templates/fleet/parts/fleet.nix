{ inputs, ... }:
let
  specialArgs = { inherit inputs; };
  fleet = import ../lib/fleet.nix {
    inherit inputs;
    universes = {
      nixosSystem = args: inputs.nixpkgs.lib.nixosSystem (args // { inherit specialArgs; });
      darwinSystem = args: inputs.nix-darwin.lib.darwinSystem (args // { inherit specialArgs; });
    };
  };
in
{
  _module.args.fleet = fleet;

  flake = {
    fleetRegistry = fleet.shipping.registry;
    fleetReport = fleet.report;
    fleetSshAliases = fleet.sshAliases;
    fleetWireguard = fleet.wireguard;
  };

  perSystem = { pkgs, ... }: { checks = fleet.checksFor pkgs; };
}
