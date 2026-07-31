# Pure eval tests for the darwin-SVH determinism flags in lockfile-builder.nix.
#
# ── WHAT THIS GUARDS, AND WHY IT IS A TEXT GATE ───────────────────────────
#
# `mkBuiltTree`'s `mergedExtras` sets `extraRustcOpts` for every crate compile,
# and that key has THREE independent contributors which must all survive:
#
#   args.extraRustcOpts           quirk-apply.nix:31 puts a ForceCfg quirk's
#                                 `--cfg <name>` pair here
#   overrideExtras.extraRustcOpts a crate's own override entry
#   -Z remap-cwd-prefix=.         the darwin SVH determinism flag
#
# The merge is `buildRustCrate (args // mergedExtras)`, so `mergedExtras` WINS
# OUTRIGHT: any contributor not named on the right-hand side is DROPPED, not
# merged. That is not hypothetical — it shipped. 75fd70e wrote only
# `(overrideExtras.extraRustcOpts or [])`, which silently discarded the `--cfg`
# for any crate carrying BOTH a ForceCfg quirk and an override entry. Such a
# crate then compiles the wrong cfg branch, plausibly still succeeding, with
# nothing in the log naming the cause — strictly worse than the SVH skew the
# commit set out to fix. Repaired in the follow-up; this test is what makes the
# repair stick.
#
# TIER — state it plainly rather than round it up. This is a SOURCE-TEXT DRIFT
# GATE, the weakest honest tier: it reads lockfile-builder.nix as a string and
# asserts the three contributors and the two determinism settings are present at
# the merge site. It does NOT prove the flags reach a rendered derivation, and it
# cannot see a semantic regression that keeps the text but changes the meaning.
#
# Why text and not a real drv assertion (which the Go side does at
# lib/build/go/tests/package-builder-ferrite-test.nix:85, `hasInfix
# "SOURCE_DATE_EPOCH" nodeF0.drv.buildPhase`): reaching `mergedExtras` requires
# a full `mkProject` invocation with a lockfile, a build-spec and a crate
# universe — scaffolding far heavier than the defect, and it would drag IFD into
# an eval-only check suite. The cheap gate that WOULD HAVE CAUGHT THE ACTUAL
# REGRESSION is worth more than the expensive one that was never written. A real
# two-build `.rustc`-section comparison is the separate, expensive, darwin-only
# measurement tracked alongside this.
#
# Usage: wired as a derivation via `asCheck pkgs` in substrate's flake checks.
{ lib }:

let
  testHelpers = import ../../../util/test-helpers.nix { inherit lib; };
  inherit (lib) hasInfix;

  # lib/build/rust/tests/ -> ../lockfile-builder.nix
  builderSrc = builtins.readFile ../lockfile-builder.nix;

  # The `++`-chained merge expression, as one contiguous string. Asserting the
  # WHOLE chain rather than three separate substrings is deliberate: three
  # independent `hasInfix` checks would still pass if someone split them across
  # two different attrsets, which is precisely the shape that drops one.
  mergeChain = ''extraRustcOpts = (args.extraRustcOpts or [])'';

  tests = [
    (testHelpers.mkTest "builder-source-is-readable"
      (builtins.isString builderSrc && builtins.stringLength builderSrc > 1000)
      "the builder must be readable as text — a gate that cannot read its subject never fires")

    # ── The regression this file exists to catch ──────────────────────
    (testHelpers.mkTest "quirk-cfgs-survive-the-merge"
      (hasInfix mergeChain builderSrc)
      "args.extraRustcOpts MUST head the extraRustcOpts chain — it carries ForceCfg quirks' --cfg pairs (quirk-apply.nix:31), and mergedExtras wins the // merge outright, so omitting it DROPS them silently")

    (testHelpers.mkTest "override-opts-survive-the-merge"
      (hasInfix ''++ (overrideExtras.extraRustcOpts or [])'' builderSrc)
      "a crate's own override opts must be concatenated, not replaced — overrideFor returns ONLY the override's new attrs (crate-override-compose.nix:44), so they reach the merge nowhere else")

    (testHelpers.mkTest "svh-remap-flag-present"
      (hasInfix ''"-Z" "remap-cwd-prefix=."'' builderSrc)
      "the darwin SVH determinism flag must remain — without it two builds of one crate embed different cwd-derived metadata and a cached rlib can disagree with what a dependent was compiled against (E0463/E0514/E0786)")

    (testHelpers.mkTest "rustc-bootstrap-present"
      (hasInfix ''RUSTC_BOOTSTRAP = "1"'' builderSrc)
      "-Z flags require a nightly-or-bootstrap rustc; without RUSTC_BOOTSTRAP the remap flag is not merely inert, the compile REJECTS it")

    # ── The ordering that makes the chain correct ─────────────────────
    (testHelpers.mkTest "determinism-flag-is-the-tail-of-the-chain"
      (let
         idxOf = needle:
           let parts = lib.splitString needle builderSrc;
           in if builtins.length parts < 2 then (-1)
              else builtins.stringLength (builtins.head parts);
         quirkAt = idxOf mergeChain;
         remapAt = idxOf ''"-Z" "remap-cwd-prefix=."'';
       in quirkAt > 0 && remapAt > quirkAt)
      "the determinism flag must come AFTER the semantic contributors so it reads as the tail of one chain; a --cfg appearing after it would suggest a second, competing assignment")
  ];

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  asCheck = pkgs:
    if result.allPassed
    then pkgs.runCommand "rust-determinism-flags-test" { } ''
      echo "rust/determinism-flags: ${result.summary}" > $out
    ''
    else throw ''
      rust/determinism-flags tests FAILED (${result.summary}):
        - ${builtins.concatStringsSep "\n  - " result.failures}'';
}
