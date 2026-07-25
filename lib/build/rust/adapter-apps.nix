# adapter-apps.nix — every REAL gen verb wrapped as a flake app.
#
# Substrate's rust shape builders compose these into the consumer's
# `apps.${system}` attrset, giving every consumer the gen operator
# verbs for free:
#
#   nix run .#lock        — gen lock    (resolve manifest → lockfile state)
#   nix run .#build-spec  — gen build   (emit typed build-spec; needs cargo)
#   nix run .#confirm     — gen confirm (OFFLINE delta-freshness gate)
#
# Only verbs the gen CLI actually implements are surfaced. `plan` /
# `diff` / `sbom` were PHANTOM apps — no matching `gen` subcommand, so
# `nix run .#plan` errored with clap's `unrecognized subcommand`.
# Shipping a broken app surface is dishonest; they're removed until (and
# if) the real verbs land, at which point they're added back here as a
# one-line entry each. `confirm` is the first of the trio to become real
# (gen 2bedb69+ — the pure offline `Cargo.gen.lock`-vs-`Cargo.lock`
# freshness check that also backs the `gen-confirm` nix-flake-check).
#
# Each app shells out to substrate-bound gen. Identical surface will be
# lifted out of `rust/` into `lib/` once the npm + ruby adapters land —
# same verbs, ecosystem-routed.
{ pkgs, gen }:
let
  # Operator runs `nix run .#<verb>` from their workspace; PWD is
  # already the manifest root. Pass through any extra args via `$@`.
  mkVerb = verb: pkgs.writeShellApplication {
    name = "gen-${verb}";
    runtimeInputs = [ gen ];
    text = ''
      exec gen ${verb} . "$@"
    '';
  };
in {
  apps = {
    lock = {
      type = "app";
      program = "${mkVerb "lock"}/bin/gen-lock";
    };
    build-spec = {
      type = "app";
      program = "${mkVerb "build"}/bin/gen-build";
    };
    confirm = {
      type = "app";
      program = "${mkVerb "confirm"}/bin/gen-confirm";
    };
  };
}
