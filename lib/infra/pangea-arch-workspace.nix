# substrate/lib/infra/pangea-arch-workspace.nix
#
# Canonical workspace flake helper for pangea-architectures-style
# **subdirectory** workspaces — the shape every workspace under
# `pangea-architectures/workspaces/<name>/` uses.
#
# Different from sibling helpers in this directory:
#
#   pangea-workspace.nix     — Nix-generated pangea.yml; delegates to
#                              `pangea workspace <action>` CLI. For
#                              workspaces whose entire config is a Nix
#                              expression (no .rb template authored).
#
#   pangea-infra-flake.nix   — top-level flake (one repo per workspace),
#                              calls `pangea bulk` over the repo root.
#                              For monorepo-as-workspace setups.
#
#   THIS FILE                — subdirectory workspace inside the
#                              pangea-architectures monorepo, with a
#                              hand-authored .rb template (e.g.
#                              tailnet.rb, lilitu_io.rb, quero_iam.rb).
#                              Produces nix run apps that bundle exec
#                              the matching `pangea <verb> <template>.rb`.
#
# # Usage
#
# Per-workspace flake.nix collapses to ~15 lines:
#
#   {
#     description = "pleme-io-tailnet — Tailscale tailnet IaC";
#     inputs = {
#       nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
#       flake-utils.url = "github:numtide/flake-utils";
#       substrate = { url = "github:pleme-io/substrate"; inputs.nixpkgs.follows = "nixpkgs"; };
#     };
#     outputs = { self, nixpkgs, flake-utils, substrate, ... }:
#       flake-utils.lib.eachDefaultSystem (system: let
#         pkgs = import nixpkgs { inherit system; };
#         workspace = import "${substrate}/lib/infra/pangea-arch-workspace.nix" {
#           inherit pkgs;
#         } {
#           name = "pleme-io-tailnet";
#           template = "tailnet.rb";
#           extraDeps = [ pkgs.sops ];          # for Pangea::Secrets resolution
#         };
#       in {
#         apps = workspace.apps // { default = workspace.apps.plan; };
#         devShells.default = workspace.devShell;
#       });
#   }
#
# # What gets produced
#
#   nix run .#plan      → bundle exec pangea plan <template>
#   nix run .#deploy    → bundle exec pangea apply <template>
#   nix run .#destroy   → bundle exec pangea destroy <template>
#   nix run .#synth     → bundle exec pangea synth <template>
#   nix run .#test      → bundle exec rspec spec/
#   nix run .#import    → bundle exec ruby bin/import-baseline.rb
#                         (only if the workspace ships such a script)
#
# # Secrets
#
# Secrets are NOT plumbed via env vars by this helper — workspace .rb
# templates use `Pangea::Secrets.resolve('path/to/key')` directly,
# reading from the SOPS file declared in `account.yaml` (or wired via
# `Pangea::Secrets.configure(sops_file: ...)`). This matches the
# canonical cloudflare-pleme pattern: SOPS resolution lives in Ruby,
# never in shell wrappers, never in fleet.yaml.
#
# # Stale native-extension handling
#
# bundler caches gem-native extensions against a specific Ruby store
# path. When the Nix Ruby store hash changes (e.g. a flake update),
# old extensions become invalid and `bundle install` silently leaves
# them broken. The wrapper marks `vendor/bundle/.ruby-store` and
# nukes the bundle when the store path drifts — stops mysterious
# "cannot load such file" failures across rebuilds.
{ pkgs }:

{
  # Workspace name (must match the directory it lives in). Used to label
  # the produced binaries.
  name,

  # Path to the .rb template file relative to the workspace dir.
  template,

  # AWS profile to export before any pangea/tofu invocation. Defaults to
  # the shared pleme-io account that backs the S3 state bucket.
  awsProfile ? "akeyless-development",

  # Extra runtime dependencies (nix packages) appended to the default
  # ruby+opentofu toolchain. Common adds: pkgs.sops (for Pangea::Secrets),
  # pkgs.gh, pkgs.curl, pkgs.jq.
  extraDeps ? [],

  # Verbs to expose. Defaults to all six. Drop ones you don't need by
  # passing a smaller list (e.g. [ "plan" "deploy" "test" ]).
  verbs ? [ "plan" "deploy" "destroy" "synth" "test" "import" ],

  # Ruby version. Defaults to the gemfile-pinned 3.3 that pangea-core
  # requires; bumping should be coordinated with the gem ecosystem.
  ruby ? pkgs.ruby_3_3,
}:

let
  lib = pkgs.lib;

  rubyEnv = [ ruby pkgs.opentofu ] ++ extraDeps;

  # Map verb → underlying pangea subcommand. `deploy` is operator
  # ergonomics for `apply`; `synth` is the read-only render.
  pangeaSubcommand = {
    plan    = "plan";
    deploy  = "apply";
    destroy = "destroy";
    synth   = "synth";
  };

  # The repeating prologue every wrapper runs: cd to repo root for
  # RUBYLIB, set AWS profile, nuke stale native exts, run bundle install.
  prologue = ''
    set -euo pipefail
    export AWS_PROFILE=${lib.escapeShellArg awsProfile}

    # Add repo-root lib/ to RUBYLIB so workspace-local helpers see
    # pangea-architectures/lib/* without copying gems.
    REPO_LIB="$(cd ../.. 2>/dev/null && pwd)/lib"
    [ -d "$REPO_LIB" ] && export RUBYLIB="$REPO_LIB:''${RUBYLIB:-}"

    # Drop stale gem-native extensions if the Nix Ruby store path moved.
    RUBY_STORE=$(ruby -e 'puts RbConfig::CONFIG["libdir"]')
    MARKER=vendor/bundle/.ruby-store
    if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" != "$RUBY_STORE" ]; then
      rm -rf vendor/bundle .bundle
    fi

    bundle config set --local path vendor/bundle
    bundle install --quiet 2>/dev/null
    mkdir -p vendor/bundle && echo "$RUBY_STORE" > "$MARKER"
  '';

  mkPangeaApp = verb: pkgs.writeShellApplication {
    name = "${name}-${verb}";
    runtimeInputs = rubyEnv;
    excludeShellChecks = [ "SC2086" "SC2046" ];
    text = ''
      ${prologue}
      bundle exec pangea ${pangeaSubcommand.${verb}} ${lib.escapeShellArg template} "$@"
    '';
  };

  mkTestApp = pkgs.writeShellApplication {
    name = "${name}-test";
    runtimeInputs = rubyEnv;
    excludeShellChecks = [ "SC2086" ];
    text = ''
      ${prologue}
      bundle exec rspec spec/ "$@"
    '';
  };

  # `import` runs a one-shot bin/import-baseline.rb script if present.
  # Workspaces that don't ship such a script can drop "import" from
  # the verbs list to suppress this app.
  mkImportApp = pkgs.writeShellApplication {
    name = "${name}-import";
    runtimeInputs = rubyEnv;
    excludeShellChecks = [ "SC2086" ];
    text = ''
      ${prologue}
      if [ ! -f bin/import-baseline.rb ]; then
        echo "ERROR: ${name} has no bin/import-baseline.rb — drop \"import\" from verbs list" >&2
        exit 1
      fi
      bundle exec ruby bin/import-baseline.rb "$@"
    '';
  };

  appFor = verb:
    if verb == "test" then mkTestApp
    else if verb == "import" then mkImportApp
    else mkPangeaApp verb;

  apps = lib.listToAttrs (map (verb: {
    name = verb;
    value = {
      type = "app";
      program = "${appFor verb}/bin/${name}-${verb}";
    };
  }) verbs);

in {
  # Map of verb → `nix run .#<verb>` app definition.
  inherit apps;

  # Standard dev shell — drops the operator into a shell with ruby,
  # opentofu, and any extraDeps in PATH. Useful for ad-hoc
  # `bundle exec rspec`, `bundle exec pangea ...`, etc.
  devShell = pkgs.mkShellNoCC { buildInputs = rubyEnv; };

  # Re-exported for advanced consumers that want to compose the env
  # into something larger (e.g. multi-template workspaces).
  inherit rubyEnv;
}
