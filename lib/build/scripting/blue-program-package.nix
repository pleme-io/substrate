# substrate/lib/build/scripting/blue-program-package.nix
#
# mkBlueProgramPackage — wire a blue program (`.b`) into an INSTALLABLE
# package: `bin/<name>` runs the program, for PATH, a launchd agent or a
# systemd unit. The blue sibling of tatara-script-package.nix, for the
# development ladder's top rung.
#
# This is a NAME, not an implementation. The one implementation is blue's
# `mkBlueApp` (`blue/bidamas/mk-bidama.nix`), reached through the consumer's
# package set as `pkgs.blueLib` — blue's `overlays.default` (or
# `overlays.bidamas`) puts it there. substrate cannot take blue as an input
# (blue builds on substrate), so it composes over what the consumer's pkgs
# carries. From 2026-09-27 to the next day this file was a second copy with a
# bash makeWrapper; mkBlueApp's wrapper is compiled (makeBinaryWrapper) and
# runs `blue run --quiet <file> --`, so a command prints only what it writes
# and every argument a user types goes to the program.
#
# Usage:
#
#   mkBlueProgramPackage = import "${substrate}/lib/build/scripting/blue-program-package.nix" {
#     inherit pkgs;
#   };
#   mkBlueProgramPackage {
#     name = "tehai";
#     blue = pkgs.blue-with-bidamas;    # a blue that already resolves the bidamas
#     source = ''use("tehai")\nth_main()\n'';   # or program = ./main.b;
#     extraPath = [ pkgs.openssh ];
#     env = { TEHAI_TIMEOUT_S = "2"; };
#   }
#
# With `pkgs.blueApp` (the same overlay) the blue and the distribution are
# already bound: `pkgs.blueApp { name; source; tools; env; }`.
#
# Arguments:
#   name       the binary's name, bin/<name>.
#   blue       a blue binary that resolves the bidamas the program uses.
#   program    a path to a .b file; or
#   source     the program's text (exactly one of the two).
#   extraPath  packages whose bin/ the program may exec (a process boundary),
#              suffixed to PATH so a node's own copy wins.
#   env        environment set on every run as a default (the caller's own
#              environment wins where it sets the same name).
#   checkAtBuild  run `blue check` on the program while building (default
#              true). A store file is read-only, so a program blue's check
#              stage rejects can never run: tehai and ukai exited 1 every
#              15 s on ryn (B0012 on 2026-09-30, B0023 on 2026-10-27) while
#              their packages built. With this, that program fails the build.
{ pkgs }:
{
  name,
  blue,
  program ? null,
  source ? null,
  extraPath ? [ ],
  env ? { },
  checkAtBuild ? true,
}:
assert pkgs.lib.assertMsg (pkgs ? blueLib)
  "mkBlueProgramPackage ${name}: pkgs has no blueLib; add blue's overlays.default (or overlays.bidamas) to this package set";
let
  app = pkgs.blueLib.mkBlueApp {
    inherit name blue program source env;
    # `blue` already carries its distribution; nothing to add on BLUE_PATH.
    bidamas = { };
    tools = extraPath;
  };
  file = if program != null then "${program}" else "$out/share/blue/${name}.b";
in
if checkAtBuild then
  app.overrideAttrs (old: {
    buildCommand = old.buildCommand + ''
      HOME=$TMPDIR ${blue}/bin/blue check ${file} > $TMPDIR/blue-check.log 2>&1 || { cat $TMPDIR/blue-check.log; exit 1; }
    '';
  })
else
  app
