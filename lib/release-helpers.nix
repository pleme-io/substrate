# ============================================================================
# RELEASE HELPERS - Shared release/bump/check-all app factories
# ============================================================================
# Delegates to `forge tool` subcommands for release lifecycle operations.
# Each function returns an app attrset ({ type, program }).
#
# Internal helper — not exported from lib/default.nix.
{
  # Build a release app that builds all targets, tags, and uploads to GitHub.
  # Delegates to `forge tool release`.
  mkReleaseApp = { hostPkgs, toolName, repo, language ? "rust", ... }: {
    type = "app";
    program = toString (hostPkgs.writeShellScript "${toolName}-release" ''
      set -euo pipefail
      exec ${hostPkgs.forge or "forge"}/bin/forge tool release \
        --name "${toolName}" \
        --repo "${repo}" \
        --language "${language}" \
        "$@"
    '');
  };

  # Build a version bump app.
  # Delegates to `forge tool bump`.
  mkBumpApp = { hostPkgs, toolName, language ? "rust", ... }: {
    type = "app";
    program = toString (hostPkgs.writeShellScript "${toolName}-bump" ''
      set -euo pipefail
      LEVEL="''${1:-patch}"
      exec ${hostPkgs.forge or "forge"}/bin/forge tool bump \
        --name "${toolName}" \
        --language "${language}" \
        --level "$LEVEL"
    '');
  };

  # Build a check-all app that runs language-specific quality checks.
  # Delegates to `forge tool check`.
  mkCheckAllApp = { hostPkgs, toolName, language ? "rust", ... }: {
    type = "app";
    program = toString (hostPkgs.writeShellScript "${toolName}-check-all" ''
      set -euo pipefail
      exec ${hostPkgs.forge or "forge"}/bin/forge tool check \
        --name "${toolName}" \
        --language "${language}"
    '');
  };
}
