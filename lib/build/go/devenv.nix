# Standalone Go development environment builder.
#
# Reusable devShell for Go services/tools — use when you need a dev
# environment without the full service-flake.nix pipeline. This is the
# single source for Go devShells (previously inlined ≥3 times across
# service-flake.nix, grpc-service*.nix, and consumer flakes).
#
# Uses substrate's from-source `pkgs.go` (the fleet Go toolchain). No C
# compiler is pulled in — Go fleet builds run with CGO_ENABLED=0, so
# mkShellNoCC is the correct (lighter) shell base.
#
# Usage (standalone):
#   goDevenv = import "${substrate}/lib/build/go/devenv.nix";
#   devShells.default = goDevenv.mkGoDevShell pkgs { withProtobuf = true; };
#
# Usage (via substrate lib):
#   substrateLib = substrate.libFor { inherit pkgs system; };
#   devShells.default = substrateLib.mkGoDevShell { withGrpc = true; };
{
  # Build a Go development shell with optional tool sets.
  #
  # Parameters:
  #   withSqlite:       Include sqlite (database development)
  #   withHelm:         Include kubernetes-helm (chart development)
  #   withKubernetes:   Include kubectl (cluster interaction)
  #   withDocker:       Include docker-client (image management)
  #   withProtobuf:     Include protobuf compiler + protoc-gen-go
  #   withGrpc:         Include protobuf compiler + protoc-gen-go +
  #                     protoc-gen-go-grpc (gRPC codegen)
  #   extraPackages:    Additional packages to include
  mkGoDevShell = pkgs: {
    withSqlite ? false,
    withHelm ? false,
    withKubernetes ? false,
    withDocker ? false,
    withProtobuf ? false,
    withGrpc ? false,
    extraPackages ? [],
  }: let
    lib = pkgs.lib;
  in pkgs.mkShellNoCC {
    packages = with pkgs;
      # Core Go toolchain
      [ go gopls gotools delve gofumpt ]
      # Optional tool sets
      ++ lib.optionals withSqlite [ sqlite ]
      ++ lib.optionals withHelm [ kubernetes-helm ]
      ++ lib.optionals withKubernetes [ kubectl ]
      ++ lib.optionals withDocker [ docker-client ]
      ++ lib.optionals withProtobuf [ protobuf protoc-gen-go ]
      ++ lib.optionals withGrpc [ protobuf protoc-gen-go protoc-gen-go-grpc ]
      # Caller extras
      ++ extraPackages;
  };
}
