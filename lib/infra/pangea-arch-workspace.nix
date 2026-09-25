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

  # AWS profile to export before any pangea/tofu invocation.
  #
  # NO DEFAULT ON PURPOSE. This used to carry a hardcoded account-specific
  # profile name, which meant a workspace that simply forgot to set it still
  # ran -- against whichever estate that name happened to resolve to. Silently
  # targeting the wrong AWS account is the worst failure this helper can have,
  # so when this is null the wrapper falls back to the ambient AWS_PROFILE and
  # REFUSES to run if that is empty too (see `prologue` below). Set it here, or
  # export AWS_PROFILE in the environment.
  awsProfile ? null,

  # Does this workspace need AWS at all?
  #
  # Defaults TRUE, which preserves the refusal above for every existing
  # consumer: most workspaces keep tofu state in an S3 bucket, so no AWS
  # credential means no state, and running would be worse than refusing.
  #
  # Set FALSE for a workspace that touches no AWS resource AND keeps its state
  # somewhere other than S3 (`state.type: local`, or the operator's Postgres on
  # the magma path). Measured 2026-09-24 on `pleme-io-tailnet`: every resource
  # in it targets the Tailscale API, its state had just been moved off S3, and
  # this gate still refused to run `plan` because the ambient AWS_PROFILE was
  # empty — so changing the operator's OWN tailnet required a live SSO session
  # against an unrelated cloud account. The credential was not protecting
  # anything; it was load-bearing for a state file that no longer lived there.
  #
  # This is deliberately an explicit flag rather than something derived from
  # `pangea.yml`: reading the workspace's state type at eval time would make
  # the AWS requirement depend on a YAML parse, and a requirement that can
  # silently flip is exactly what the `awsProfile` comment above refuses to
  # accept. A consumer that says "I do not need AWS" says it on purpose.
  requiresAwsProfile ? true,

  # Extra runtime dependencies (nix packages) appended to the default
  # ruby+opentofu toolchain. Common adds: pkgs.sops (for Pangea::Secrets),
  # pkgs.gh, pkgs.curl, pkgs.jq.
  extraDeps ? [],

  # Verbs to expose. Defaults to all seven. Drop ones you don't need
  # by passing a smaller list (e.g. [ "plan" "deploy" "test" ]).
  # `apply` is a tofu-native alias for `deploy` — same underlying
  # `pangea apply <template>` invocation, just the name operators
  # familiar with terraform/tofu reach for instinctively.
  verbs ? [ "plan" "deploy" "apply" "destroy" "synth" "test" "test-magma" "import" ],

  # Workspace-specific extra apps beyond the canonical six. Use for
  # AMI build/sweep/commission/verify steps that aren't a pangea verb.
  # Each entry: { command = "<shell command>"; runtimeInputs ? []; }
  # The command runs inside the same prologue (cd to workspace, AWS
  # profile, RUBYLIB, bundle install) the standard verbs use.
  #
  # Example:
  #   extraApps = {
  #     build-ami = {
  #       command = "bundle exec ruby bin/build_ami.rb \"$@\"";
  #     };
  #     sweep = {
  #       command = "bundle exec ruby bin/sweep_amis.rb \"$@\"";
  #       runtimeInputs = [ pkgs.awscli2 ];
  #     };
  #   };
  extraApps ? {},

  # Ruby version. Defaults to the gemfile-pinned 3.3 that pangea-core
  # requires; bumping should be coordinated with the gem ecosystem.
  ruby ? pkgs.ruby_3_3,

  # Executor to use for plan/deploy/apply/destroy. Default is "tofu":
  # `bundle exec pangea <verb> <template>` shells to opentofu. Setting
  # to "magma" switches to the pleme-io Rust-native executor — Pangea
  # Ruby still synthesizes the JSON, magma consumes it. M0 path uses a
  # disk intermediary at `.pangea/rendered.tf.json`; the in-memory
  # magnus-driven flow (theory/MAGMA.md §II.9) lands once magma's
  # `magnus` feature is wired into the helper.
  #
  # When executor == "magma", the consumer must thread the magma
  # package into the helper via `magmaPackage`.
  executor ? "tofu",

  # Magma package (required when executor == "magma"). Thread via the
  # consumer flake's magma input: `magmaPackage = magma.packages.${system}.default;`.
  magmaPackage ? null,

  # Capability requirements for this workspace. Validated at eval time
  # against the selected executor via substrate/lib/infra/pangea-backend.nix.
  # Failing to satisfy a requirement raises a typed Nix error before
  # any apps are produced — operator can't accidentally run a
  # tofu-incompatible workspace under tofu.
  #
  # Recognized keys:
  #   feature        — string, one of "in_memory_pipeline" | "workspace_chain"
  #   input_format   — string, one of "hcl2" | "terraform-json" | "pangea-ruby-inprocess"
  #
  # Example: a Pangea-Ruby workspace that relies on in-memory chains:
  #   requires = { feature = "in_memory_pipeline"; input_format = "pangea-ruby-inprocess"; };
  requires ? { },
}:

let
  lib = pkgs.lib;

  isMagma = executor == "magma";

  # Build the typed backend selector via substrate's central helper.
  # Single source of truth for both validation + capability probing.
  backend = (import ./pangea-backend.nix { inherit pkgs; }) {
    name         = executor;
    magmaPackage = magmaPackage;
    tofuPackage  = pkgs.opentofu;
  };

  # Verify the chosen executor supports every requirement the workspace
  # declares. Fails the eval with a typed error on mismatch.
  _verifyResult = backend.verify { inherit requires; };

  rubyEnv =
    [ ruby ]
    ++ backend.runtimeInputs
    ++ extraDeps;

  # Map verb → underlying pangea subcommand. `deploy` and `apply` both
  # resolve to `pangea apply` — `deploy` is the original operator
  # ergonomics (matches the .#flow-deploy-* convention in root flakes),
  # `apply` is a tofu-native alias for the same operation.
  # `synth` is the read-only render.
  pangeaSubcommand = {
    plan    = "plan";
    deploy  = "apply";
    apply   = "apply";
    destroy = "destroy";
    synth   = "synth";
  };

  # The repeating prologue every wrapper runs: cd to repo root for
  # RUBYLIB, set AWS profile, nuke stale native exts, run bundle install.
  prologue = ''
    set -euo pipefail
    ${
      if !requiresAwsProfile
      then ''
        # This workspace declared requiresAwsProfile = false: no AWS resource,
        # no S3 state. Neither export nor demand a profile — an AWS_PROFILE that
        # is merely ambient would make the run look account-scoped when nothing
        # in it reads AWS at all.
        :
      ''
      else if awsProfile != null
      then ''export AWS_PROFILE=${lib.escapeShellArg awsProfile}''
      else ''
        if [ -z "''${AWS_PROFILE:-}" ]; then
          echo "error: no AWS profile. Pass awsProfile to the workspace helper," >&2
          echo "       export AWS_PROFILE before running this app, or — if this" >&2
          echo "       workspace touches no AWS resource and keeps its state off" >&2
          echo "       S3 — pass requiresAwsProfile = false." >&2
          exit 2
        fi
      ''
    }

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

    # ── ★ NEVER DISCARD BUNDLER'S STDERR ────────────────────────────────────
    # This was `bundle install --quiet 2>/dev/null`. With `set -euo pipefail`
    # above, a failing install exited with bundler's code and printed NOTHING,
    # so every wrapper in this helper could die silently on a dependency
    # problem. Measured 2026-09-24 on `pleme-io-tailnet`: `nix run .#plan`
    # exited 6 with an empty log, twice, and the cause was unknowable from the
    # outside — the redirect threw away the only description of the failure.
    #
    # `--quiet` stays (it suppresses the routine per-gem chatter on SUCCESS).
    # The stderr redirect does not: keep the output, and on failure say which
    # step died before propagating the code, because an exit status with no
    # message is the most expensive shape a build step can have.
    # `$?` inside `if ! cmd; then` is the INVERTED status (always 0), which is
    # the same read-a-value-through-a-transforming-construct bug as the
    # redirect this block replaced — the first draft of it reported
    # "failed (exit 0)". Capture the real status with `set +e` around the call.
    set +e
    bundle install --quiet
    bundle_rc=$?
    set -e
    if [ "$bundle_rc" -ne 0 ]; then
      echo "error: bundle install failed (exit $bundle_rc) in $(pwd)." >&2
      echo "       The gem set for this workspace could not be resolved;" >&2
      echo "       bundler's own message is above." >&2
      exit "$bundle_rc"
    fi

    mkdir -p vendor/bundle && echo "$RUBY_STORE" > "$MARKER"
  '';

  # Map verb → magma subcommand. Pangea Ruby still renders the JSON
  # (via `pangea synth`); magma consumes it. For executor=magma, the
  # `synth` verb stays Pangea-only (it doesn't need an executor).
  magmaSubcommand = {
    plan    = "plan";
    deploy  = "apply";
    apply   = "apply";
    destroy = "destroy";
    # synth is handled separately (Pangea-only render).
  };

  mkPangeaApp = verb: pkgs.writeShellApplication {
    name = "${name}-${verb}";
    runtimeInputs = rubyEnv;
    excludeShellChecks = [ "SC2086" "SC2046" ];
    text = ''
      ${prologue}
      bundle exec pangea ${pangeaSubcommand.${verb}} ${lib.escapeShellArg template} "$@"
    '';
  };

  # Magma executor app: Pangea Ruby synthesizes to a disk intermediary,
  # magma consumes it. Per theory/MAGMA.md §VI.M5, this is the
  # workspace-level migration path — opt in workspace-by-workspace,
  # keep tofu as the fallback. In-memory magnus flow (no disk file)
  # lands once magma's `magnus` feature is consumed here.
  mkMagmaApp = verb: pkgs.writeShellApplication {
    name = "${name}-${verb}";
    runtimeInputs = rubyEnv;
    excludeShellChecks = [ "SC2086" "SC2046" ];
    text = ''
      ${prologue}
      # `synth` is a Pangea-only render; pass through unchanged.
      ${if verb == "synth" then "bundle exec pangea synth ${lib.escapeShellArg template} \"$@\""
        else ''
          mkdir -p .pangea
          # Render Pangea Ruby → Terraform JSON (disk intermediary; the
          # in-memory magnus path is M0.x).
          bundle exec pangea synth ${lib.escapeShellArg template} > .pangea/rendered.tf.json
          # magma <verb> against the rendered workspace dir.
          magma ${magmaSubcommand.${verb}} .pangea "$@"
        ''}
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

  # `test-magma` — render Pangea Ruby → JSON, then verify via
  # `magma fixture verify-dir`. Requires the `magma` binary on PATH
  # (auto-included in runtimeInputs when executor = "magma";
  # consumers running this under executor = "tofu" must provide
  # `magmaPackage` explicitly via extraDeps to get the magma binary
  # accessible).
  mkTestMagmaApp = pkgs.writeShellApplication {
    name = "${name}-test-magma";
    runtimeInputs = rubyEnv ++ (if !isMagma && magmaPackage != null
                                then [ magmaPackage ]
                                else []);
    excludeShellChecks = [ "SC2086" ];
    text = ''
      ${prologue}
      # Render Pangea Ruby → typed JSON in .pangea/.
      mkdir -p .pangea
      bundle exec pangea synth ${lib.escapeShellArg template} > .pangea/rendered.tf.json
      # Verify the rendered workspace through magma's typed pipeline.
      # Emits a typed JSON report on stdout; exit 0 = passes magma's
      # plan-cleanly assertion, exit 1 = something doesn't.
      magma fixture verify-dir .pangea
    '';
  };

  appFor = verb:
    if verb == "test" then mkTestApp
    else if verb == "test-magma" then mkTestMagmaApp
    else if verb == "import" then mkImportApp
    else if isMagma then mkMagmaApp verb
    else mkPangeaApp verb;

  mkExtraApp = verb: spec: pkgs.writeShellApplication {
    name = "${name}-${verb}";
    runtimeInputs = rubyEnv ++ (spec.runtimeInputs or []);
    excludeShellChecks = [ "SC2086" "SC2046" ];
    text = ''
      ${prologue}
      ${spec.command}
    '';
  };

  standardApps = lib.listToAttrs (map (verb: {
    name = verb;
    value = {
      type = "app";
      program = "${appFor verb}/bin/${name}-${verb}";
    };
  }) verbs);

  extraAppDefs = lib.mapAttrs (verb: spec: {
    type = "app";
    program = "${mkExtraApp verb spec}/bin/${name}-${verb}";
  }) extraApps;

  apps = standardApps // extraAppDefs;

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
