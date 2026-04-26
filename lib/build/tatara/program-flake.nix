# ============================================================================
# TATARA PROGRAM FLAKE — turn a tatara-lisp source into a complete flake
# ============================================================================
# Wraps `program.nix` with `flake-utils.eachDefaultSystem` and the
# pleme-io flake conventions (overlays, default app, devShell). Drops
# the boilerplate so a consumer flake is one import.
#
# USAGE — `pleme-io/programs/<name>/flake.nix`:
#
#   { inputs = {
#       nixpkgs.url     = "github:nixos/nixpkgs?ref=nixos-unstable";
#       flake-utils.url = "github:numtide/flake-utils";
#       substrate = {
#         url = "github:pleme-io/substrate";
#         inputs.nixpkgs.follows = "nixpkgs";
#       };
#       tatara-lisp = {
#         url = "github:pleme-io/tatara-lisp";
#         inputs.nixpkgs.follows = "nixpkgs";
#       };
#     };
#     outputs = { self, nixpkgs, flake-utils, substrate, tatara-lisp, ... }:
#       (import "${substrate}/lib/build/tatara/program-flake.nix" {
#         inherit nixpkgs flake-utils;
#       }) {
#         tataraLispFlake = tatara-lisp;
#         programs = {
#           hello-world = {
#             source = { type = "local"; path = ./main.tlisp; };
#             description = "the canonical pleme-io WASM/WASI breathable service";
#           };
#         };
#       };
#   }
#
# Result: `nix run .#hello-world` runs the program. `nix build .` builds
# the default (first declared). Multiple programs in one flake supported.
{ nixpkgs, flake-utils }:

{
  # Reference to the tatara-lisp flake — we read its
  # packages.<system>.tatara-script for the runtime.
  tataraLispFlake,

  # Map of name → program-spec (source, args, extraEnv, description).
  # See program.nix for the full spec shape.
  programs,

  # Optional list of systems to build for. Defaults to the standard
  # pleme-io quartet.
  systems ? [
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
  ],
}@cfg:

flake-utils.lib.eachSystem cfg.systems (system: let
  pkgs = import nixpkgs { inherit system; };
  tataraLisp = cfg.tataraLispFlake.packages.${system}.tatara-lisp-script;

  buildProgram = import ./program.nix { inherit pkgs tataraLisp; };

  built = builtins.mapAttrs
    (name: spec: buildProgram (spec // { inherit name; }))
    cfg.programs;

  # First program is the default.
  firstName = builtins.head (builtins.attrNames cfg.programs);
in {
  packages = built // {
    default = built.${firstName};
  };

  apps = builtins.mapAttrs (name: pkg: {
    type = "app";
    program = "${pkg}/bin/${name}";
  }) built // {
    default = {
      type = "app";
      program = "${built.${firstName}}/bin/${firstName}";
    };
  };

  devShells.default = pkgs.mkShellNoCC {
    buildInputs = [ tataraLisp ];
  };
})
