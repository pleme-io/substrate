# Per-system Ruby workspace builder — for repos that bundle several
# path-gems (typically monorepo + submodules). Companion to
# lib/build/ruby/gem.nix which handles the single-gem case.
#
# Problem this solves:
#   When a Gemfile declares `gem "pangea-core", path: "pangea-core"`,
#   bundix's generated gemset.nix either (a) silently resolves the gem
#   against rubygems.org (breaks: pangea-core isn't published), or
#   (b) materialises it as {type = "git"; ...} for git-sourced deps,
#   which doesn't pick up local edits or submodule overrides.
#
#   The nix-community/ruby-nix builder natively supports
#   {type = "path"; path = <derivation-or-storepath>; ...} but bundix
#   doesn't emit that shape. This module bridges the gap: it takes a
#   stock bundix-produced gemset.nix plus an explicit {gemName =
#   ./relative/path} map, and rewrites the affected entries to the
#   path-gem form at evaluation time.
#
# Usage in a flake (per-system):
#   let rubyWorkspace = import "${substrate}/lib/build/ruby/workspace.nix" {
#     inherit nixpkgs system ruby-nix substrate forge;
#   };
#   in rubyWorkspace {
#     inherit self;
#     name = "quero-infrastructure";
#     pathGems = {
#       "pangea-core"     = self + /pangea-core;
#       "pangea-aws"      = self + /pangea-aws;
#       "pangea-akeyless" = self + /pangea-akeyless;
#     };
#   }
#
# Returns: { devShells, apps, env, ruby }  — same shape as gem.nix
# plus an explicit `env`/`ruby` handle for callers that need to
# compose further (e.g. mkAmiBuildPipeline shell scripts with access
# to `bundle exec rspec`).
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
  pathGems ? {},       # { "gem-name" = path-derivation-or-storepath; ... }
  gemsetPath ? "/gemset.nix",
  shellHookExtra ? "",
  devShellExtras ? [],
  # Optional explicit interpreter. Default (null) keeps the historical
  # behaviour: ruby-nix defaults to the overlaid `pkgs.ruby` (whatever the
  # pinned nixpkgs ships). Pass a PLAIN, versioned derivation (e.g.
  # `pkgs.ruby_3_3`) to pin the gem-workspace interpreter — required when an
  # embedder links libruby itself (rb-sys / magnus) and the gems must be
  # ABI-coherent with THAT interpreter, not the floating default. A plain
  # versioned ruby is not self-referential, so ruby-nix's `meta = ruby.meta`
  # passthru resolves without the infinite recursion an overlaid `ruby`
  # override would trigger.
  ruby ? null,
}:
let
  pkgs = import nixpkgs {
    inherit system;
    overlays = [ruby-nix.overlays.ruby];
  };
  lib = pkgs.lib;
  # The interpreter handed to ruby-nix's builder. null → the overlaid default.
  rubyInterp = if ruby != null then ruby else pkgs.ruby;

  # Load the bundix-generated gemset and rewrite any entry whose name
  # matches a pathGems key so ruby-nix sees it as a path source. The
  # rewrite preserves other attributes (version, dependencies, groups)
  # so bundler resolution stays correct; only `source` is replaced.
  rawGemset = import (self + gemsetPath);

  rewritten = lib.mapAttrs (gemName: entry:
    if pathGems ? ${gemName}
    then entry // {
      source = {
        type = "path";
        path = pathGems.${gemName};
      };
    }
    else entry
  ) rawGemset;

  # ruby-nix accepts gemset as EITHER a path OR a pre-evaluated attrset
  # (see github:inscapist/ruby-nix default.nix:
  # `if builtins.typeOf gemset == "set" then gemset else import gemset`).
  # Pass the rewritten attrset directly — avoids a toPretty
  # round-trip, which doesn't preserve path-type values for
  # flake-input sources (would otherwise serialize them as
  # `<derivation /nix/store/...>` strings that ruby-nix then
  # interprets as Booleans, breaking the build).
  rnix = ruby-nix.lib pkgs;
  rnix-env = rnix {
    inherit name;
    gemset = rewritten;
    ruby = rubyInterp;
  };
  env = rnix-env.env;
  rubyOut = rnix-env.ruby;

  writeShellScript = pkgs.writeShellScript;

  # Test app — runs `bundle exec rspec` inside a shell with the
  # workspace's pinned Ruby + gem set. Each pathGems entry's tree is
  # available via RUBYLIB so require 'pangea-core' works uniformly
  # from every workspace script regardless of whether the gem is a
  # top-level bundle dep or a transitive path dep.
  rubylibEntries = lib.concatStringsSep ":"
    ([ "${self}/lib" ] ++ lib.mapAttrsToList (_: p: "${p}/lib") pathGems);

  testApp = {
    type = "app";
    program = toString (writeShellScript "test-${name}" ''
      set -euo pipefail
      export PATH="${env}/bin:${rubyOut}/bin:$PATH"
      export RUBYLIB="${rubylibEntries}:''${RUBYLIB:-}"
      export DRY_TYPES_WARNINGS=false
      cd "${self}"
      exec bundle exec rspec --format documentation "$@"
    '');
  };

  devShell = pkgs.mkShell {
    buildInputs = [ env rubyOut ] ++ devShellExtras;
    shellHook = ''
      export RUBYLIB="${rubylibEntries}:''${RUBYLIB:-}"
      export DRY_TYPES_WARNINGS=false
      ${shellHookExtra}
    '';
  };

in {
  devShells.default = devShell;
  apps.test = testApp;
  # Exposed for composition — callers that want to spawn `bundle
  # exec` inside another script (e.g. Packer-driven infra apps) can
  # reach env / ruby / rubylib directly without re-deriving them.
  inherit env;
  ruby = rubyOut;
  rubylib = rubylibEntries;
}
