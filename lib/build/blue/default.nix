# The blue builders: how a bidama, a blue program and a blue project are built
# into derivations, taking `blue` (the toolchain) as an argument.
#
# substrate holds them so every blue project and every fleet node builds
# through one family, and the toolchain is a parameter, never an import:
# substrate has no input on blue, so nothing here can name a particular blue.
# `bidamas` is blue's own bidama builders (mkBidama, mkBluePath,
# mkBlueWithBidamas, mkBlueApp, the gates), moved here byte for byte from
# blue/bidamas/mk-bidama.nix (docs/PURE-BLUE.md D0).
{ }:
{
  bidamas = args: import ./bidamas.nix args;
}
