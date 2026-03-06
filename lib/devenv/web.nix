# Devenv module for web/TypeScript development.
#
# Provides: Node.js, npm, and standard web dev tooling.
#
# Usage (in a devenv shell definition):
#   imports = [ "${substrate}/lib/devenv/web.nix" ];
{ pkgs, lib, ... }: {
  languages.javascript = {
    enable = true;
    package = lib.mkDefault pkgs.nodejs_22;
  };

  packages = with pkgs; [
    nodePackages.npm
    nodePackages.typescript
  ];

  git-hooks.hooks = {
    prettier.enable = lib.mkDefault true;
  };
}
