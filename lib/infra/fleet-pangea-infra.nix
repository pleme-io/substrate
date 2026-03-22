# Per-system Fleet + Pangea infrastructure builder
#
# Takes system-level dependencies, returns a function that accepts
# project config and produces { devShells, apps }.
#
# Extends pangea-infra.nix with Fleet DAG orchestration. Generates
# fleet.yaml from Nix attrsets (shikumi pattern), wraps fleet+pangea+tofu
# into nix run apps.
#
# Usage in a flake (per-system):
#   let fleetPangeaInfra = import "${substrate}/lib/infra/fleet-pangea-infra.nix" {
#     inherit nixpkgs system ruby-nix substrate forge;
#     fleet = inputs.fleet;
#     pangea = inputs.pangea;
#   };
#   in fleetPangeaInfra {
#     inherit self;
#     name = "my-infra";
#     flows = { deploy = { ... }; destroy = { ... }; };
#   }
#
# This returns: { devShells, apps }
#
# Apps produced:
#   flow-{name}   — run a named flow (e.g. flow-deploy, flow-destroy)
#   flow-list     — list all available flows
#   plan          — shortcut: pangea plan (all templates)
#   apply         — shortcut: pangea apply (all templates)
#   destroy       — shortcut: pangea destroy (all templates)
#   validate      — plan-only validation
#   test          — bundle exec rspec
#   drift         — plan in CI mode, fail if changes detected
#   regen         — regenerate Gemfile.lock + gemset.nix
{
  nixpkgs,
  system,
  ruby-nix,
  substrate,
  forge,
  fleet ? null,
  pangea ? null,
}:
{
  name,
  self,
  flows ? {},
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

  rubyBuild = import "${substrate}/lib/build/ruby/build.nix" {
    inherit pkgs;
    forgeCmd = "${forge.packages.${system}.default}/bin/forge";
    defaultGhcrToken = "";
  };

  # Resolve fleet binary: prefer flake input, fall back to PATH
  fleetBin = if fleet != null
    then "${fleet.packages.${system}.default}/bin/fleet"
    else "fleet";

  # Pangea CLI: pangea-core gem provides Pangea::CLI.
  # The wrapper inlines the require + run so it works before the gem is published.
  pangeaWrapper = pkgs.writeShellScriptBin "pangea" ''
    exec ${env}/bin/bundle exec ruby -e "
      require 'pangea-core'
      require 'pangea/cli'
      Pangea::CLI.run
    " -- "$@"
  '';

  # Generate fleet.yaml from Nix attrset (shikumi pattern: Nix → YAML → app)
  fleetYaml = pkgs.writeText "${name}-fleet.yaml" (builtins.toJSON { inherit flows; });

  # Helper: write a shell script for pangea operations
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

      export PATH="${pangeaWrapper}/bin:${env}/bin:${pkgs.opentofu}/bin:${pkgs.git}/bin:$PATH"
      export RUBYLIB="$REPO_ROOT/lib:''${RUBYLIB:-}"
      export DRY_TYPES_WARNINGS=false
      pangea bulk ${subcommand} --namespace "$NS" --dir "$REPO_ROOT" ${extraFlags}
    '');
  };

  # Helper: write a fleet flow runner app
  mkFleetApp = flowName: {
    type = "app";
    program = toString (pkgs.writeShellScript "${name}-flow-${flowName}" ''
      set -euo pipefail
      REPO_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
      cd "$REPO_ROOT"

      # Ensure fleet.yaml exists (generated from Nix or checked in)
      if [ ! -f fleet.yaml ]; then
        cp ${fleetYaml} fleet.yaml
      fi

      # Fleet calls pangea as a subprocess — put it in PATH
      export PATH="${pangeaWrapper}/bin:${env}/bin:${pkgs.opentofu}/bin:${pkgs.git}/bin:$PATH"
      export RUBYLIB="$REPO_ROOT/lib:''${RUBYLIB:-}"
      export DRY_TYPES_WARNINGS=false
      ${fleetBin} flow run ${flowName} "$@"
    '');
  };

  # Generate flow apps from the flows attrset
  flowApps = builtins.listToAttrs (
    builtins.map (flowName: {
      name = "flow-${flowName}";
      value = mkFleetApp flowName;
    }) (builtins.attrNames flows)
  );

in
{
  devShells.default = pkgs.mkShell {
    buildInputs = [
      env
      ruby
      pkgs.opentofu
      pkgs.git
      pangeaWrapper
    ] ++ (pkgs.lib.optional (fleet != null) fleet.packages.${system}.default)
      ++ devShellExtras;
    shellHook = ''
      export RUBYLIB=$PWD/lib:$RUBYLIB
      export DRY_TYPES_WARNINGS=false

      # Ensure fleet.yaml is available (Nix-generated)
      if [ ! -f fleet.yaml ] && [ -n "${toString fleetYaml}" ]; then
        cp ${fleetYaml} fleet.yaml 2>/dev/null || true
      fi

      ${shellHookExtra}
    '';
  };

  apps = flowApps // {
    # Fleet flow management
    flow-list = {
      type = "app";
      program = toString (pkgs.writeShellScript "${name}-flow-list" ''
        set -euo pipefail
        REPO_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
        cd "$REPO_ROOT"
        if [ ! -f fleet.yaml ]; then
          cp ${fleetYaml} fleet.yaml
        fi
        ${fleetBin} flow list
      '');
    };

    # Direct pangea operations (bypass Fleet for single-template use)
    validate = mkPangeaApp { appName = "validate"; subcommand = "plan"; };
    plan = mkPangeaApp { appName = "plan"; subcommand = "plan"; };
    apply = mkPangeaApp { appName = "apply"; subcommand = "apply"; };
    destroy = mkPangeaApp { appName = "destroy"; subcommand = "destroy"; };
    init = mkPangeaApp { appName = "init"; subcommand = "init"; };

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

        export PATH="${env}/bin:${pkgs.opentofu}/bin:$PATH"
        for f in "$REPO_ROOT"/*.rb; do
          [ -f "$f" ] || continue
          echo "==> drift check: $(basename "$f") [namespace: $NS]"
          OUTPUT="$(${pangeaBin} plan "$f" --namespace "$NS" 2>&1)"
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
