# Devenv module for Nix-only development.
#
# Provides: Nix language support and formatting hooks.
# Use for configuration repos (blackmatter-*, etc.).
#
# Usage (in a devenv shell definition):
#   imports = [ "${substrate}/lib/devenv/nix.nix" ];
{ pkgs, lib, ... }: {
  languages.nix.enable = true;

  packages = with pkgs; [
    nixpkgs-fmt
    nil
  ];

  git-hooks.hooks = {
    nixpkgs-fmt.enable = lib.mkDefault true;
  };
}
