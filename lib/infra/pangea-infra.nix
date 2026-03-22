# Per-system Pangea infrastructure builder
#
# Takes system-level dependencies, returns a function that accepts
# project config and produces { devShells, apps }.
#
# Usage in a flake (per-system):
#   let pangeaInfra = import "${substrate}/lib/pangea-infra.nix" {
#     inherit nixpkgs system ruby-nix substrate forge;
#   };
#   in pangeaInfra {
#     inherit self;
#     name = "my-infra";
#   }
#
# This returns: { devShells, apps }
#
# Apps produced (namespace as $1 argument, falls back to pangea.yml default_namespace):
#   validate  — plan-only validation (no apply)
#   plan      — pangea plan
#   apply     — pangea apply
#   destroy   — pangea destroy
#   init      — pangea init
#   test      — bundle exec rspec
#   drift     — plan in CI mode, fail if changes detected
#   regen     — regenerate Gemfile.lock + gemset.nix
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

  # Helper: write a shell script that resolves repo root, discovers templates,
  # reads default namespace from pangea.yml, then runs a pangea subcommand.
  mkPangeaApp = { appName, subcommand, extraFlags ? "" }: {
    type = "app";
    program = toString (pkgs.writeShellScript "${name}-${appName}" ''
      set -euo pipefail
      REPO_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
      cd "$REPO_ROOT"

      NS="''${1:-}"
      if [ -z "$NS" ]; then
        NS="$(${pkgs.yq-go}/bin/yq '.default_namespace' pangea.yml)"
      fi

      TEMPLATES=()
      for f in "$REPO_ROOT"/*.rb; do
        [ -f "$f" ] && TEMPLATES+=("$f")
      done

      if [ ''${#TEMPLATES[@]} -eq 0 ]; then
        echo "Error: no .rb template files found in $REPO_ROOT" >&2
        exit 1
      fi

      for tmpl in "''${TEMPLATES[@]}"; do
        echo "==> ${subcommand}: $(basename "$tmpl") [namespace: $NS]"
        # Find pangea CLI: gem path, sibling repo, or direct bundle exec
        PANGEA_EXE="$(${env}/bin/ruby -e "
          spec = Gem::Specification.find_by_name('pangea-core') rescue nil
          puts File.join(spec.full_gem_path, spec.bindir, 'pangea') if spec&.executables&.include?('pangea')
        " 2>/dev/null)"
        if [ -z "$PANGEA_EXE" ] || [ ! -f "$PANGEA_EXE" ]; then
          PANGEA_EXE="$REPO_ROOT/../pangea-core/exe/pangea"
        fi
        if [ -f "$PANGEA_EXE" ]; then
          ${env}/bin/bundle exec ruby "$PANGEA_EXE" ${subcommand} "$tmpl" --namespace "$NS" ${extraFlags}
        else
          ${env}/bin/bundle exec pangea ${subcommand} "$tmpl" --namespace "$NS" ${extraFlags}
        fi
      done
    '');
  };

in
{
  devShells.default = pkgs.mkShell {
    buildInputs = [
      env
      ruby
      pkgs.opentofu
      pkgs.git
    ] ++ devShellExtras;
    shellHook = ''
      export RUBYLIB=$PWD/lib:$RUBYLIB
      export DRY_TYPES_WARNINGS=false
      ${shellHookExtra}
    '';
  };

  apps = {
    validate = mkPangeaApp {
      appName = "validate";
      subcommand = "plan";
    };

    plan = mkPangeaApp {
      appName = "plan";
      subcommand = "plan";
    };

    apply = mkPangeaApp {
      appName = "apply";
      subcommand = "apply";
    };

    destroy = mkPangeaApp {
      appName = "destroy";
      subcommand = "destroy";
    };

    init = mkPangeaApp {
      appName = "init";
      subcommand = "init";
    };

    drift = {
      type = "app";
      program = toString (pkgs.writeShellScript "${name}-drift" ''
        set -euo pipefail
        REPO_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
        cd "$REPO_ROOT"

        NS="''${1:-}"
        if [ -z "$NS" ]; then
          NS="$(${pkgs.yq-go}/bin/yq '.default_namespace' pangea.yml)"
        fi

        for f in "$REPO_ROOT"/*.rb; do
          [ -f "$f" ] || continue
          echo "==> drift check: $(basename "$f") [namespace: $NS]"
          OUTPUT="$(${env}/bin/bundle exec pangea plan "$f" --namespace "$NS" 2>&1)"
          echo "$OUTPUT"
          if echo "$OUTPUT" | grep -q "changes detected"; then
            echo "DRIFT DETECTED — failing" >&2
            exit 1
          fi
        done
        echo "No drift detected."
      '');
    };

    test = {
      type = "app";
      program = toString (pkgs.writeShellScript "${name}-test" ''
        set -euo pipefail
        REPO_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
        cd "$REPO_ROOT"
        ${env}/bin/bundle exec rspec --format documentation
      '');
    };

    regen = (rubyBuild.mkRubyRegenApp {
      srcDir = self;
      inherit name;
    }).regen;
  };
}
