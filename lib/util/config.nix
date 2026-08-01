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
  # ── skopeo RETIRED from the default set 2026-08-01 ─────────────────────────
  # MEASURED, not assumed: `SKOPEO_BIN` — the only thing listing skopeo here
  # produces — has ZERO consumers across substrate, hardened-images and actions.
  # So did REGCTL_BIN and BUN_BIN. The probe was validated with a control first:
  # searching for `$VAR` found nothing even for TRIVY_BIN, which IS consumed —
  # tatara-script reads env vars via `(env-get "NAME")`, not `$NAME`. With the
  # correct pattern the control returns 4 real consumers (TRIVY/GRYPE/GZIP/CP),
  # so the zeros above are genuine absence rather than a broken search.
  #
  # Listing it therefore put skopeo into every deployment closure to export a
  # variable nothing read — cost with no consumer, and a standing invitation to
  # start using skopeo again after the fleet-wide move to doca.
  #
  # The `runtimeTools.skopeo` entry itself is KEPT (MODULARIZE, DON'T DELETE):
  # it stays valid, buildable and one list-entry away. What changed is that it is
  # no longer a DEFAULT. Anything that genuinely needs skopeo can name it
  # explicitly and say why.
  deploymentTools = ["attic" "git" "regctl"];
  kubernetesTools = ["kubectl" "flux"];
  allRuntimeTools = builtins.attrNames runtimeTools;
}
