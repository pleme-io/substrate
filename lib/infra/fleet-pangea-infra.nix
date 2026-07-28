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
#
# ★★ PLATFORM-MEDIATED INFRASTRUCTURE — `mutatingVerbs`
#
#   Same typed retirement surface as pangea-infra.nix, and the retireable set
#   additionally covers every generated `flow-<name>` app (a fleet flow runs
#   pangea underneath, so a mutating flow is a mutating verb):
#
#     fleetPangeaInfra {
#       inherit self; name = "my-infra"; flows = { deploy = { … }; };
#       mutatingVerbs.flow-deploy = {
#         enable    = false;
#         retiredOn = "2026-07-27";
#         executes  = "fleet flow run deploy -> pangea apply -> OpenTofu";
#       };
#     }
#
#   Default is `enable = true` for every verb, so omitting the argument
#   changes nothing. See lib/infra/mutating-verbs.nix.
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
  mutatingVerbs ? {},
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
    # Pin the gem-workspace interpreter to the CACHED ruby_3_3. Without
    # this it falls to the overlaid `pkgs.ruby`, which a nixpkgs bump
    # floated 3.3→3.4.9 — an un-cached interpreter that compiles from
    # source (RAM-heavy → OOM-crashes the nix daemon mid-flow-build) and
    # is ABI-incoherent with the operator's rb-sys/magnus embed
    # (imagePkgs.ruby_3_3). This is an EXPLICIT arg to ruby-nix (which
    # declares `ruby ? pkgs.ruby`), NOT an overlay override, so it does
    # not re-enter the ruby-nix fixpoint (the recursion that sank the
    # overlay-level pin attempts). Mirrors lib/build/ruby/workspace.nix.
    ruby = pkgs.ruby_3_3;
  };
  env = rnix-env.env;
  ruby = rnix-env.ruby;

  rubyBuild = import "${substrate}/lib/build/ruby/build.nix" {
    inherit pkgs;
    forgeCmd = "${forge.packages.${system}.default}/bin/forge";
    defaultGhcrToken = "";
  };

  # Typed verb retirement (★★ MODULARIZE, DON'T DELETE). Identity when every
  # verb is enabled — see lib/infra/tests/mutating-verbs-test.nix.
  mutatingVerbsLib = import ./mutating-verbs.nix { inherit (pkgs) lib; };

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

      # Always regenerate fleet.yaml from Nix (ensures flows are current)
      cp -f ${fleetYaml} fleet.yaml 2>/dev/null || cp ${fleetYaml} fleet.yaml

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

      # Always regenerate fleet.yaml from Nix (ensures flows are current)
      if [ -n "${toString fleetYaml}" ]; then
        cp -f ${fleetYaml} fleet.yaml 2>/dev/null || cp ${fleetYaml} fleet.yaml
      fi

      ${shellHookExtra}
    '';
  };

  # Every app below is built exactly as before; `retireApps` is the identity
  # unless a consumer declared `enable = false` for one of `verbs`.
  apps = mutatingVerbsLib.retireApps {
    inherit pkgs name mutatingVerbs;
    verbs = [ "flow-list" "validate" "plan" "apply" "destroy" "init" "drift" "test" "regen" ]
      ++ builtins.attrNames flowApps;
  } (flowApps // {
    # Fleet flow management
    flow-list = {
      type = "app";
      program = toString (pkgs.writeShellScript "${name}-flow-list" ''
        set -euo pipefail
        REPO_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
        cd "$REPO_ROOT"
        cp -f ${fleetYaml} fleet.yaml 2>/dev/null || cp ${fleetYaml} fleet.yaml
        ${fleetBin} flow list
      '');
    };

    # Direct pangea operations (bypass Fleet for single-template use)
    validate = mkPangeaApp { appName = "validate"; subcommand = "plan"; };
    plan = mkPangeaApp { appName = "plan"; subcommand = "plan"; };
    apply = mkPangeaApp { appName = "apply"; subcommand = "apply"; };
    destroy = mkPangeaApp { appName = "destroy"; subcommand = "destroy"; };
    init = mkPangeaApp { appName = "init"; subcommand = "init"; };

    # pending-typed-drift: see the long note on the same verb in
    # pangea-infra.nix. Same grep-on-console-text shape, same NO SHELL
    # violation, same typed replacements available and unwired
    # (`pangea drift detect` on the Ruby side; `magma plan
    # --detailed-exitcode` / `--json` + the `magma-drift` `classify` on the
    # magma side, gated on this builder gaining the `executor` seam that
    # currently exists only in pangea-arch-workspace.nix).
    #
    # This block and pangea-infra.nix's are NOT byte-identical — this one
    # exports PATH/RUBYLIB/DRY_TYPES_WARNINGS and invokes the `pangea`
    # wrapper, that one shells `bundle exec pangea` bare. Deliberately not
    # merged: one shared definition would change one site's behaviour.
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

        export PATH="${pangeaWrapper}/bin:${env}/bin:${pkgs.opentofu}/bin:${pkgs.git}/bin:$PATH"
        export RUBYLIB="$REPO_ROOT/lib:''${RUBYLIB:-}"
        export DRY_TYPES_WARNINGS=false
        for f in "$REPO_ROOT"/*.rb; do
          [ -f "$f" ] || continue
          echo "==> drift check: $(basename "$f") [namespace: $NS]"
          OUTPUT="$(pangea plan "$f" --namespace "$NS" 2>&1)"
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

    # `mkRubyRegenApp` RETURNS the app — `{ type, program }` — so there is no
    # `.regen` to select off it (build.nix's own two call sites bind it
    # directly). The stray `.regen` here evaluated to `attribute 'regen'
    # missing`, and survived because app values are lazy: `nix run .#plan`
    # never forces a sibling app, so only `nix flake check` ever saw it.
    regen = rubyBuild.mkRubyRegenApp {
      srcDir = self;
      inherit name;
    };
  });
}
