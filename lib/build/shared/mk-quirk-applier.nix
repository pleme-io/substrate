# mk-quirk-applier.nix — v0.1 back-compat alias for
# `mk-typed-dispatcher.nix`.
#
# The original name leaks the gen-adapter origin; the primitive
# itself is the *typed-variant-fold catamorphism at a language
# boundary*. New consumers SHOULD import
# `./mk-typed-dispatcher.nix` directly. This shim exists so
# v0.1 callers continue to work unchanged.
#
# See `theory/QUIRK-APPLIER.md` §IV-bis for context.
{ lib, helpers }:
import ./mk-typed-dispatcher.nix { inherit lib helpers; }
