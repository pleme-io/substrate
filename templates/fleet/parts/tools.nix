{ inputs, ... }:
let
  lib = inputs.nixpkgs.lib;
  iroha = inputs.substrate.iroha;

  anyList = lib.mkOption {
    type = lib.types.listOf lib.types.anything;
    default = [ ];
  };

  universes = {
    nixos.options = {
      assertions = anyList;
      environment.systemPackages = anyList;
    };
    darwin.options = {
      assertions = anyList;
      environment.systemPackages = anyList;
    };
    homeManager.options = {
      assertions = anyList;
      home.packages = anyList;
    };
  };

  installedOn =
    pkgs: class: enable:
    let
      c =
        (lib.evalModules {
          inherit class;
          modules = [
            universes.${class}
            ../modules/pleme/shared/tools.nix
            { pleme.tools.enable = enable; }
          ];
          specialArgs = { inherit inputs pkgs; };
        }).config;
    in
    builtins.elem pkgs.jq (if class == "homeManager" then c.home.packages else c.environment.systemPackages);

  proofFor = pkgs: class: {
    "${class}-installs-the-pinned-package" = {
      expr = installedOn pkgs class true;
      expected = true;
    };
    "${class}-installs-nothing-when-off" = {
      expr = installedOn pkgs class false;
      expected = false;
    };
  };
in
{
  perSystem = { pkgs, ... }: {
    checks.tools-surface =
      (iroha.mkEvalChecks {
        name = "tools-surface";
        tests = proofFor pkgs "nixos" // proofFor pkgs "darwin" // proofFor pkgs "homeManager";
      }).asCheck
        pkgs;
  };
}
