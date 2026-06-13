# Tests — template conformance: the shipped fleet template's blanks file
# must validate against the kata schema and assemble via mkFleet. A
# schema change that breaks the template (or vice versa) fails here —
# the template cannot drift from the vocabulary.
{
  lib,
  iroha,
  kata,
}:
let
  templateDir = ../../../templates/fleet;
  blanks = import (templateDir + "/fleet.nix");

  f = kata.mkFleet {
    config = blanks;
    universes = {
      nixosSystem = args: {
        kind = "nixos";
        inherit args;
      };
      darwinSystem = args: {
        kind = "darwin";
        inherit args;
      };
    };
    profiles.server-base = templateDir + "/profiles/server-base.nix";
  };
in
{
  template-files-exist = {
    expr = builtins.all builtins.pathExists [
      (templateDir + "/flake.nix")
      (templateDir + "/fleet.nix")
      (templateDir + "/profiles/server-base.nix")
      (templateDir + "/README.md")
    ];
    expected = true;
  };
  blanks-validate = {
    expr = f.config.name;
    expected = "example";
  };
  fleet-assembles = {
    expr = builtins.attrNames f.nixosConfigurations;
    expected = [ "alpha" ];
  };
  template-invariants-pass = {
    expr = (iroha.mkEvalChecks { name = "tpl"; tests = f.invariants; }).passed;
    expected = true;
  };
  template-deploy-data = {
    expr = f.deployRs.nodes.alpha.sshUser;
    expected = "admin";
  };
}
