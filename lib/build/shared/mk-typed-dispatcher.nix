# mk-typed-dispatcher.nix — typed-tagged-union catamorphism at a
# language boundary. Substrate primitive shared across every
# dispatch site that consumes a typed Rust enum (or any other
# typed variant universe) by serde tag.
#
# Pattern: Rust enum (closed, total) -> serde tag (string) -> Nix
# helpers table (closed by the throw-on-unknown rule) -> fold-left
# producing merge-friendly override attrs.
#
# Consumers pass a `helpers` table — `{ "<kind>" = quirk: attrs:
# attrs-overrides; }`. The `kind` matches the serde tag the typed
# Rust enum emits (`#[serde(tag = "kind", rename_all = "kebab-case")]`).
#
# Returns: `{ applyVariants }` (and a back-compat alias
# `applyQuirks` for v0.1 callers).
#
# Use anywhere a typed variant universe meets a Nix consumer.
# Canonical instances at v0.1: 9 ecosystem `quirk-apply.nix`
# files at `substrate/lib/build/<eco>/quirk-apply.nix`. See
# `theory/QUIRK-APPLIER.md` §IV-bis for the redistribution surface
# and `theory/QUIRK-APPLIER.md` §IV-bis.3 for the high-leverage
# moves to expose this fully.
{ lib, helpers }:
let
  applyVariant = variant: attrs:
    if helpers ? "${variant.kind}" then
      (helpers."${variant.kind}" variant) attrs
    else
      throw "mk-typed-dispatcher: unknown variant kind '${variant.kind}'. Add a helpers.\"${variant.kind}\" arm in the consumer when the typed enum gains a variant.";
in {
  # Apply a list of variants left-to-right against base attrs. Each
  # variant sees `attrs` overlaid with every override accumulated so
  # far (`attrs // acc`), not the pristine base — otherwise two
  # variants that both derive the same output key from `attrs` (e.g.
  # two ForceCfg quirks each appending to `extraRustcOpts`) would each
  # compute their append against the ORIGINAL list and the second
  # `acc // result` would silently clobber the first's contribution
  # instead of accumulating. Caught live: wgpu-hal needs both
  # `supports_64bit_atomics` and `supports_ptr_atomics` ForceCfg'd,
  # and only the last-applied one was surviving the fold.
  applyVariants = variants: attrs:
    builtins.foldl' (acc: variant: acc // (applyVariant variant (attrs // acc))) {} variants;

  # v0.1 back-compat alias. New consumers SHOULD use applyVariants.
  applyQuirks = variants: attrs:
    builtins.foldl' (acc: variant: acc // (applyVariant variant (attrs // acc))) {} variants;
}
