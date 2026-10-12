{ inputs, ... }:
let
  lib = inputs.nixpkgs.lib;
  iroha = inputs.substrate.iroha;

  anyList = lib.mkOption {
    type = lib.types.listOf lib.types.anything;
    default = [ ];
  };

  universe = {
    options = {
      assertions = anyList;
      time.timeZone = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
    };
  };

  evalAs =
    class: extra:
    lib.evalModules {
      inherit class;
      modules = [
        universe
        ../modules/pleme/shared/site.nix
        extra
      ];
      specialArgs = { inherit inputs; };
    };

  render = platform: extra: (evalAs platform extra).config;

  failed = c: map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);

  proofFor = platform: {
    "${platform}-renders-the-selected-zone" = {
      expr = (render platform { pleme.site.selected = "fortaleza"; }).time.timeZone;
      expected = "America/Fortaleza";
    };
    "${platform}-renders-the-default-zone" = {
      expr = (render platform { }).time.timeZone;
      expected = "UTC";
    };
    "${platform}-an-unknown-zone-is-an-eval-error" = {
      expr = (builtins.tryEval (render platform { pleme.site.selected = "atlantis"; }).time.timeZone).success;
      expected = false;
    };
    "${platform}-the-zone-is-read-only" = {
      expr = (builtins.tryEval (render platform { pleme.site.timeZone = "UTC"; }).time.timeZone).success;
      expected = false;
    };
  };

  home = render "homeManager" { pleme.site.enable = true; };
in
{
  perSystem = { pkgs, ... }: {
    checks.site-surface =
      (iroha.mkEvalChecks {
        name = "site-surface";
        tests = proofFor "nixos" // proofFor "darwin" // {
          home-manager-refuses-with-its-reason = {
            expr = map (m: lib.hasInfix "(scope:" m) (failed home);
            expected = [ true ];
          };
          home-manager-renders-nothing = {
            expr = home.time.timeZone;
            expected = null;
          };
        };
      }).asCheck
        pkgs;
  };
}
