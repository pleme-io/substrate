{ inputs, fleet, ... }:
let
  lib = inputs.nixpkgs.lib;
  iroha = inputs.substrate.iroha;
  deploy = fleet.deployRs;
  deployable = lib.attrNames (
    lib.filterAttrs (_: n: n.deploy != null && n.status == "live") fleet.config.nodes
  );
  local = lib.attrNames (lib.filterAttrs (_: n: n.deploy == null) fleet.config.nodes);

  suite =
    lib.foldl'
      (
        acc: name:
        acc
        // {
          "${name}-is-a-deploy-target" = {
            expr = deploy.nodes ? ${name};
            expected = true;
          };
          "${name}-deploys-to-its-node-name" = {
            expr = deploy.nodes.${name}.hostname;
            expected = name;
          };
          "${name}-deploys-as-its-fleet-ssh-user" = {
            expr = deploy.nodes.${name}.sshUser;
            expected = fleet.domains.sshUserFor name;
          };
        }
      )
      {
        local-only-nodes-are-not-deploy-targets = {
          expr = lib.filter (n: deploy.nodes ? ${n}) local;
          expected = [ ];
        };
      }
      deployable;
in
{
  flake.fleetDeploy = fleet.shipping.deployRs;

  perSystem = { pkgs, ... }: {
    checks.deploy-renderer =
      (iroha.mkEvalChecks {
        name = "deploy-renderer";
        tests = suite;
      }).asCheck
        pkgs;
  };
}
