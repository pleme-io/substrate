{ self, ... }: {
  perSystem = { pkgs, ... }: {
    checks.nix-canonical = pkgs.runCommand "nix-canonical" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
      find ${self} -name '*.nix' -print0 | xargs -0 nixfmt --strict --check
      touch $out
    '';
  };
}
