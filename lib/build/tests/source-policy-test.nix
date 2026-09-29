# Pure eval tests for lib/build/source-policy.nix.
#
# WHAT THIS GUARDS. `prose = "excluded"` is what keeps a documentation edit
# from rebuilding and restarting a deployed daemon, and `prose = "included"`
# is what lets every existing consumer adopt the policy without a single
# derivation changing. Both directions are asserted, and a value outside the
# enum must throw.
#
# NOT VACUOUS: `excluded-drops-top-level-prose` fails if the filter stops
# filtering; `excluded-keeps-code-and-member-readme` fails if it filters too
# much; `included-is-identity` fails if the default starts reshaping trees.
#
# Wired as a derivation via `asCheck pkgs` in substrate's flake checks.
{ lib }:

let
  testHelpers = import ../../util/test-helpers.nix { inherit lib; };
  policy = import ../source-policy.nix { inherit lib; };

  fixture = ./fixtures/source-policy;
  excluded = policy.buildSrc { src = fixture; prose = "excluded"; };
  has = root: rel: builtins.pathExists (root + "/${rel}");

  tests = [
    (testHelpers.mkTest "included-is-identity"
      (policy.buildSrc { src = fixture; } == fixture
        && policy.buildSrc { src = fixture; prose = "included"; } == fixture)
      "the default must return the tree untouched so adopting the policy changes no derivation")

    (testHelpers.mkTest "excluded-drops-top-level-prose"
      (!(has excluded "docs") && !(has excluded "README.md") && !(has excluded "NOTES.md"))
      "excluded must drop top-level docs/ and every top-level *.md")

    (testHelpers.mkTest "excluded-keeps-code-and-member-readme"
      (has excluded "Cargo.toml" && has excluded "src/lib.rs" && has excluded "crates/member/README.md")
      "excluded must keep code and member-level READMEs, which crates commonly include_str!")

    (testHelpers.mkTest "non-path-src-passes-through"
      (policy.buildSrc { src = "/nix/store/already-a-store-path"; prose = "excluded"; }
        == "/nix/store/already-a-store-path")
      "a non-path src is not a local tree; the policy must leave it alone")

    (testHelpers.mkTest "unknown-value-throws"
      (!(builtins.tryEval (policy.buildSrc { src = fixture; prose = "stripped"; })).success)
      "an unknown prose value must be an eval error, never a silent no-op")
  ];

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  asCheck = pkgs:
    if result.allPassed
    then pkgs.runCommand "source-policy-test" { } ''
      echo "source-policy: ${result.summary}" > $out
    ''
    else throw ''
      source-policy tests FAILED (${result.summary}):
        - ${builtins.concatStringsSep "\n  - " result.failures}'';
}
