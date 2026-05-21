# substrate/lib/scripting/mkTataraScript.nix
#
# mkTataraScript (inline-source variant) — compile a .tlisp source string
# into a runnable shell shim. Writes the source to /nix/store, then wraps
# it in `exec tatara-script <script-file> "$@"` (the smallest possible
# adapter to satisfy nix-run's "program is an executable path" contract).
#
# This is the redistributable form of the helper that was previously
# inlined in `lib/infra/ansible-collection.nix`. Any builder that emits
# nix-run apps backed by embedded .tlisp source can consume this — the
# ansible-collection helper is just the first caller.
#
# Sibling helper: `lib/build/scripting/tatara-script.nix` wraps a .tlisp
# file already on disk (referenced by path under a source tree). Use that
# when the script lives in the consumer's repo; use this one when the
# .tlisp source is generated in Nix as a string.
#
# Usage:
#
#   let
#     mkTataraScript = import "${substrate}/lib/scripting/mkTataraScript.nix" {
#       inherit pkgs;
#       tataraScript = inputs.tatara-lisp.packages.${system}.tatara-script;
#     };
#   in pkgs.writeShellScript "wrapper" ''
#     exec ${mkTataraScript "my-app" ''
#       (println "hello from tlisp")
#     ''} "$@"
#   '';
#
# Arguments to the importer:
#
#   pkgs         — a nixpkgs instance (used for writeText + writeShellScript)
#   tataraScript — either a derivation (its bin/tatara-script is used) or
#                  a bare command name expected on PATH (default
#                  "tatara-script")
#
# Returns: a function `scriptName -> src -> derivation` where the
# derivation is a shell script that invokes tatara-script on the embedded
# source with positional args forwarded.

{ pkgs, tataraScript ? "tatara-script" }:

let
  lib = pkgs.lib;
  # Resolve tataraScript to a shell-quotable invocation. If a derivation
  # was passed, point at its bin/tatara-script; otherwise treat it as a
  # bare command on $PATH.
  tataraInvocation =
    if lib.isDerivation tataraScript
    then "${tataraScript}/bin/tatara-script"
    else tataraScript;
in
  scriptName: src:
  let
    scriptFile = pkgs.writeText "${scriptName}.tlisp" src;
  in pkgs.writeShellScript "${scriptName}-wrapper" ''
    exec ${tataraInvocation} ${scriptFile} "$@"
  ''
