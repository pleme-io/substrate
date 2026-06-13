# kata (型) — the pleme-io fleet-standard layer.
#
# The mold a fleet repo is cast from. Sits ABOVE the iroha alphabet
# (substrate/lib/iroha): iroha owns composition mechanics (options,
# modules, overlays, manifests, host matrices); kata owns the SHAPE of a
# fleet — the typed blanks contract (fleet-config), the fleet registries
# (domains, users), and the one-call assembly (mkFleet). A private fleet
# repo is exactly: one kata.fleet config value + node hardware files +
# a secrets file. Instantiate a new one from substrate's `fleet`
# template (`nix flake init -t github:pleme-io/substrate#fleet`).
#
# Pure { lib } — zero pkgs at import. Import from anywhere:
#
#   kata = import "${substrate}/lib/kata" { lib = nixpkgs.lib; };
#
# Self-test: every letter ships tests/<letter>.nix in the same commit;
# the aggregate is `(import ./tests { inherit lib; })`; flake surface
# checks.<system>.kata builds it.
{ lib }:
let
  domains = import ./domains.nix { inherit lib; };
  sshAliases = import ./ssh-aliases.nix { inherit lib; };
  wireguard = import ./wireguard.nix { inherit lib; };
  kubeconfig = import ./kubeconfig.nix { inherit lib; };
  secretSeed = import ./secret-seed.nix { inherit lib; };
  topology = import ./topology.nix { inherit lib; };
  users = import ./users.nix { inherit lib; };
  fleetConfig = import ./fleet-config.nix { inherit lib; };
  fleet = import ./fleet.nix { inherit lib; };
in
domains
// sshAliases
// wireguard
// kubeconfig
// secretSeed
// topology
// users
// fleetConfig
// fleet
// {
  catalog = import ./catalog.nix { inherit lib; };
  tests = import ./tests { inherit lib; };
  version = "0.1.0";
}
