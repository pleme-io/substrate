# Zero-boilerplate flake.nix for a single estante shell-package repo.
#
# A package author writes one flake.nix at their repo root:
#
#   {
#     description = "zsh-you-should-use ported to frost-lisp";
#     inputs = {
#       nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
#       flake-utils.url = "github:numtide/flake-utils";
#       substrate = {
#         url = "github:pleme-io/substrate";
#         inputs.nixpkgs.follows = "nixpkgs";
#       };
#     };
#     outputs = inputs: (import "${inputs.substrate}/lib/build/estante/flake.nix" {
#       inherit (inputs) nixpkgs flake-utils;
#     }) {
#       name = "zsh-you-should-use";
#       version = "1.7.4";
#       src = inputs.self;
#       description = "Reminds you of aliases you forgot you wrote.";
#       exports = [ "alias" "hook" ];
#     };
#   }
#
# The repo just needs a `rc.lisp` at the root — that's the package's
# behavior surface. Consumers `defload` it by name; this flake builds
# the derivation that lands in `materialized-path`.
{
  nixpkgs,
  flake-utils,
  ...
}: args @ {
  name,
  version,
  src,
  systems ? [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ],
  ...
}:
flake-utils.lib.eachSystem systems (system:
  let
    pkgs = import nixpkgs { inherit system; };
    estante = import ./default.nix { inherit pkgs; };
    pkg = estante.mkShellPackage (builtins.removeAttrs args [ "systems" ]);
  in {
    packages = {
      default = pkg;
      ${name} = pkg;
    };
    apps = {
      lint = {
        type = "app";
        program = "${pkgs.writeShellApplication {
          name = "estante-lint";
          text = ''
            echo "estante pkg: ${name}@${version}"
            echo "src: ${src}"
            echo "entrypoint exists: $(if [ -f "${src}/rc.lisp" ]; then echo yes; else echo NO; fi)"
          '';
        }}/bin/estante-lint";
      };
    };
  })
