# Go gRPC Service Builder
#
# Builds a Go gRPC service with standardized patterns:
# - Health check server (HTTP)
# - Graceful shutdown with signal handling
# - Prometheus metrics endpoint
# - Unix socket or TCP listener
# - Multi-architecture Docker image
#
# Extracts the common pattern from CSI providers, KMS plugins, and
# microservices that expose gRPC interfaces.
#
# Usage:
#   mkGoGrpcService = (import "${substrate}/lib/go-grpc-service.nix").mkGoGrpcService;
#   service = mkGoGrpcService pkgs {
#     name = "my-grpc-service";
#     src = ./.;
#     version = "1.0.0";
#     vendorHash = "sha256-...";
#     ports = {
#       grpc = 50051;
#       health = 8080;
#       metrics = 9090;
#     };
#   };
#
# Returns: { package, dockerImage, devShell }
{
  mkGoGrpcService = pkgs: {
    name,
    src,
    version ? "0.1.0",
    vendorHash ? null,
    subPackages ? [ "cmd/${name}" ],
    ports ? { grpc = 50051; health = 8080; },
    ldflags ? [],
    buildInputs ? [],
    nativeBuildInputs ? [],
    architecture ? "amd64",
    env ? [],
    protobufDeps ? [],
  }: let
    goDocker = import ./docker.nix;

    binary = pkgs.buildGoModule {
      pname = name;
      inherit version src vendorHash subPackages ldflags;
      inherit buildInputs nativeBuildInputs;
      CGO_ENABLED = 0;
      meta = {
        description = "${name} gRPC service";
        mainProgram = name;
      };
    };

    dockerImage = goDocker.mkGoDockerImage pkgs {
      inherit name binary architecture ports env;
    };

    devShell = pkgs.mkShell {
      buildInputs = with pkgs; [
        go
        gopls
        protobuf
        protoc-gen-go
        protoc-gen-go-grpc
        grpcurl
        buf
      ] ++ buildInputs;

      shellHook = ''
        echo "gRPC service dev shell: ${name}"
        echo "  go build: go build ./cmd/${name}"
        echo "  proto:    buf generate"
        echo "  test:     grpcurl -plaintext localhost:${toString (ports.grpc or 50051)} list"
      '';
    };
  in {
    inherit binary dockerImage devShell;
    package = binary;
  };
}
