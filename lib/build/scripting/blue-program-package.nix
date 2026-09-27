# substrate/lib/build/scripting/blue-program-package.nix
#
# mkBlueProgramPackage — wire a blue program (`.b`) into an INSTALLABLE
# package: a derivation with `bin/<name>` that runs `blue run <program>` with
# the bidama distribution on BLUE_PATH. The blue sibling of
# tatara-script-package.nix, for the development ladder's top rung: a tool's
# logic is blue, and this is the one way it reaches PATH, a launchd daemon or
# a systemd unit.
#
# The wrapper is makeWrapper, not a shell script: the program path, extra PATH
# entries and environment are flags on the wrapper, so nothing here is shell
# to maintain.
#
# Usage:
#
#   let
#     mkBlueProgramPackage = import "${substrate}/lib/build/scripting/blue-program-package.nix" {
#       inherit pkgs;
#     };
#   in
#     mkBlueProgramPackage {
#       name = "tehai";
#       blue = pkgs.blue-with-bidamas;    # blue, wrapped with its bidamas
#       program = ./tehai-main.b;         # a file, or
#       # source = ''use("tehai")\nth_main()\n'';
#       extraPath = [ pkgs.openssh ];
#       env = { TEHAI_TIMEOUT_S = "2"; };
#     }
#
# Arguments:
#   name       the binary's name, bin/<name>.
#   blue       a blue binary that already resolves the bidamas the program
#              uses (the fleet's `blue-with-bidamas`, blue's mkBlueWithBidamas).
#   program    a path to a .b file; or
#   source     the program's text, written to the store as <name>.b.
#   extraPath  packages whose bin/ the program may exec (a process boundary).
#   env        environment set on every run (the caller's own environment
#              wins where it sets the same name).
{ pkgs }:
{
  name,
  blue,
  program ? null,
  source ? null,
  extraPath ? [ ],
  env ? { },
}:
assert pkgs.lib.assertMsg ((program == null) != (source == null))
  "mkBlueProgramPackage ${name}: give exactly one of `program` (a .b file) or `source` (its text)";
let
  lib = pkgs.lib;
  file = if program != null then program else pkgs.writeText "${name}.b" source;
  envFlags = lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "--set-default ${lib.escapeShellArg k} ${lib.escapeShellArg v}") env);
in
pkgs.runCommand name
  {
    nativeBuildInputs = [ pkgs.makeWrapper ];
    meta.mainProgram = name;
    passthru = { inherit file; };
  }
  ''
    mkdir -p $out/bin
    makeWrapper ${blue}/bin/blue $out/bin/${name} \
      --add-flags "run ${file}" \
      ${lib.optionalString (extraPath != [ ]) "--prefix PATH : ${lib.makeBinPath extraPath}"} \
      ${envFlags}
  ''
