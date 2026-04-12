# Rust Service — Typed Builder Wrapper
#
# Backward-compatible wrapper that validates user arguments through
# the NixOS module system before delegating to the existing
# service.nix builder. Consumer API is unchanged — this is a
# drop-in replacement that adds type-checking at the boundary.
#
# Usage (identical to service.nix):
#   rustService = import ./service-typed.nix {
#     inherit nixpkgs system nixLib crate2nix forge;
#   };
#   outputs = rustService {
#     serviceName = "auth";
#     src = ./.;
#   };
{
  nixpkgs,
  system,
  nixLib,
  crate2nix,
  forge,
  nixHooks ? null,
  devenv ? null,
}:

# User-facing function — accepts the same args as service.nix
userArgs:

let
  lib = nixpkgs.lib or (import nixpkgs {}).lib;

  # Evaluate user args through the typed module system
  evaluated = lib.evalModules {
    modules = [
      (import ./service-module.nix)
      { config.substrate.rust.service = userArgs; }
    ];
  };
  spec = evaluated.config.substrate.rust.service;

  # Resolve auto-derived fields (matching service.nix defaults)
  resolvedPorts = if spec.ports == {} then
    (if spec.serviceType == "rest" then { http = 8080; health = 8081; metrics = 9090; }
     else { graphql = 8080; health = 8081; metrics = 9090; })
  else spec.ports;

  resolvedPackageName =
    if spec.packageName != null then spec.packageName
    else if spec.productName != null then "${spec.serviceName}-service"
    else spec.serviceName;

  resolvedNamespace =
    if spec.namespace != null then spec.namespace
    else if spec.productName != null then "${spec.productName}-staging"
    else "${spec.serviceName}-system";

  resolvedServiceDirRelative =
    if spec.serviceDirRelative != null then spec.serviceDirRelative
    else if spec.productName != null then "services/rust/${spec.serviceName}"
    else ".";

  # Delegate to the original builder with validated + resolved args
  originalBuilder = import ./service.nix {
    inherit nixpkgs system nixLib crate2nix forge nixHooks devenv;
  };
in originalBuilder {
  inherit (spec) serviceName src serviceType enableAwsSdk
    buildInputs nativeBuildInputs extraDevInputs devEnvVars
    crateOverrides extraContents cluster architectures
    registry registryBase productName;
  ports = resolvedPorts;
  packageName = resolvedPackageName;
  namespace = resolvedNamespace;
  serviceDirRelative = resolvedServiceDirRelative;
  description = spec.description;
  cargoNix = if spec.cargoNix != null then spec.cargoNix else spec.src + "/Cargo.nix";
  repoRoot = if spec.repoRoot != null then spec.repoRoot else spec.src;
  migrationsPath = if spec.migrationsPath != null then spec.migrationsPath else spec.src + "/migrations";
}
