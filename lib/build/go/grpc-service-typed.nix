# Go gRPC Service — Typed Builder Wrapper
#
# Validates user arguments through the module system before delegating
# to grpc-service.nix. Drop-in replacement with type checking.
#
# Usage (identical to grpc-service.nix):
#   mkGoGrpcService = (import ./grpc-service-typed.nix).mkGoGrpcService;
#   result = mkGoGrpcService pkgs { name = "my-svc"; src = ./.; };
{
  mkGoGrpcService = pkgs: userArgs: let
    lib = pkgs.lib;

    evaluated = lib.evalModules {
      modules = [
        (import ./grpc-service-module.nix)
        { config.substrate.go.grpcService = userArgs; }
      ];
    };
    spec = evaluated.config.substrate.go.grpcService;

    originalBuilder = (import ./grpc-service.nix).mkGoGrpcService;

    resolvedSubPackages =
      if spec.subPackages == null then [ "cmd/${spec.name}" ]
      else spec.subPackages;
  in originalBuilder pkgs {
    inherit (spec) name src version vendorHash ports ldflags
      buildInputs nativeBuildInputs architecture env protobufDeps;
    subPackages = resolvedSubPackages;
  };
}
