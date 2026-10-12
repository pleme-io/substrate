{ lib, ... }: {
  perSystem = { config, pkgs, ... }: {
    checks.fleet-proofs = pkgs.linkFarm "fleet-proofs" (
      lib.mapAttrs (_: drv: drv) (
        builtins.removeAttrs config.checks [
          "fleet-proofs"
          "nix-canonical"
        ]
      )
    );
  };
}
