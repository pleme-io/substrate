{ inputs, ... }:
let
  lib = inputs.nixpkgs.lib;
  iroha = inputs.substrate.iroha;

  anyList = lib.mkOption {
    type = lib.types.listOf lib.types.anything;
    default = [ ];
  };
  anyAttrs = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
  };

  universes = {
    nixos.options = {
      environment.systemPackages = anyList;
      environment.etc = anyAttrs;
      systemd.services = anyAttrs;
    };
    darwin.options = {
      environment.systemPackages = anyList;
      environment.etc = anyAttrs;
      launchd.daemons = anyAttrs;
    };
    homeManager.options = {
      home.homeDirectory = lib.mkOption {
        type = lib.types.str;
        default = "/home/op";
      };
      home.packages = anyList;
      home.file = anyAttrs;
      home.activation = anyAttrs;
      launchd.agents = anyAttrs;
      systemd.user.services = anyAttrs;
      blackmatter.components.anvil.mcp.servers = anyAttrs;
    };
  };

  installedOn =
    pkgs: class:
    let
      c =
        (lib.evalModules {
          inherit class;
          modules = [
            universes.${class}
            ../modules/pleme/shared/hello.nix
            { pleme.hello.enable = true; }
          ];
          specialArgs = { inherit inputs pkgs; };
        }).config;
    in
    builtins.elem pkgs.hello (if class == "homeManager" then c.home.packages else c.environment.systemPackages);
in
{
  perSystem = { pkgs, ... }: {
    checks.hello-surface =
      (iroha.mkEvalChecks {
        name = "hello-surface";
        tests = lib.genAttrs [ "nixos" "darwin" "homeManager" ] (class: {
          expr = installedOn pkgs class;
          expected = true;
        });
      }).asCheck
        pkgs;
  };
}
