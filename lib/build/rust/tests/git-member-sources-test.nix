{
  pkgs,
  lib ? pkgs.lib,
  blueRev ? "8922b04c13a44fe7220e614ed32bbebf8368f81f",
}:

let
  testHelpers = import ../../../util/test-helpers.nix { inherit lib; };
  builder = import ../lockfile-builder.nix { inherit pkgs lib; };

  gitCrate = name: {
    inherit name;
    version = "0.0.0";
    source = {
      kind = "git";
      url = "https://github.com/pleme-io/blue";
      rev = blueRev;
    };
  };

  declaring = gitCrate "blue-lang-pkg";
  undeclaring = gitCrate "blue-lang-runtime";
  rooted = builder.gitMemberRootedOf declaring;
  declaringSrc = builder.mkSrcOf pkgs ./. declaring;
  undeclaringSrc = builder.mkSrcOf pkgs ./. undeclaring;
  has = src: rel: builtins.pathExists "${src}/${rel}";

  tests = [
    (testHelpers.mkTest "declaring-member-is-rooted-at-its-directory"
      (rooted != null && rooted.rel == "crates/blue-lang-pkg")
      "blue-lang-pkg declares [package.metadata.substrate] sources at ${blueRev}, so it must build from the whole repository with crates/blue-lang-pkg as its member directory")

    (testHelpers.mkTest "declaring-member-source-holds-its-declared-sources"
      (has declaringSrc "bidamas" && has declaringSrc "crates/blue-lang-pkg/build.rs")
      "the source of blue-lang-pkg lacks ../../bidamas or its own build.rs; its build.rs then embeds an empty standard distribution")

    (testHelpers.mkTest "undeclaring-member-stays-narrowed-to-its-directory"
      (builder.gitMemberRootedOf undeclaring == null
        && has undeclaringSrc "Cargo.toml"
        && !(has undeclaringSrc "bidamas"))
      "blue-lang-runtime declares no sources, so its source must stay narrowed to crates/blue-lang-runtime")
  ];

  result = testHelpers.runTests tests;
in
{
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  asCheck = pkgs':
    if result.allPassed
    then pkgs'.runCommand "rust-git-member-sources" { } ''
      echo "rust git-member sources gate: ${result.summary}" > $out
    ''
    else throw ''
      rust git-member sources gate FAILED (${result.summary}):
        - ${builtins.concatStringsSep "\n  - " result.failures}'';
}
