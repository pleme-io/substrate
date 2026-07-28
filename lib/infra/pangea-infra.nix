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
#
# ★★ PLATFORM-MEDIATED INFRASTRUCTURE — `mutatingVerbs`
#
#   `apply` / `destroy` / `init` here run `pangea bulk <verb>` with
#   `pkgs.opentofu` on PATH: a hand-run OpenTofu mutation against state
#   pangea-operator cannot see. The org doctrine says a human's only two
#   verbs are DECLARE and OBSERVE. A consumer retires the mutating half
#   with a typed declaration rather than deleting the app:
#
#     pangeaInfra {
#       inherit self; name = "my-infra";
#       mutatingVerbs.apply = {
#         enable    = false;
#         retiredOn = "2026-07-27";
#         executes  = "pangea bulk apply -> OpenTofu apply against S3 state";
#       };
#     }
#
#   The retired app still EXISTS and still resolves — its program becomes a
#   refusal derived from the declaration, naming the declare-and-observe
#   replacement path. Default for every verb is `enable = true`, so omitting
#   the argument changes nothing. See lib/infra/mutating-verbs.nix.
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
  };
  env = rnix-env.env;
  ruby = rnix-env.ruby;

  rubyBuild = import "${substrate}/lib/ruby-build.nix" {
    inherit pkgs;
    forgeCmd = "${forge.packages.${system}.default}/bin/forge";
    defaultGhcrToken = "";
  };

  # Typed verb retirement (★★ MODULARIZE, DON'T DELETE). Identity when every
  # verb is enabled — see lib/infra/tests/mutating-verbs-test.nix.
  mutatingVerbsLib = import ./mutating-verbs.nix { inherit (pkgs) lib; };

  # Pangea CLI wrapper — runs Pangea::CLI via bundle exec ruby -e
  pangeaWrapper = pkgs.writeShellScriptBin "pangea" ''
    exec ${env}/bin/bundle exec ruby -e "
      require 'pangea-core'
      require 'pangea/cli'
      Pangea::CLI.run
    " -- "$@"
  '';

  # Helper: write a shell script that runs pangea bulk on all templates.
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

in
{
  devShells.default = pkgs.mkShell {
    buildInputs = [
      env
      ruby
      pkgs.opentofu
      pkgs.git
      pangeaWrapper
    ] ++ devShellExtras;
    shellHook = ''
      export RUBYLIB=$PWD/lib:$RUBYLIB
      export DRY_TYPES_WARNINGS=false
      ${shellHookExtra}
    '';
  };

  # Every app below is built exactly as before; `retireApps` is the identity
  # unless a consumer declared `enable = false` for one of `verbs`.
  apps = mutatingVerbsLib.retireApps {
    inherit pkgs name mutatingVerbs;
    verbs = [ "validate" "plan" "apply" "destroy" "init" "drift" "test" "regen" ];
  } {
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

    # pending-typed-drift: this verb collapses a whole structured plan result
    # to `grep -q "changes detected"` on console text, and is a NO SHELL
    # violation besides (org rule: no bash beyond ~3 lines of glue). The typed
    # answer already exists on both sides and neither is wired here:
    #
    #   * Ruby   — `pangea drift detect` (pangea's DriftCommand) already
    #     computes a typed report with `total_changes` + `drift_severity` and
    #     already exits 1 on drift. This loop re-derives that from `plan`
    #     console output instead of calling it.
    #   * magma  — `magma plan --detailed-exitcode` returns 2 for
    #     "changes pending" and `--json` emits the structured plan; the
    #     `magma-drift` crate classifies a `Plan` into a typed `DriftReport`
    #     via `classify(&plan, &policy)`. But the `executor = "tofu"|"magma"`
    #     knob lives only in `pangea-arch-workspace.nix` — this top-level
    #     repo-as-workspace builder has NO executor seam to reuse, so routing
    #     drift through magma here means adding that seam first.
    #
    # NOT collapsed with the near-identical block in fleet-pangea-infra.nix:
    # the two are NOT byte-identical (verified). That one exports
    # PATH/RUBYLIB/DRY_TYPES_WARNINGS and calls the `pangea` wrapper; this one
    # calls `${env}/bin/bundle exec pangea` with none of that env — unlike
    # every other verb in THIS file, which gets it from `mkPangeaApp`.
    # Collapsing to one definition would change one site's behaviour;
    # parameterizing the divergence would enshrine it as intentional. Left
    # alone deliberately until the typed route above replaces both.
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
