{ inputs, ... }:
let
  fleet = import ../lib/fleet.nix { inherit inputs; };
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
