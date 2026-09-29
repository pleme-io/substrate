# claude-md-gate.nix — fail the build when a CLAUDE.md outgrows what loads.
#
# Claude Code does not load a CLAUDE.md over 40,000 characters, so anything
# past that is written and never read. This gate measures BYTES
# (`builtins.stringLength`), and UTF-8 bytes are always >= characters, so a
# 40,000-byte ceiling can never admit an over-limit file; it can only be
# stricter on multi-byte-dense text, which is the safe direction. The number
# comes from that external limit, not from what a file weighs today.
#
#   (import ./claude-md-gate.nix { inherit lib; }).check pkgs {
#     name = "substrate"; file = ./CLAUDE.md;
#   }
{ lib }:

let
  defaultLimit = 40000;
in
{
  inherit defaultLimit;

  # measure file -> { bytes; limit; within; }
  measure = { file, limit ? defaultLimit }:
    let bytes = builtins.stringLength (builtins.readFile file);
    in { inherit bytes limit; within = bytes <= limit; };

  # check pkgs { name; file; limit? } -> a derivation for `checks`, or an
  # eval error naming the overage.
  check = pkgs: { name, file, limit ? defaultLimit }:
    let
      bytes = builtins.stringLength (builtins.readFile file);
    in
    if bytes <= limit
    then pkgs.runCommand "claude-md-size-${name}" { } ''
      echo "${name} CLAUDE.md: ${toString bytes} of ${toString limit} bytes" > $out
    ''
    else throw ''
      ${name} CLAUDE.md is ${toString bytes} bytes, over the ${toString limit}-byte
      ceiling by ${toString (bytes - limit)}. Claude Code will not load it. Move
      detail into docs/ and leave the index + short hard rules here.'';
}
