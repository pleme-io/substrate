# Runtime configuration: tokens, secrets, tools
#
# Centralized configuration for CI/CD tokens and runtime tool paths.
# Environment variables override defaults for security.
{ pkgs }:

rec {
  # ============================================================================
  # CENTRALIZED TOKENS & SECRETS
  # ============================================================================
  # Environment variables override defaults for security in CI/CD
  # Set ATTIC_TOKEN and GHCR_TOKEN to override these defaults
  #
  # For CI/CD: Inject tokens via Kubernetes secrets or GitHub secrets
  # For local dev: Uses defaults below (falling back if env vars not set)

  # Returns "" when env var is not set (pure flake eval) — shell scripts do runtime file read.
  # CI/CD: set ATTIC_TOKEN/GHCR_TOKEN before `nix run` to embed tokens in the built app.
  defaultAtticToken = builtins.getEnv "ATTIC_TOKEN";

  defaultGhcrToken = let
    ghcrToken = builtins.getEnv "GHCR_TOKEN";
    githubToken = builtins.getEnv "GITHUB_TOKEN";
  in
    if ghcrToken != ""
    then ghcrToken
    else githubToken;  # Returns "" if both unset — shell scripts handle runtime fallback

  # ============================================================================
  # RUNTIME TOOLS CONFIGURATION
  # ============================================================================
  # Generalized system for calling external tools via derivation paths
  # Uses the derivation-to-environment-variable pattern for reproducible builds

  runtimeTools = {
    skopeo = {
      package = pkgs.skopeo;
      binary = "skopeo";
    };
    attic = {
      package = pkgs.attic-client;
      binary = "attic";
    };
    kubectl = {
      package = pkgs.kubectl;
      binary = "kubectl";
    };
    git = {
      package = pkgs.git;
      binary = "git";
    };
    nix = {
      package = pkgs.nix;
      binary = "nix";
    };
    flux = {
      package = pkgs.fluxcd;
      binary = "flux";
    };
    docker = {
      package = pkgs.docker;
      binary = "docker";
    };
    crate2nix = {
      package = pkgs.crate2nix;
      binary = "crate2nix";
    };
    bun = {
      package = pkgs.bun;
      binary = "bun";
    };
    regctl = {
      package = pkgs.regclient;
      binary = "regctl";
    };
  };

  # Generate environment variable exports for runtime tools
  mkRuntimeToolsEnv = {tools ? []}:
    let
      mkExport = toolName:
        let
          tool = runtimeTools.${toolName};
          envVarName = "${pkgs.lib.toUpper toolName}_BIN";
          toolPath = "${tool.package}/bin/${tool.binary}";
        in
          "export ${envVarName}=\"${toolPath}\"";
    in
      pkgs.lib.concatMapStringsSep "\n" mkExport tools;

  # Common tool sets for different use cases
  deploymentTools = ["skopeo" "attic" "git" "regctl"];
  kubernetesTools = ["kubectl" "flux"];
  allRuntimeTools = builtins.attrNames runtimeTools;
}
