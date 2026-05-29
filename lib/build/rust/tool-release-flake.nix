# Complete multi-system flake outputs for a Rust CLI tool.
# Wraps rust-tool-release.nix + eachSystem + overlays for zero-boilerplate
# consumer flakes.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, crate2nix, flake-utils, substrate, ... }:
#     (import "${substrate}/lib/rust-tool-release-flake.nix" {
#       inherit nixpkgs crate2nix flake-utils;
#     }) {
#       toolName = "kindling";
#       src = self;
#       repo = "pleme-io/kindling";
#     };
#
# Module trio (NixOS + nix-darwin + home-manager): pass `module = { ... }` to
# auto-emit nixosModules.default / darwinModules.default / homeManagerModules.default.
# See substrate/lib/module-trio.nix for the spec shape. Example:
#
#   {
#     toolName = "namimado";
#     src = self;
#     module = {
#       description = "Namimado desktop browser";
#       withMcp = true; withHttp = true; withSystemDaemon = false;
#     };
#   };
{
  nixpkgs,
  crate2nix,
  flake-utils,
  fenix ? null,
  devenv ? null,
  forge ? null,
  # Substrate-bound gen flake input. When supplied, the consumer's
  # outputs include `apps.{lock,build-spec,plan,confirm,diff,sbom}`
  # — every Adapter verb wired as a flake app for free.
  gen ? null,
}:
{
  toolName,
  systems ? ["aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux"],
  module ? null,
  ...
} @ args:
let
  toolArgs = builtins.removeAttrs args [ "systems" "module" ];
  flakeWrapper = import ../../util/flake-wrapper.nix { inherit nixpkgs; };
  hygiene = import ../../util/flake-hygiene.nix {
    lib = (import nixpkgs { system = "x86_64-linux"; }).lib;
  };
  pkgsLib = (import nixpkgs { system = "x86_64-linux"; }).lib;
  # Enforce flake hygiene at evaluation time — fails fast on misconfiguration.
  # In tool flakes, src = self, so src.inputs holds the flake inputs.
  _hygieneCheck =
    if args ? src && args.src ? inputs then hygiene.enforceAll args.src.inputs
    else true;

  mkPerSystem = system: let
    rustTool = import ./tool-release.nix {
      inherit system nixpkgs devenv;
      crate2nix = crate2nix.packages.${system}.default;
      fenix = if fenix != null then fenix else null;
      forge = if forge != null then forge.packages.${system}.default else null;
      # gen is wired in AS A BUILD TOOL for the IFD auto-regen
      # path. Prefer the `host-tool` output (native dynamic, no
      # pkgsStatic) over `default` (which may be a static-musl
      # cross-build for linux systems and fail under crate-compat
      # walls like notify/mio). Fall back to `default` for gen
      # versions that haven't published host-tool yet.
      gen =
        if gen == null then null
        else gen.packages.${system}.host-tool or gen.packages.${system}.default;
    };
  in rustTool toolArgs;

  # Ultra-simple consumer flake support: read module-trio config from
  # `Cargo.build-spec.json`'s `flake_metadata[<toolName>]` map, populated
  # by gen from `Cargo.toml [package.metadata.pleme]`. Consumers don't
  # need to pass `module = { ... }` at all when the typed metadata is
  # in the source. Priority order per field:
  #
  #   1. Explicit `module.<field>` arg (highest — operator override)
  #   2. flake_metadata.<toolName>.<json-key> (gen-emitted)
  #   3. Substrate default
  #
  # This is THE central-control-plane move: change behavior in substrate
  # OR in gen, every consumer gets it on next eval without flake.nix
  # edits. New consumers ship a 3-line flake; existing consumers can
  # migrate by adding `[package.metadata.pleme]` to Cargo.toml and
  # deleting their `module = { ... }` block.
  src = args.src or null;
  specPath = if src == null then null else src + "/Cargo.build-spec.json";
  spec =
    if specPath != null && builtins.pathExists specPath
    then builtins.fromJSON (builtins.readFile specPath)
    else null;
  flakeMetaForTool =
    if spec == null then null
    else (spec.flake_metadata or {}).${toolName} or null;
  # Priority resolver: explicit module field > flake_metadata field > default.
  pick = field: jsonKey: default:
    if module != null && module ? ${field} then module.${field}
    else if flakeMetaForTool != null && flakeMetaForTool ? ${jsonKey}
         && flakeMetaForTool.${jsonKey} != null
      then flakeMetaForTool.${jsonKey}
    else default;
  hasAnyModuleSource = module != null || flakeMetaForTool != null;
  trio =
    if !hasAnyModuleSource then null
    else (import ../../module-trio.nix { lib = pkgsLib; }).mkModuleTrio (
      {
        name = pick "name" "hm_leaf" toolName;
        description = pick "description" "description" "${toolName} CLI tool";
        packageAttr = pick "packageAttr" "package_attr" toolName;
        hmNamespace = pick "hmNamespace" "hm_namespace" "programs";
        binaryName = pick "binaryName" "binary_name" toolName;
      }
      // (
        if module == null then {}
        else builtins.removeAttrs module [
          "name" "description" "packageAttr" "hmNamespace" "binaryName"
        ]
      )
    );

  moduleOutputs = if trio == null then {} else {
    homeManagerModules.default = trio.homeManagerModule;
    nixosModules.default = trio.nixosModule;
    darwinModules.default = trio.darwinModule;
  };
in
  flakeWrapper.mkFlakeOutputs {
    inherit systems mkPerSystem;
    extraOutputs = {
      overlays.default = final: prev: {
        ${toolArgs.toolName} = (mkPerSystem final.stdenv.hostPlatform.system).packages.default;
      };
    } // moduleOutputs;
  }
