{ inputs, fleet, ... }:
let
  iroha = inputs.substrate.iroha;
  kata = inputs.substrate.kata;
in
{
  flake.nixosConfigurations = fleet.shipping.nixosConfigurations;

  perSystem = { pkgs, ... }: {
    checks.nixos-renderer =
      (iroha.mkEvalChecks {
        name = "nixos-renderer";
        tests = kata.mkLayerProof {
          class = "nixos";
          inherit (fleet.config) nodes;
          configurations = fleet.nixosConfigurations;
        };
      }).asCheck
        pkgs;
  };
}
