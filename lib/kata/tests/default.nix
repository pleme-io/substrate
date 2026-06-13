# kata test aggregator — every letter's suite, one tree (iroha harness).
#
# Inner loop:
#   nix eval --impure --expr 'let
#     fl = builtins.getFlake (toString /Users/drzzln/code/github/pleme-io/substrate);
#   in (import /Users/drzzln/code/github/pleme-io/substrate/lib/kata/tests {
#     lib = fl.inputs.nixpkgs.lib;
#   }).summary'
{ lib }:
let
  iroha = import ../../iroha { inherit lib; };
  kata = import ../. { inherit lib; };

  suiteFiles = {
    domains = ./domains.nix;
    ssh-aliases = ./ssh-aliases.nix;
    wireguard = ./wireguard.nix;
    users = ./users.nix;
    fleet-config = ./fleet-config.nix;
    fleet = ./fleet.nix;
    catalog = ./catalog.nix;
    template = ./template.nix;
  };

  suites = lib.mapAttrs (_: f: import f { inherit lib iroha kata; }) suiteFiles;
in
iroha.mkSuiteTree {
  name = "kata";
  inherit suites;
}
