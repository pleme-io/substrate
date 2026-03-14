# Source Registry Builder
#
# Creates a centralized, pinned source registry from GitHub repos.
# Provides a single place to track versions, revisions, and hashes
# for external repos that you build without modifying.
#
# Usage (standalone):
#   mkSourceRegistry = import "${substrate}/lib/source-registry.nix";
#   sources = mkSourceRegistry {
#     inherit (pkgs) fetchFromGitHub;
#     repos = {
#       cli = { owner = "acme"; repo = "cli"; rev = "abc123"; hash = "sha256-..."; };
#       sdk = { owner = "acme"; repo = "sdk"; rev = "def456"; hash = "sha256-..."; };
#     };
#   };
#   # sources.cli => fetchFromGitHub derivation
#   # sources.sdk => fetchFromGitHub derivation
#
# Usage (with version metadata):
#   sources = mkSourceRegistry {
#     inherit (pkgs) fetchFromGitHub;
#     repos = {
#       cli = {
#         owner = "acme"; repo = "cli";
#         rev = "v1.2.3"; hash = "sha256-...";
#         version = "1.2.3";  # metadata — accessible via sources.cli.version
#       };
#     };
#   };
{
  fetchFromGitHub,
  repos,
}: builtins.mapAttrs (_name: { owner, repo, rev, hash, version ? null, ... }:
  let
    src = fetchFromGitHub { inherit owner repo rev hash; };
  in src // {
    # Attach metadata for consumers that need it
    meta = { inherit owner repo rev; } // (if version != null then { inherit version; } else {});
  }
) repos
