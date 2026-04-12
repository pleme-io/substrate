# Shared Release App Factory
#
# Typed factories for release lifecycle apps (release, bump, check-all,
# lock-platform). Wraps the forge CLI with standardized argument patterns.
#
# This unifies the release automation that was previously duplicated
# across Rust (release-helpers.nix), Go, Zig, and Ruby builders.
#
# Depends on: pkgs (for writeShellScript)
#
# Usage:
#   shared = import ./release-app.nix { inherit pkgs forgeCmd; };
#   apps = shared.mkReleaseApps {
#     toolName = "kindling";
#     repo = "pleme-io/kindling";
#     language = "rust";
#   };
{ pkgs, forgeCmd ? "forge" }:

rec {
  # ── Release App ───────────────────────────────────────────────────
  # Builds all targets, tags, and uploads to GitHub.
  mkReleaseApp = { toolName, repo, language ? "rust" }: {
    type = "app";
    program = toString (pkgs.writeShellScript "${toolName}-release" ''
      set -euo pipefail
      exec ${forgeCmd} tool release \
        --name "${toolName}" \
        --repo "${repo}" \
        --language "${language}" \
        "$@"
    '');
  };

  # ── Bump App ──────────────────────────────────────────────────────
  # Version bump (patch/minor/major).
  mkBumpApp = { toolName, language ? "rust" }: {
    type = "app";
    program = toString (pkgs.writeShellScript "${toolName}-bump" ''
      set -euo pipefail
      LEVEL="''${1:-patch}"
      exec ${forgeCmd} tool bump \
        --name "${toolName}" \
        --language "${language}" \
        --level "$LEVEL"
    '');
  };

  # ── Check-All App ─────────────────────────────────────────────────
  # Runs language-specific quality checks (fmt, lint, test).
  mkCheckAllApp = { toolName, language ? "rust" }: {
    type = "app";
    program = toString (pkgs.writeShellScript "${toolName}-check-all" ''
      set -euo pipefail
      exec ${forgeCmd} tool check \
        --name "${toolName}" \
        --language "${language}"
    '');
  };

  # ── Lock-Platform App ─────────────────────────────────────────────
  # Certifies cross-platform build on the current platform.
  mkLockPlatformApp = { toolName, language ? "rust" }: let
    platform = pkgs.stdenv.hostPlatform.system;
  in {
    type = "app";
    program = toString (pkgs.writeShellScript "${toolName}-lock-platform" ''
      set -euo pipefail
      exec ${forgeCmd} tool lock \
        --name "${toolName}" \
        --language "${language}" \
        --platform "${platform}"
    '');
  };

  # ── Combined Release Apps ─────────────────────────────────────────
  # Returns all standard release lifecycle apps at once.
  mkReleaseApps = { toolName, repo, language ? "rust" }: {
    release = mkReleaseApp { inherit toolName repo language; };
    bump = mkBumpApp { inherit toolName language; };
    check-all = mkCheckAllApp { inherit toolName language; };
    lock-platform = mkLockPlatformApp { inherit toolName language; };
  };

  # ── Image Push App ────────────────────────────────────────────────
  # Push a Docker image to a container registry via forge.
  mkImagePushApp = { name, registry }: {
    type = "app";
    program = toString (pkgs.writeShellScript "${name}-push" ''
      set -euo pipefail
      GIT_SHA="''${RELEASE_GIT_SHA:-$(${pkgs.git}/bin/git rev-parse --short HEAD)}"
      exec ${forgeCmd} push \
        --image-path result \
        --registry ${registry} \
        --tag "amd64-$GIT_SHA" \
        --tag "amd64-latest" \
        --retries 10
    '');
  };
}
