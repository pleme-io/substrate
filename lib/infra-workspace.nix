# Generic OpenTofu infrastructure workspace.
#
# Each pangea template is its own workspace with isolated state.
# Supports local and S3 backends with state migration (local → S3).
#
# Usage (per-system):
#   let mkInfraWorkspace = import "${substrate}/lib/infra-workspace.nix" {
#     inherit pkgs;
#   };
#   in mkInfraWorkspace {
#     name = "akeyless-dev";
#     configs = {
#       "main.tf.json" = { resource = { ... }; };
#       "providers.tf.json" = { terraform = { ... }; provider = { ... }; };
#     };
#     backend = {
#       type = "s3";
#       bucket = "my-state-bucket";
#       key = "pangea/akeyless-dev/terraform.tfstate";
#       region = "us-east-1";
#       dynamodb_table = "my-lock-table";
#     };
#     awsProfile = "my-aws-profile";
#   }
#
# Returns: { plan, apply, destroy, validate, output, show, migrate }
#
# Bootstrap workflow (state backend):
#   1. nix run .#state-backend-plan     # local state
#   2. nix run .#state-backend-apply    # creates S3 + DynamoDB
#   3. nix run .#state-backend-migrate  # migrates local → S3
#   4. Update Nix config: backend.type = "s3"
#   5. nix run .#state-backend-plan     # verify, now uses S3
#
# After bootstrap, other workspaces use S3 backend directly.
{ pkgs }:

{
  name,
  configs,
  backend ? { type = "local"; },
  remoteBackend ? null,
  awsProfile ? null,
  stateDir ? null,
}:

let
  lib = pkgs.lib;

  # ── Schema enforcement ──────────────────────────────────────────────
  #
  # Every workspace must have a name, configs, and a valid backend.
  # S3 backends must specify bucket, key, and dynamodb_table.
  # remoteBackend is required for the migrate action.

  assertions = [
    {
      assertion = lib.isString name && name != "";
      message = "infra-workspace: name must be a non-empty string";
    }
    {
      assertion = lib.isAttrs configs && configs != {};
      message = "infra-workspace: configs must be a non-empty attrset of { \"filename.tf.json\" = { ... }; }";
    }
    {
      assertion = backend ? type && builtins.elem backend.type ["local" "s3"];
      message = "infra-workspace: backend.type must be \"local\" or \"s3\", got: ${backend.type or "missing"}";
    }
    {
      assertion = backend.type != "s3" || (backend ? bucket && backend ? key && backend ? dynamodb_table);
      message = "infra-workspace: S3 backend requires bucket, key, and dynamodb_table";
    }
    {
      assertion = remoteBackend == null || (remoteBackend ? bucket && remoteBackend ? key && remoteBackend ? dynamodb_table);
      message = "infra-workspace: remoteBackend (if set) requires bucket, key, and dynamodb_table";
    }
  ];

  failedAssertions = builtins.filter (a: !a.assertion) assertions;
  _ = if failedAssertions != []
    then throw (builtins.head failedAssertions).message
    else true;

  # ── State directory ─────────────────────────────────────────────────

  actualStateDir = if stateDir != null then stateDir
    else "\${HOME}/.local/state/infra/${name}";

  # ── Backend configuration ───────────────────────────────────────────

  backendConfig =
    if backend.type == "s3" then {
      terraform.backend.s3 = {
        bucket         = backend.bucket;
        key            = backend.key;
        region         = backend.region or "us-east-1";
        dynamodb_table = backend.dynamodb_table;
        encrypt        = true;
      };
    } else {
      terraform.backend.local = {
        path = "terraform.tfstate";
      };
    };

  # ── Config file generation ──────────────────────────────────────────

  allConfigs = configs // {
    "backend.tf.json" = backendConfig;
  };

  configFiles = lib.mapAttrsToList (filename: content: {
    inherit filename;
    path = pkgs.writeText "${name}-${filename}" (builtins.toJSON content);
  }) allConfigs;

  copyConfigs = lib.concatMapStringsSep "\n" (f:
    ''cp -f "${f.path}" "$STATE_DIR/${f.filename}"''
  ) configFiles;

  # ── AWS SSO check ──────────────────────────────────────────────────

  awsCheck = lib.optionalString (awsProfile != null) ''
    if ! aws sts get-caller-identity --profile "${awsProfile}" >/dev/null 2>&1; then
      echo ""
      echo "  AWS SSO session expired. Run:"
      echo ""
      echo "    aws sso login --profile ${awsProfile}"
      echo ""
      exit 1
    fi
    export AWS_PROFILE="${awsProfile}"
  '';

  # ── Shared preamble ────────────────────────────────────────────────

  preamble = ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.opentofu ]}:$PATH"

    STATE_DIR="${actualStateDir}"
    mkdir -p "$STATE_DIR"

    ${awsCheck}
    ${copyConfigs}

    cd "$STATE_DIR"

    if ! tofu init -input=false -no-color -upgrade > /tmp/tofu-init-${name}-$$.log 2>&1; then
      echo "tofu init failed:"
      cat /tmp/tofu-init-${name}-$$.log
      rm -f /tmp/tofu-init-${name}-$$.log
      exit 1
    fi
    rm -f /tmp/tofu-init-${name}-$$.log
  '';

  # ── App generator ──────────────────────────────────────────────────

  mkApp = action: flags: {
    type = "app";
    program = toString (pkgs.writeShellScript "${name}-${action}" ''
      ${preamble}
      echo "--- ${name}: ${action} ---"
      echo ""
      tofu ${action} ${flags}
    '');
  };

  # ── Migration app (local → S3) ─────────────────────────────────────

  migrateApp =
    if remoteBackend == null then
      mkApp "validate" "" // {
        program = toString (pkgs.writeShellScript "${name}-migrate" ''
          echo "No remoteBackend configured for workspace '${name}'."
          echo "Set remoteBackend = { bucket = ...; key = ...; dynamodb_table = ...; } to enable migration."
          exit 1
        '');
      }
    else
      let
        s3BackendConfig = {
          terraform.backend.s3 = {
            bucket         = remoteBackend.bucket;
            key            = remoteBackend.key;
            region         = remoteBackend.region or "us-east-1";
            dynamodb_table = remoteBackend.dynamodb_table;
            encrypt        = true;
          };
        };
        s3BackendJson = pkgs.writeText "${name}-s3-backend.tf.json"
          (builtins.toJSON s3BackendConfig);
      in {
        type = "app";
        program = toString (pkgs.writeShellScript "${name}-migrate" ''
          set -euo pipefail
          export PATH="${lib.makeBinPath [ pkgs.opentofu ]}:$PATH"

          STATE_DIR="${actualStateDir}"

          ${awsCheck}

          if [ ! -d "$STATE_DIR" ]; then
            echo "No state directory found at $STATE_DIR"
            echo "Run plan/apply first to create local state."
            exit 1
          fi

          cd "$STATE_DIR"

          if [ ! -f terraform.tfstate ] && [ ! -f .terraform/terraform.tfstate ]; then
            echo "No local state found. Nothing to migrate."
            exit 1
          fi

          echo "--- ${name}: migrate (local -> S3) ---"
          echo ""
          echo "  Bucket:   ${remoteBackend.bucket}"
          echo "  Key:      ${remoteBackend.key}"
          echo "  DynamoDB: ${remoteBackend.dynamodb_table}"
          echo "  Region:   ${remoteBackend.region or "us-east-1"}"
          echo ""

          # Replace local backend with S3 backend
          cp -f "${s3BackendJson}" "$STATE_DIR/backend.tf.json"

          # Migrate state to S3
          tofu init -migrate-state

          echo ""
          echo "State migrated to S3."

          # Clean up local state
          if [ -f terraform.tfstate ]; then
            rm -f terraform.tfstate terraform.tfstate.backup
            echo "Local state files cleaned up."
          fi

          echo ""
          echo "IMPORTANT: Update your Nix workspace config to use backend.type = \"s3\""
          echo "with the same bucket/key/dynamodb_table, then rebuild."
        '');
      };

in builtins.seq _ {
  plan     = mkApp "plan" "";
  apply    = mkApp "apply" "";
  destroy  = mkApp "destroy" "";
  validate = mkApp "validate" "";
  output   = mkApp "output" "";
  show     = mkApp "show" "";
  migrate  = migrateApp;
}
