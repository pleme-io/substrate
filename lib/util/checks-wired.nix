# checks-wired.nix — every declared flake check has a CI step that builds it.
#
# `nix flake check` is not what CI runs here: each check gets its own
# `nix build .#checks.<system>.<name>` step so a failure names the suite. The
# cost of that shape is that a new check is green forever if nobody adds its
# step. Measured 2026-09-29 in substrate: 9 of 26 declared checks had no step.
# This gate turns that silent gap into a failing build.
#
#   (import ./checks-wired.nix { inherit lib; }).check pkgs {
#     names = builtins.attrNames self.checks.x86_64-linux;
#     system = "x86_64-linux";
#     workflowText = builtins.readFile ./.github/workflows/nix-tests.yml;
#   }
{ lib }:

let
  # missing { names; system; workflowText } -> [ name ] with no build step.
  # A step must spell the full attribute path followed by a quote, so
  # `checks.x86_64-linux.rust-shape` does not count as wiring `rust`.
  missing = { names, system, workflowText }:
    lib.filter
      (n: !(lib.hasInfix "checks.${system}.${n}'" workflowText
        || lib.hasInfix "checks.${system}.${n}\"" workflowText))
      names;
in
{
  inherit missing;

  check = pkgs: { names, system, workflowText }:
    let gap = missing { inherit names system workflowText; };
    in
    if gap == [ ]
    then pkgs.runCommand "checks-wired" { } ''
      echo "checks-wired: ${toString (builtins.length names)} of ${toString (builtins.length names)} checks have a CI step" > $out
    ''
    else throw ''
      checks-wired: ${toString (builtins.length gap)} declared check(s) have no CI build step:
        - ${lib.concatStringsSep "\n  - " gap}
      Add `nix build --no-link -L '.#checks.${system}.<name>'` for each to the
      workflow, or the check stays green because nothing runs it.'';
}
