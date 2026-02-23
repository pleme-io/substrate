# Per-system Ruby gem builder (follows rust-library.nix pattern)
#
# Takes system-level dependencies, returns a function that accepts
# gem config and produces { devShells, apps }.
#
# Usage in a flake (per-system):
#   let rubyGem = import "${substrate}/lib/ruby-gem.nix" {
#     inherit nixpkgs system ruby-nix substrate forge;
#   };
#   in rubyGem {
#     inherit self;
#     name = "pangea-core";
#   }
#
# This returns: { devShells, apps }
{
  nixpkgs,
  system,
  ruby-nix,
  substrate,
  forge,
}:
{
  name,
  self,
  shellHookExtra ? "",
  devShellExtras ? [],
}:
let
  pkgs = import nixpkgs {
    inherit system;
    overlays = [ruby-nix.overlays.ruby];
  };
  rnix = ruby-nix.lib pkgs;
  rnix-env = rnix {
    inherit name;
    gemset = self + "/gemset.nix";
  };
  env = rnix-env.env;
  ruby = rnix-env.ruby;

  rubyBuild = import "${substrate}/lib/ruby-build.nix" {
    inherit pkgs;
    forgeCmd = "${forge.packages.${system}.default}/bin/forge";
    defaultGhcrToken = "";
  };
in
{
  devShells.default = pkgs.mkShell {
    buildInputs = [env ruby] ++ devShellExtras;
    shellHook = ''
      export RUBYLIB=$PWD/lib:$RUBYLIB
      export DRY_TYPES_WARNINGS=false
      ${shellHookExtra}
    '';
  };

  apps = rubyBuild.mkRubyGemApps {
    srcDir = self;
    inherit name;
  };
}
