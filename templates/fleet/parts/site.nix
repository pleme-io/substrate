{ inputs, ... }:
let
  lib = inputs.nixpkgs.lib;
  iroha = inputs.substrate.iroha;

  universe = {
    options.time.timeZone = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
  };

  render =
    platform: extra:
    (lib.evalModules {
      modules = [
        universe
        ../modules/pleme/shared/site.nix
        ../modules/pleme/${platform}/site.nix
        extra
      ];
    }).config;

  proofFor = platform: {
    "${platform}-renders-the-selected-zone" = {
      expr = (render platform { pleme.site.timeZone = "America/Fortaleza"; }).time.timeZone;
      expected = "America/Fortaleza";
    };
    "${platform}-renders-the-default-zone" = {
      expr = (render platform { }).time.timeZone;
      expected = "UTC";
    };
    "${platform}-derived-zone-is-read-only" = {
      expr =
        (builtins.tryEval (render platform { pleme.site.derived.timeZone = "UTC"; }).time.timeZone).success;
      expected = false;
    };
  };
in
{
  perSystem = { pkgs, ... }: {
    checks.site-surface =
      (iroha.mkEvalChecks {
        name = "site-surface";
        tests = proofFor "nixos" // proofFor "darwin";
      }).asCheck
        pkgs;
  };
}
