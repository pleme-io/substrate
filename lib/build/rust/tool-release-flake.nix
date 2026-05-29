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

  # Ultra-simple consumer flake support. gen emits a complete typed
  # `module_trio` attrset inside `flake_metadata[<toolName>]` when the
  # consumer authored `[package.metadata.pleme]` in Cargo.toml — all
  # defaults applied IN RUST (gen-cargo `ModuleTrioSpec`). Nix is dumb:
  # read the struct, pass to mkModuleTrio. No TOML scraping, no
  # per-field defaulting, no priority logic.
  #
  # Three sources, in priority order:
  #   1. Explicit `module = { ... }` arg — operator override, wins.
  #   2. spec.flake_metadata.<toolName>.module_trio — gen-emitted typed struct.
  #   3. No module trio. Substrate emits nothing under
  #      homeManagerModules / nixosModules / darwinModules. The tool
  #      is just a CLI; consumers that want it on PATH use overlay.
  #
  # Central-control-plane move: behavior change → gen-cargo
  # ModuleTrioSpec defaults → every consumer's next regen.
  src = args.src or null;
  specPath = if src == null then null else src + "/Cargo.build-spec.json";
  spec =
    if specPath != null && builtins.pathExists specPath
    then builtins.fromJSON (builtins.readFile specPath)
    else null;
  specModuleTrio =
    if spec == null then null
    else ((spec.flake_metadata or {}).${toolName} or {}).module_trio or null;
  # Translate the gen-emitted struct (snake_case keys, defaults
  # already applied) into the mkModuleTrio call shape (camelCase
  # `hmNamespace` / `packageAttr` / `binaryName`). This is a pure
  # rename — no defaulting, no logic.
  trioFromSpec =
    if specModuleTrio == null then null
    else {
      name        = specModuleTrio.name;
      description = specModuleTrio.description;
      packageAttr = specModuleTrio.package_attr;
      binaryName  = specModuleTrio.binary_name;
      hmNamespace = specModuleTrio.hm_namespace;
      withMcp           = specModuleTrio.with_mcp           or false;
      withHttp          = specModuleTrio.with_http          or false;
      withSystemDaemon  = specModuleTrio.with_system_daemon or false;
    };
  # Final trio spec: explicit module arg wins; else spec; else nothing.
  trioSpec =
    if module != null then module
    else trioFromSpec;
  trio =
    if trioSpec == null then null
    else (import ../../module-trio.nix { lib = pkgsLib; }).mkModuleTrio trioSpec;

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
