{ inputs, fleet, ... }:
let
  iroha = inputs.substrate.iroha;
  kata = inputs.substrate.kata;
in
{
  flake.darwinConfigurations = fleet.shipping.darwinConfigurations;

  perSystem = { pkgs, ... }: {
    checks.darwin-renderer =
      (iroha.mkEvalChecks {
        name = "darwin-renderer";
        tests = kata.mkLayerProof {
          class = "darwin";
          inherit (fleet.config) nodes;
          configurations = fleet.darwinConfigurations;
        };
      }).asCheck
        pkgs;
  };
}
