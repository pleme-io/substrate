# crate-override-compose.nix — typed composition of crate-override maps.
#
# A *crate-override map* is `{ <crateName> = oldAttrs: newAttrs; }` — the
# shape buildRustCrate consumes as `crateOverrides` and nixpkgs ships as
# `defaultCrateOverrides`. Two such maps routinely need merging: a
# caller's *base* map (raw nixpkgs defaults `//` the consumer's own
# per-crate tweaks) and a fleet *safety-net* map (pleme-crate-overrides.nix
# — fixes for nixpkgs/upstream bugs that must never be silently dropped).
#
# `composeOverrideMaps { base, winner }` returns a per-crate resolver
# `name -> (attrs -> attrs)`:
#   - neither map has `name` → identity (`oldAttrs: oldAttrs`)
#   - only one has it        → that map's function, verbatim
#   - both have it           → compose at the attrs level, **winner wins**
#                              on field collision: `(base attrs) // (winner attrs)`
#
# WHY winner-wins, and why `winner` is the safety-net (not the caller):
# every entry in the safety-net map exists to FIX a bug carried in `base`.
# The canonical case: nixpkgs' `defaultCrateOverrides.proc-macro-crate`
# (3.5.0) postPatch `--replace-fail`s the literal `env::var("CARGO")`,
# which the crate removed — strict substitute then hard-errors in
# patchPhase, failing every gen-built Rust image. Callers thread raw
# nixpkgs defaults into `base`, so if `base` won the collision the very
# bug the safety-net fixes would be re-introduced. The safety-net manages
# only the handful of crates with known breakage, and caller extras key
# off their own crate names, so winner-wins is *surgical* — it changes
# behavior only for the safety-net crates, where it must.
#
# Pure: needs only `lib` (no `pkgs`, no `<nixpkgs>` lookup) so it is usable
# in pure-eval flake context alongside pleme-crate-overrides.nix.
{ lib }:
let
  # composeOverrideMaps :: { base : OverrideMap; winner : OverrideMap }
  #                     -> String -> (Attrs -> Attrs)
  composeOverrideMaps = { base, winner }: name:
    let
      b = base.${name} or null;
      w = winner.${name} or null;
    in
      if b == null && w == null then (oldAttrs: oldAttrs)
      else if b == null then w
      else if w == null then b
      else (attrs: (b attrs) // (w attrs));

  # mergeOverrideMaps :: { base : OverrideMap; winner : OverrideMap }
  #                   -> OverrideMap
  # Eager attrset form: produces a full `{ <name> = composedFn; }` map over
  # the union of both maps' keys, each value already composed by
  # `composeOverrideMaps`. For consumers that want a plain `crateOverrides`
  # attrset to hand to buildRustCrate rather than a per-name resolver.
  mergeOverrideMaps = { base, winner }:
    let
      resolver = composeOverrideMaps { inherit base winner; };
      names = lib.unique ((builtins.attrNames base) ++ (builtins.attrNames winner));
    in
      lib.genAttrs names resolver;
in {
  inherit composeOverrideMaps mergeOverrideMaps;
}
