{
  pkgs,
  lib ? pkgs.lib,
  blueRev ? "8922b04c13a44fe7220e614ed32bbebf8368f81f",
  nymRev ? "1abb0cf1b92f135e71c84b738bcd19b97916a3eb",
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

  nymCrate = name: {
    inherit name;
    version = "2.0.1";
    source = {
      kind = "git";
      url = "https://github.com/nymtech/nym";
      rev = nymRev;
    };
  };
  macroSrc = builder.mkSrcOf pkgs ./. (nymCrate "nym-http-api-client-macro");
  sdkSrc = builder.mkSrcOf pkgs ./. (nymCrate "nym-sdk");
  nameIn = src: (builtins.fromTOML (builtins.readFile "${src}/Cargo.toml")).package.name or null;

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

    (testHelpers.mkTest "a-member-outside-the-conventional-layouts-is-found-by-the-workspace-member-list"
      (nameIn macroSrc == "nym-http-api-client-macro"
        && has macroSrc "build.rs"
        && nameIn sdkSrc == "nym-sdk")
      "nym-http-api-client-macro lives at common/http-api-client-macro and nym-sdk at sdk/rust/nym-sdk; a source left at the repository root builds with no build.rs (caligo run 43657075195)")
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
