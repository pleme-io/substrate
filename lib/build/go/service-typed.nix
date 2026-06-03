# Go Service — Typed Builder Wrapper
#
# Validates user arguments through the NixOS module system before
# delegating to the existing service-flake.nix builder. Drop-in
# replacement that adds type checking + auto-derivation at the
# boundary. Consumer API is unchanged.
#
# Mirrors the Rust service wrapper (../rust/service-typed.nix) in
# layering — outer layer takes the deps service-flake.nix needs, then
# a single user-facing function — and follows the proven Go gRPC
# wrapper (./grpc-service-typed.nix) evalModules pattern.
#
# Usage (identical to service-flake.nix's config arg):
#   goService = import ./service-typed.nix {
#     inherit nixpkgs substrate forge;
#   };
#   outputs = goService {
#     inherit self;
#     serviceName = "my-go-service";
#     registry    = "ghcr.io/pleme-io/my-go-service";
#   };
{
  nixpkgs,
  substrate,
  forge,
}:

# User-facing function — accepts the same args as service-flake.nix
userArgs:

let
  lib = nixpkgs.lib or (import nixpkgs {}).lib;

  # `self` is a flake-level arg consumed by service-flake.nix, not a
  # typed service option — split it out before validation.
  self = userArgs.self or null;
  serviceArgs = builtins.removeAttrs userArgs [ "self" ];

  # Evaluate user args through the typed module system.
  evaluated = lib.evalModules {
    modules = [
      (import ./service-module.nix)
      { config.substrate.go.service = serviceArgs; }
    ];
  };
  spec = evaluated.config.substrate.go.service;

  # Resolve auto-derived fields (matching service-flake.nix defaults).
  resolvedSubPackages =
    if spec.subPackages == null then [ "cmd/${spec.serviceName}" ]
    else spec.subPackages;

  # Fold the singular `port` convenience field into `ports.http`.
  resolvedPorts =
    if spec.port != null then spec.ports // { http = spec.port; }
    else spec.ports;

  # Delegate to the original builder with validated + resolved args.
  originalBuilder = import ./service-flake.nix {
    inherit nixpkgs substrate forge;
  };
in originalBuilder {
  inherit self;
  inherit (spec) serviceName registry src vendorHash version ldflags
    architectures systems env user workDir buildInputs
    distroless tini sign sbom fipsBuild labels description;
  subPackages = resolvedSubPackages;
  ports = resolvedPorts;
}
