{ self, inputs, ... }: {
  perSystem = { pkgs, system, ... }: {
    checks.nix-canonical = inputs.substrate.formatterLib.mkCanonicalCheck {
      inherit pkgs;
      entry = inputs.substrate.formatters.${system}.nix;
      root = self;
      name = "nix-canonical";
    };
  };
}
