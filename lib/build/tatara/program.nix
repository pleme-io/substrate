# ============================================================================
# TATARA-LISP PROGRAM BUILDER — `tlisp2nix` analog of crate2nix
# ============================================================================
# Takes a tatara-lisp source URL (or a local path) and produces a Nix
# derivation that:
#
#   1. Fetches the .tlisp bytes via the appropriate forge fetcher
#      (fetchFromGitHub / fetchFromGitLab / builtins.fetchurl).
#   2. Stores those bytes in /nix/store keyed by the resolved hash,
#      making every cluster's pull a single download fleet-wide.
#   3. Builds a wrapper `nix run`-target that points `tatara-script`
#      at the cached source.
#
# This is the canonical "package a tatara-lisp program as Nix" pattern.
# Same content-addressing as theory/TATARA-PACKAGING.md describes,
# but with the /nix/store cache instead of ~/.cache/tatara/sources.
# Both caches coexist; either path produces the same BLAKE3.
#
# ----------------------------------------------------------------------------
# USAGE 1 — author writes a flake that builds their .tlisp into nix:
#
#   { inputs.substrate.url = "github:pleme-io/substrate";
#     outputs = { self, nixpkgs, substrate, ... }: let
#       system = "x86_64-linux";
#       pkgs = import nixpkgs { inherit system; };
#       tataraLisp = pkgs.fetchurl {
#         url = "https://github.com/pleme-io/tatara-lisp/releases/download/v0.2.0/tatara-script-${system}";
#         sha256 = "...";
#       };
#       buildProgram = import "${substrate}/lib/build/tatara/program.nix" {
#         inherit pkgs tataraLisp;
#       };
#     in {
#       packages.${system}.hello-world = buildProgram {
#         name   = "hello-world";
#         source = {
#           type  = "local";
#           path  = ./hello-world/main.tlisp;
#         };
#         args   = [];
#       };
#     };
#   }
#
# Then `nix run .#hello-world` runs it.
#
# ----------------------------------------------------------------------------
# USAGE 2 — fetch a tatara-lisp program directly from GitHub:
#
#   buildProgram {
#     name = "hello-world";
#     source = {
#       type  = "github";
#       owner = "pleme-io";
#       repo  = "programs";
#       path  = "hello-world/main.tlisp";
#       rev   = "v0.1.0";
#       sha256 = "0000…0000";   # nix-prefetch-github result
#     };
#   }
#
# The fetched .tlisp is cached at /nix/store/<hash>-hello-world.tlisp;
# every cluster (or laptop) that builds the same flake input shares
# that store path. Content-addressed Nix store doubles as the
# tatara-source cache for free.
#
# ----------------------------------------------------------------------------
{ pkgs, tataraLisp }:

let
  inherit (pkgs) lib;

  # Resolve the source according to its declared type. Returns a
  # derivation for the .tlisp file.
  resolveSource = source:
    if source.type == "local" then
      pkgs.runCommand "tlisp-source" {
        src = source.path;
      } ''
        mkdir -p $out
        cp $src $out/main.tlisp
      ''
    else if source.type == "github" then
      pkgs.fetchFromGitHub {
        inherit (source) owner repo;
        rev    = source.rev;
        sha256 = source.sha256;
      } + "/${source.path}"
    else if source.type == "gitlab" then
      pkgs.fetchFromGitLab {
        inherit (source) owner repo;
        rev    = source.rev;
        sha256 = source.sha256;
      } + "/${source.path}"
    else if source.type == "url" then
      # Generic fetch; caller supplies the raw URL + content hash.
      pkgs.fetchurl {
        url    = source.url;
        sha256 = source.sha256;
      }
    else
      throw "unknown source.type: ${source.type}; want local | github | gitlab | url";

in
{
  # name      — package + binary name; should be unique within the flake.
  # source    — source descriptor (see USAGE blocks above).
  # args      — additional default args passed to tatara-script before user argv.
  # extraEnv  — extra env vars (e.g. PORT=8080) baked into the wrapper.
  # description — optional human-readable description for the derivation meta.
  name,
  source,
  args ? [],
  extraEnv ? {},
  description ? "tatara-lisp program ${name}",
}@cfg:

let
  resolvedSource = resolveSource cfg.source;

  argList = lib.concatStringsSep " " (map lib.escapeShellArg cfg.args);

  envSetters = lib.concatStringsSep "\n" (lib.mapAttrsToList
    (k: v: "export ${k}=${lib.escapeShellArg (toString v)}")
    cfg.extraEnv);

in
pkgs.writeShellApplication {
  name = cfg.name;
  runtimeInputs = [ tataraLisp ];
  text = ''
    ${envSetters}
    exec tatara-script "${resolvedSource}" ${argList} "$@"
  '';

  # Embed the description into the derivation's meta so consumers see
  # it under `nix run .#<name> --help`-style introspection.
  meta = {
    inherit description;
    license = lib.licenses.mit;
    mainProgram = cfg.name;
  };
}
