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

  workspace = ./fixtures/member-source;
  own = crateName: relativePath:
    policy.memberSrc { src = workspace; inherit crateName relativePath; memberSource = "own"; };
  ownA = own "a" "crates/a";
  ownB = own "b" "crates/b";
  ownE = own "e" "crates/e";

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

    (testHelpers.mkTest "member-workspace-is-identity"
      (policy.memberSrc { src = workspace; crateName = "a"; relativePath = "crates/a"; } == workspace
        && policy.memberSrc { src = workspace; crateName = "a"; relativePath = "crates/a"; memberSource = "workspace"; } == workspace)
      "the default must hand every member the whole tree, so adopting the parameter changes no derivation")

    (testHelpers.mkTest "member-own-root-crate-is-identity"
      (own "root" "." == workspace && own "root" "" == workspace)
      "a crate at the workspace root owns the whole tree")

    (testHelpers.mkTest "member-own-keeps-member-manifests-and-declared"
      (lib.all (has ownA) [ "Cargo.toml" "Cargo.lock" "crates/a/Cargo.toml" "crates/a/src/lib.rs" "shared/data.txt" ])
      "own must keep the member, the root manifests and every declared source")

    (testHelpers.mkTest "member-own-drops-siblings-prose-and-root-orphan"
      (lib.all (r: !(has ownA r)) [ "crates/b" "other" "docs" "src" "crates/e" ])
      "own must drop every path the member neither owns nor declares")

    (testHelpers.mkTest "member-own-drops-build-only-dirs"
      (!(has ownA "crates/a/tests") && !(has ownA "crates/a/benches") && !(has ownB "crates/a"))
      "own must drop tests/ and benches/, which buildRustCrate never compiles")

    (testHelpers.mkTest "member-own-declared-file-inside-tests-survives"
      (has ownE "crates/e/tests/fixture.txt" && !(has ownE "crates/e/tests/t.rs"))
      "a declared source re-admits exactly that path inside a build-only dir")

    (testHelpers.mkTest "member-own-escaping-source-throws"
      (!(builtins.tryEval (builtins.deepSeq (toString (own "c" "crates/c")) true)).success)
      "a declared source outside the workspace root must be an eval error")

    (testHelpers.mkTest "member-own-missing-source-throws"
      (!(builtins.tryEval (builtins.deepSeq (toString (own "d" "crates/d")) true)).success)
      "a declared source that does not exist must be an eval error")

    (testHelpers.mkTest "member-unknown-value-throws"
      (!(builtins.tryEval (toString (policy.memberSrc { src = workspace; crateName = "a"; relativePath = "crates/a"; memberSource = "narrow"; }))).success)
      "an unknown memberSource value must be an eval error")

    (testHelpers.mkTest "member-failure-hint-names-the-fix"
      (policy.memberFailureHint { crateName = "a"; relativePath = "crates/a"; } == { }
        && lib.hasInfix "[package.metadata.substrate] sources"
          (policy.memberFailureHint { crateName = "a"; relativePath = "crates/a"; memberSource = "own"; }).failureHook)
      "a narrowed member's failure must name the declaration that fixes it")
  ];

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  asCheck = testHelpers.mkAsCheck { name = "source-policy-test"; label = "source-policy"; } result;
}
