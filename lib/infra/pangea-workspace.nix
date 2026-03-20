# Pangea-native infrastructure workspace.
#
# Generates pangea.yml config from Nix attrsets and produces nix run apps
# that delegate to `pangea workspace <action> <name>`. All orchestration
# happens in Ruby (architecture synthesis, state management, migration).
# Nix only generates config and provides the runtime environment.
#
# This replaces infra-workspace.nix + infra-state-backend.nix with a
# single pattern that delegates to the pangea CLI.
#
# Usage:
#   let mkPangeaWorkspace = import "${substrate}/lib/pangea-workspace.nix" {
#     inherit pkgs;
#     pangea = inputs.pangea.packages.${system}.default;  # or however pangea is provided
#   };
#   in mkPangeaWorkspace {
#     name = "state-backend";
#     architecture = "state_backend";
#     awsProfile = "akeyless-development";
#     stateBackend = { type = "local"; };
#     remoteBackend = { type = "s3"; bucket = "..."; key = "..."; dynamodb_table = "..."; };
#     config = { bucket = "..."; dynamodb_table = "..."; };
#     providers.aws = { region = "us-east-1"; version = "~> 5.0"; };
#   };
#
# Returns: { plan, apply, destroy, show, status, migrate, list, pangeaYml }
#
# The generated pangea.yml follows shikumi-style YAML config patterns:
# Nix generates it, Ruby reads it, no shell in between.
{ pkgs, pangea ? null }:

{
  name,
  architecture,
  awsProfile ? null,
  namespace ? "production",
  stateBackend ? { type = "local"; },
  remoteBackend ? null,
  config ? {},
  providers ? {},
}:

let
  lib = pkgs.lib;

  # ── Schema enforcement ──────────────────────────────────────────────

  assertions = [
    {
      assertion = lib.isString name && name != "";
      message = "pangea-workspace: name must be a non-empty string";
    }
    {
      assertion = lib.isString architecture && architecture != "";
      message = "pangea-workspace: architecture must be a non-empty string";
    }
    {
      assertion = stateBackend ? type && builtins.elem stateBackend.type ["local" "s3"];
      message = "pangea-workspace: stateBackend.type must be \"local\" or \"s3\", got: ${stateBackend.type or "missing"}";
    }
    {
      assertion = stateBackend.type != "s3" || (stateBackend ? bucket && stateBackend ? key && stateBackend ? dynamodb_table);
      message = "pangea-workspace: S3 stateBackend requires bucket, key, and dynamodb_table";
    }
    {
      assertion = remoteBackend == null || (remoteBackend ? bucket && remoteBackend ? key && remoteBackend ? dynamodb_table);
      message = "pangea-workspace: remoteBackend (if set) requires bucket, key, and dynamodb_table";
    }
  ];

  failedAssertions = builtins.filter (a: !a.assertion) assertions;
  _ = if failedAssertions != []
    then throw (builtins.head failedAssertions).message
    else true;

  # ── YAML generation (shikumi-style: Nix → YAML → Ruby) ──────────

  # Build the workspace entry for pangea.yml
  workspaceEntry = {
    inherit architecture;
    inherit namespace;
    backend = stateBackend;
    inherit config;
    inherit providers;
  } // lib.optionalAttrs (awsProfile != null) {
    aws_profile = awsProfile;
  } // lib.optionalAttrs (remoteBackend != null) {
    remote_backend = remoteBackend;
  };

  # Full pangea.yml with a single workspace
  pangeaConfig = {
    default_namespace = namespace;
    namespaces.${namespace} = {
      state = stateBackend;
    };
    workspaces.${name} = workspaceEntry;
  };

  pangeaYml = pkgs.writeText "${name}-pangea.yml"
    (builtins.toJSON pangeaConfig);

  # ── Runtime dependencies ─────────────────────────────────────────

  runtimeDeps = [ pkgs.opentofu ]
    ++ lib.optional (awsProfile != null) pkgs.awscli2
    ++ lib.optional (pangea != null) pangea;

  # ── App generator ────────────────────────────────────────────────
  #
  # Each action is a thin shell script that:
  # 1. Writes pangea.yml to a workspace directory
  # 2. Calls `pangea workspace <action> <name>`
  #
  # The pangea CLI handles everything: synthesis, state, backends, SSO.

  mkApp = action: {
    type = "app";
    program = toString (pkgs.writeShellScript "${name}-${action}" ''
      set -euo pipefail
      export PATH="${lib.makeBinPath runtimeDeps}:$PATH"

      # Write generated pangea.yml to workspace config directory
      PANGEA_DIR="''${HOME}/.pangea/workspace-configs/${name}"
      mkdir -p "$PANGEA_DIR"
      cp -f "${pangeaYml}" "$PANGEA_DIR/pangea.yml"

      cd "$PANGEA_DIR"

      echo "--- ${name}: ${action} ---"
      echo ""
      pangea workspace ${action} ${name}
    '');
  };

in builtins.seq _ {
  plan    = mkApp "plan";
  apply   = mkApp "apply";
  destroy = mkApp "destroy";
  show    = mkApp "show";
  status  = mkApp "status";
  migrate = mkApp "migrate";
  list    = mkApp "list";

  # Expose the generated config for debugging / composition
  inherit pangeaYml;
}
