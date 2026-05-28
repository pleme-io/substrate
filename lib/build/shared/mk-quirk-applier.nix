# mk-quirk-applier.nix — typed-quirk dispatch combinator shared
# across every ecosystem's `quirk-apply.nix`.
#
# Source of truth for WHICH packages need WHICH quirks lives in the
# per-ecosystem Rust adapter (`gen-cargo`, `gen-npm`, `gen-bundler`,
# `gen-helm`, `gen-pip`, `gen-poetry`, `gen-gomod`, `gen-ansible`,
# `gen-swift`). This file owns the *shape* of the apply pipeline:
# dispatch on `quirk.kind` to a class-helper, fold left across a
# list of quirks, return a merge-friendly attrset.
#
# Consumers pass a `helpers` table — `{ "<kind>" = quirk: attrs:
# attrs-overrides; }`. The `kind` matches the serde tag the typed
# Rust enum emits (`#[serde(tag = "kind", rename_all = "kebab-case")]`).
#
# Returns: `{ applyQuirks }`. Use in the `built` mapAttrs step of
# the ecosystem's lockfile-builder.nix.
{ lib, helpers }:
let
  applyQuirk = quirk: attrs:
    if helpers ? "${quirk.kind}" then
      (helpers."${quirk.kind}" quirk) attrs
    else
      throw "mk-quirk-applier: unknown quirk kind '${quirk.kind}'. Add a helpers.\"${quirk.kind}\" arm in the consumer's quirk-apply.nix when adding a new variant to the matching gen-<ecosystem>::quirks enum.";
in {
  # Apply a list of quirks left-to-right against base attrs.
  applyQuirks = quirks: attrs:
    builtins.foldl' (acc: quirk: acc // (applyQuirk quirk attrs)) {} quirks;
}
