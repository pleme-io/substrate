# Standalone Rust development environment builder.
#
# Reusable devShell for Rust services/tools — use when you need a dev
# environment without the full rust-service.nix pipeline.
#
# Requires the substrate rust overlay applied to pkgs (for fenixRustToolchain).
#
# Usage (via substrate lib):
#   devShells.default = substrateLib.mkRustDevShell {
#     withSqlite = true;
#     withHelm = true;
#   };
#
# Usage (standalone):
#   devenv = import "${substrate}/lib/rust-devenv.nix" { inherit pkgs; };
#   devShells.default = devenv.mkRustDevShell { withSqlite = true; };
{ pkgs }:
let
  lib = pkgs.lib;
  darwinBuildInputs = (import ./darwin.nix).mkDarwinBuildInputs pkgs;
  fenixToolchain = pkgs.fenixRustToolchain or null;
  hasToolchain = fenixToolchain != null;
in {
  # Build a Rust development shell with optional tool sets.
  #
  # Parameters:
  #   extraPackages:    Additional packages to include
  #   extraEnv:         Additional environment variables
  #   withSqlite:       Include sqlite3 + sqlx-cli (database development)
  #   withHelm:         Include kubernetes-helm (chart development)
  #   withKubernetes:   Include kubectl, k9s, fluxcd (cluster interaction)
  #   withDocker:       Include skopeo (image management)
  #   withProtobuf:     Include protobuf compiler
  mkRustDevShell = {
    extraPackages ? [],
    extraEnv ? {},
    withSqlite ? false,
    withHelm ? false,
    withKubernetes ? false,
    withDocker ? false,
    withProtobuf ? false,
  }: pkgs.mkShell {
    nativeBuildInputs = with pkgs;
      # Core Rust toolchain
      (if hasToolchain then [ fenixToolchain ] else [ rustc cargo ])
      ++ [ pkg-config cargo-watch ]
      # Optional tool sets
      ++ lib.optionals withSqlite [ sqlite ]
      ++ lib.optionals withProtobuf [ protobuf ]
      ++ lib.optionals withHelm [ kubernetes-helm ]
      ++ lib.optionals withKubernetes [ kubectl k9s fluxcd ]
      ++ lib.optionals withDocker [ skopeo ]
      # Darwin SDK
      ++ darwinBuildInputs
      # Caller extras
      ++ extraPackages;

    env = lib.optionalAttrs hasToolchain {
      RUST_SRC_PATH = "${fenixToolchain}/lib/rustlib/src/rust/library";
    } // extraEnv;
  };
}
