# mkHardenedPkgs — compose a named list of CVE mitigations (see
# ./cve-mitigations/default.nix) onto a pkgs set via nixpkgs' own overlay
# fixed-point mechanism (`lib.composeManyExtensions`).
#
# This is the reusable "harden profile" primitive: an image declares which
# named mitigations apply to it (`mitigations = [ "metrics-server-version-
# bump" ]`), gets back a pkgs set where `pkgs.<affected-attr>` resolves to
# the fixed derivation, and every catalog entry it did NOT list costs it
# nothing -- see cve-mitigations/default.nix's own header for why that's
# true by construction, not something this function has to engineer.
#
# Replaces the fleet's prior pattern of three independent, hand-rolled
# per-image mechanisms achieving the same shape (rabbitmq's inline
# `pkgs.extend` overlay, vector/node-exporter's second/third independent
# flake input pinned to a newer nixpkgs channel for exactly one package,
# neo4j's `.overrideAttrs` + `postFixup` jar-swap) with zero shared
# primitive between them -- each of those three mechanisms is expressible
# as an ordinary overlay fragment under this one composition function; see
# the migration note in cve-mitigations/default.nix's sibling entries once
# they land.
#
# A referenced-but-missing catalog key throws a real Nix "attribute
# missing" eval error (`catalog.${name}` on a nonexistent name) --
# deliberately not `catalog.${name} or null` swallowed into a silent
# no-op. A typo'd mitigation name must fail loudly, the same way a typo'd
# nixpkgs attribute does.
{ lib }:
let
  catalog = import ./cve-mitigations { inherit lib; };
in
  { pkgs, mitigations ? [] }:
    pkgs.extend (lib.composeManyExtensions
      (map (name: catalog.${name}.overlay) mitigations))
