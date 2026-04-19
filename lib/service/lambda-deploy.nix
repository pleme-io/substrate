# mkLambdaDeployApp — single-command deploy app for a
# LambdaDeploymentDecl workspace.
#
# Wraps three operations into one `nix run .#deploy`:
#
#   1. `nix build` the caller-provided `zipSource` flake reference
#      (which evaluates to a `*.zip` derivation, typically
#      `packages.<system>.lambda-zip` produced by
#      `substrate/lib/build/rust/lambda.nix`).
#   2. Symlink the built zip at a stable path in the workspace
#      (`./artifacts/<name>.zip`) so terraform sees a consistent
#      source-file path across invocations. Terraform's `etag` +
#      `source_code_hash` content-addressing handles the actual
#      upload + redeploy decisions.
#   3. `tofu init && tofu apply -auto-approve` with
#      `ZIP_LOCAL_PATH` + `ZIP_SOURCE_HASH` environment variables
#      set — the generated pangea workspace template reads these
#      ENV vars and threads them into
#      `Pangea::Architectures::LambdaDeployment.build`.
#
# The whole flow is typed + reproducible: same zip content →
# same hash → no terraform diff → no Lambda redeploy. Zip content
# actually changed (Rust crate edit, dependency bump, new input
# hash) → different hash → terraform uploads → Lambda redeploys.
# No operator shell dance.
#
# Usage (from a workspace flake.nix):
#   outputs = { self, nixpkgs, substrate, handler, ... }: let
#     system = "aarch64-darwin";
#     pkgs = import nixpkgs { inherit system; };
#     deployApp = import "${substrate}/lib/service/lambda-deploy.nix" {
#       inherit pkgs;
#     };
#   in {
#     apps.${system}.deploy = deployApp.mkLambdaDeployApp {
#       name = "my-lambda";
#       workspacePath = ./.;
#       # nix-build reference — substrate can evaluate this at deploy
#       # time. Must produce a .zip file when built.
#       zipSource = handler.packages.${system}.lambda-zip;
#     };
#   };
{
  pkgs,
  ...
}: {
  # Produce a nix `apps.<system>.*` entry that runs the full
  # build-zip → stage → apply flow.
  #
  # Inputs:
  #   name          — used in script + symlink name (e.g. `my-lambda`).
  #   workspacePath — directory containing `pangea.yml`, `template.rb`,
  #                   and the eventual terraform state. Usually `./`.
  #   zipSource     — derivation producing the zip artifact, or a
  #                   flake-ref string (`"github:pleme-io/x#lambda-zip"`)
  #                   that evaluates to one. Derivation is faster
  #                   (no nix-eval round-trip at deploy time).
  #   pangeaCmd     — how to invoke pangea's apply. Default:
  #                   `pangea plan/apply` via the workspace's own
  #                   flake app. Override to use `tofu apply` directly
  #                   when the workspace doesn't have a pangea wrapper.
  #   extraTofuArgs — additional `tofu apply` flags (e.g. `-target=…`).
  #
  # Output: an `apps` entry — `{ type = "app"; program = "${script}"; }`.
  mkLambdaDeployApp = {
    name,
    workspacePath,
    zipSource,
    pangeaCmd ? null,
    extraTofuArgs ? "",
  }: let
    # Resolve zipSource: if it's already a derivation, use it
    # directly; if it's a string (flake ref), nix-build it at runtime.
    zipDerivation =
      if builtins.isAttrs zipSource && zipSource ? drvPath
      then zipSource
      else null;

    script = pkgs.writeShellApplication {
      name = "deploy-${name}";
      runtimeInputs = [
        pkgs.opentofu
        pkgs.awscli2
        pkgs.nix
        pkgs.openssl
        pkgs.coreutils
      ];
      # Strict mode — nix-built shell scripts are expected to fail
      # loudly. No silent swallowing of build or apply errors.
      text = ''
        set -euo pipefail

        # ── 1. Resolve / build the zip ───────────────────────────
        ${
          if zipDerivation != null
          then ''
            # Pre-built derivation — path is known at flake-eval time.
            ZIP_OUT="${zipDerivation}"
          ''
          else ''
            # Runtime nix build of a flake reference. Use
            # `--print-out-paths` + `--no-link` to avoid the `result`
            # symlink shenanigans that sometimes confuse terraform.
            ZIP_OUT="$(nix build --no-link --print-out-paths ${
              pkgs.lib.escapeShellArg (toString zipSource)
            })"
          ''
        }

        # The zip is at the derivation's root for runCommand-built
        # zips (the convention used by mkLambdaZip in lambda.nix).
        # Some derivations expose it as a child file — handle both.
        if [ -f "$ZIP_OUT" ]; then
          ZIP_FILE="$ZIP_OUT"
        elif [ -f "$ZIP_OUT/bootstrap.zip" ]; then
          ZIP_FILE="$ZIP_OUT/bootstrap.zip"
        else
          # Pick the first *.zip file we find (rare — sanity path).
          ZIP_FILE="$(find "$ZIP_OUT" -maxdepth 2 -name '*.zip' | head -n1)"
          if [ -z "$ZIP_FILE" ]; then
            echo "[deploy] could not find any .zip inside $ZIP_OUT" >&2
            exit 1
          fi
        fi

        echo "[deploy] resolved zip: $ZIP_FILE"

        # ── 2. Stage at a stable path inside the workspace ───────
        cd ${pkgs.lib.escapeShellArg (toString workspacePath)}
        mkdir -p artifacts
        # Stable name — terraform's `source = ./artifacts/bootstrap.zip`
        # never changes across invocations, but `etag` tracks content.
        ln -sfn "$ZIP_FILE" artifacts/bootstrap.zip

        # ── 3. Compute base64-sha256 content hash ────────────────
        # aws_lambda_function.source_code_hash wants base64-encoded
        # sha256 of the zip BYTES (not the file path). When the hash
        # changes, terraform redeploys the function.
        ZIP_SOURCE_HASH="$(openssl dgst -sha256 -binary artifacts/bootstrap.zip | openssl base64 -A)"
        ZIP_LOCAL_PATH="$(pwd)/artifacts/bootstrap.zip"
        export ZIP_SOURCE_HASH ZIP_LOCAL_PATH

        echo "[deploy] zip content hash: $ZIP_SOURCE_HASH"
        echo "[deploy] local path:       $ZIP_LOCAL_PATH"

        # ── 4. Apply (pangea or raw tofu) ────────────────────────
        ${
          if pangeaCmd != null
          then ''
            echo "[deploy] invoking pangea: ${pangeaCmd}"
            ${pangeaCmd}
          ''
          else ''
            echo "[deploy] running tofu init + apply"
            tofu init -upgrade
            tofu apply -auto-approve ${extraTofuArgs}
          ''
        }

        echo "[deploy] done — Lambda content hash: $ZIP_SOURCE_HASH"
      '';
    };
  in {
    type = "app";
    program = "${script}/bin/deploy-${name}";
  };

  # Helper to produce a destroy counterpart — same stable-path +
  # ENV-var setup but runs `tofu destroy`. The hash vars don't
  # matter for destroy (terraform just tears down), but pangea's
  # template evaluates the config block unconditionally, which needs
  # the ENV vars to be present so the Ruby fetch(...) calls don't
  # raise.
  mkLambdaDestroyApp = {
    name,
    workspacePath,
    extraTofuArgs ? "",
  }: let
    script = pkgs.writeShellApplication {
      name = "destroy-${name}";
      runtimeInputs = [pkgs.opentofu pkgs.coreutils];
      text = ''
        set -euo pipefail
        cd ${pkgs.lib.escapeShellArg (toString workspacePath)}
        # Stub the ENV vars so the Ruby template doesn't raise during
        # destroy's config evaluation pass.
        export ZIP_LOCAL_PATH="$(pwd)/artifacts/bootstrap.zip"
        export ZIP_SOURCE_HASH="destroy-stub"
        # Pre-create a placeholder zip if the real one is missing —
        # terraform needs a path that exists at plan time even on
        # destroy, because the aws_s3_object data source reads it.
        if [ ! -e "$ZIP_LOCAL_PATH" ]; then
          mkdir -p artifacts
          : > artifacts/bootstrap.zip
        fi
        tofu destroy -auto-approve ${extraTofuArgs}
      '';
    };
  in {
    type = "app";
    program = "${script}/bin/destroy-${name}";
  };
}
