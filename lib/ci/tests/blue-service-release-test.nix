{ lib }:

let
  testHelpers = import ../../util/test-helpers.nix { inherit lib; };

  text = builtins.readFile ../../../.github/workflows/blue-service-release.yml;

  parts = lib.splitString "\njobs:\n" text;
  header = builtins.elemAt parts 0;
  jobsText = builtins.elemAt parts 1;

  blocks =
    (lib.foldl'
      (acc: l:
        let m = builtins.match "  ([a-z][a-z0-9-]*):" l;
        in
        if m != null then
          acc // { cur = builtins.head m; out = acc.out // { ${builtins.head m} = ""; }; }
        else if acc.cur == null then
          acc
        else
          acc // { out = acc.out // { ${acc.cur} = acc.out.${acc.cur} + l + "\n"; }; })
      { cur = null; out = { }; }
      (lib.splitString "\n" jobsText)).out;

  job = name: blocks.${name} or "";

  offset = needle: s:
    if lib.hasInfix needle s then builtins.stringLength (builtins.head (lib.splitString needle s)) else -1;

  before = a: b: s: offset a s >= 0 && offset b s >= 0 && offset a s < offset b s;

  gatedOnRelease = "    needs: release\n    if: needs.release.outputs.released == 'true'\n";

  tests = [
    (testHelpers.mkTest "the-jobs-are-release-chart-deploy"
      (builtins.attrNames blocks == [ "chart" "deploy" "release" ])
      "the reusable has exactly three jobs; a fourth needs its own row in blue-service-release.cases.tsv and here")

    (testHelpers.mkTest "it-is-only-a-reusable"
      (lib.hasInfix "\non:\n  workflow_call:\n" header
        && !(lib.hasInfix "\n  push:" header)
        && !(lib.hasInfix "\n  pull_request:" header)
        && !(lib.hasInfix "\n  schedule:" header)
        && !(lib.hasInfix "\n  workflow_dispatch:" header))
      "the release runs only when a caller's workflow calls it, never on a trigger of its own")

    (testHelpers.mkTest "release-runs-only-on-a-push-to-main"
      (lib.hasInfix "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'\n" (job "release"))
      "a pull request, another branch or a dispatch must never release")

    (testHelpers.mkTest "release-is-first"
      (!(lib.hasInfix "needs:" (job "release")))
      "release waits on nothing inside the reusable; the caller's CI job is its needs")

    (testHelpers.mkTest "chart-follows-a-release"
      (lib.hasInfix gatedOnRelease (job "chart"))
      "the chart is published only after release tagged a version")

    (testHelpers.mkTest "deploy-follows-a-release"
      (lib.hasInfix gatedOnRelease (job "deploy"))
      "the fleet is asked to bump only after release pushed a tag")

    (testHelpers.mkTest "release-bumps-then-tags"
      (before "mode: bump" "mode: tag" (job "release")
        && lib.hasInfix "if: steps.bump.outputs.released == 'true'\n" (job "release"))
      "tag runs after bump and only when bump released")

    (testHelpers.mkTest "release-builds-only-the-head-it-was-started-for"
      (lib.hasInfix "ref: main\n" (job "release")
        && lib.hasInfix "expect-head: \${{ github.sha }}\n" (job "release"))
      "bump reads the newest main and stands down when main moved past this run's commit")

    (testHelpers.mkTest "chart-packages-the-tag"
      (lib.hasInfix "ref: \${{ needs.release.outputs.tag }}\n" (job "chart")
        && lib.hasInfix "uses: pleme-io/actions/helm-publish@main\n" (job "chart")
        && lib.hasInfix "packages: write\n" (job "chart"))
      "the chart is the one rendered at the release tag, pushed by the shared helm-publish action")

    (testHelpers.mkTest "deploy-only-asks"
      (lib.hasInfix "mode: request-deploy\n" (job "deploy")
        && !(lib.hasInfix "flake-bump" text))
      "the service asks the consumer to bump; the consumer's own workflow holds the push")
  ];

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  asCheck = testHelpers.mkAsCheck { name = "blue-service-release-workflow-test"; label = "ci/blue-service-release"; } result;
}
