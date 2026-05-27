# adapter-apps.nix — every Adapter verb wrapped as a flake app.
#
# Substrate's rust shape builders compose these into the consumer's
# `apps.${system}` attrset, giving every consumer six operator
# verbs for free:
#
#   nix run .#lock        — gen lock (resolve manifest → lockfile)
#   nix run .#build-spec  — gen build (emit typed build-spec)
#   nix run .#plan        — gen plan (preview a bump)
#   nix run .#confirm     — gen confirm (verify invariants)
#   nix run .#diff        — gen diff (current state vs reference)
#   nix run .#sbom        — gen sbom (emit SBOM)
#
# Each app shells out to substrate-bound gen. Identical surface
# will be lifted out of `rust/` into `lib/` once the npm + ruby
# adapters land — same six verbs, ecosystem-routed.
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
    plan = {
      type = "app";
      program = "${mkVerb "plan"}/bin/gen-plan";
    };
    confirm = {
      type = "app";
      program = "${mkVerb "confirm"}/bin/gen-confirm";
    };
    diff = {
      type = "app";
      program = "${mkVerb "diff"}/bin/gen-diff";
    };
    sbom = {
      type = "app";
      program = "${mkVerb "sbom"}/bin/gen-sbom";
    };
  };
}
