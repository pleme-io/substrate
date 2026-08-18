# ifd-free-git-source-test.nix — the CHECKER for INV-4 ("No
# Import-from-Derivation", docs/cia/cache-theory.md §INV-4).
#
# ── WHY THIS FILE EXISTS ────────────────────────────────────────────────
#
# INV-4 was written down, named a checker called `ifd_avoidance`, and marked
# "auto-fixable: No (manual)". That checker did not exist. MEASURED 2026-08-18
# at HEAD dbe58e6: `git grep allow-import-from-derivation` over the whole repo
# returns ZERO hits — the option is never named, let alone set, in any
# workflow, any eval suite, or any doc. Nothing had ever evaluated anything
# with IFD disabled. The invariant was prose.
#
# ★ AND THE RULE TEXT IS NARROWER THAN THE AXIOM, which is why prose alone was
# never going to catch this. INV-4's rule reads "generated files (Cargo.nix,
# node-packages.nix) must be committed to the repo, not generated at
# evaluation time" — a statement about COMMITTED ARTIFACTS. The fleet's
# dominant IFD was not that at all: every affected repo had a perfectly good
# committed `Cargo.gen.lock`. It was a `pathExists` probe inside a fetched
# derivation, a mechanism the rule text does not describe. So this gate
# enforces the underlying AXIOM — C6, "evaluation must not build" — rather
# than the rule's example list, and that is deliberate: an audit that had
# checked exactly what INV-4 says would have reported the whole fleet clean.
#
# What it was supposed to be protecting, in the words of the defect that got
# through: substrate's `mkSrcOf` git branch fetches a crate's source and then
# calls `builtins.pathExists` INSIDE that output to find which subdirectory
# holds the crate's `Cargo.toml`. When the fetch produces a DERIVATION (the
# `fetchPkgs.fetchgit` fallback), reading a path inside it forces it to be
# BUILT, mid-evaluation. Both `gen-pin.json` files pointed at a gen revision
# whose own `Cargo.toml` still carried a git dependency, and because
# `wrapWithRuntimeGen` (tool-release.nix) puts gen on every consumer's PATH,
# EVERY consumer's eval inherited gen's git-dep probe — a 25.5% fleet IFD rate
# over 55 conclusive probes, 13 of 14 hits this one mechanism, an IFD-taking
# eval measured at 35s against 0s IFD-free. Five Go repos took it on a Rust
# crate. It was found by a human noticing a slow eval.
#
# ── THE TWO INDEPENDENT GUARDS, and why one is not enough ───────────────
#
# 1. THE INVOCATION. A Nix expression cannot set
#    `allow-import-from-derivation` for itself, so the only enforcement that
#    covers the WHOLE eval is an invocation that turns the option off:
#
#      nix build --no-link -L --option allow-import-from-derivation false \
#        '.#checks.x86_64-linux.rust-git-source-ifd-free'
#
#    That is the step in `.github/workflows/nix-tests.yml`. It catches an IFD
#    introduced ANYWHERE on the path to this fixture, including one nobody
#    thought to assert about.
#
# 2. THE STRUCTURAL ASSERTION, in this file. Guard 1 lives in a workflow
#    step, and a workflow step can be edited, reordered, or copied without its
#    `--option` flag — at which point the gate silently becomes "does this
#    fixture evaluate", which it does either way. So the check ALSO reads the
#    resolved source's STRING CONTEXT and refuses a derivation dependency:
#
#      pure fetcher  ->  { "/nix/store/…-source"    = { path = true;      }; }
#      derivation    ->  { "/nix/store/…-x.drv"     = { outputs = ["out"]; }; }
#
#    Measured, both branches, 2026-08-18. A source whose context names a
#    `.drv` is one that CANNOT be probed without a build — which is the
#    property INV-4 is actually about — so this assertion is red even with the
#    option left on.
#
# ── ANTI-VACUITY: THE DENOMINATOR IS INSIDE THE COMPARED VALUE ──────────
#
# The failure mode to fear here is a fixture that stops having a git
# dependency. A registry-only fixture resolves fine, IFD-free, forever, while
# the branch that actually regressed goes unexercised — a gate that is green
# because it is looking at nothing. So `gitSourceCount` is asserted to be
# exactly the number of git sources the fixture is supposed to carry, and the
# pinned rev + pinned `git_nar_sha256` are asserted to have reached the
# resolved source. Discovery finding nothing fails; it does not pass quietly.
#
# ── RED-RUN RECORD (2026-08-18, aarch64-darwin) ────────────────────────
#
# Reintroducing the exact defect — making `githubOwnerRepo` return `null` so
# the github URL falls through to `fetchPkgs.fetchgit`, the shape every
# pre-2026-07-26 substrate had — turns this red both ways:
#
#   * with the option OFF, the eval dies with
#     `error: cannot build '/nix/store/…-shibori-53e586a.drv^out' during
#      evaluation because the option 'allow-import-from-derivation' is
#      disabled`
#     — note the derivation NAME, `<repo>-<7charrev>`, which is `fetchgit`'s
#     naming and is exactly what the fleet's five IFD hits were called.
#   * with the option ON, `git-source-carries-no-derivation-dependency` fails
#     on the `outputs = ["out"]` context entry.
#
# ── WHAT THIS DOES NOT COVER, stated so nobody reads it as more ─────────
#
#   * crate2nix's `mkGitHash` is a SECOND, INDEPENDENT IFD mechanism, on the
#     `Cargo.nix` path this file never touches (~137 fleet repos ship one).
#   * substrate's own gen bootstrap (`packages.<sys>.gen`) is IFD BY
#     CONSTRUCTION — gen's source is fetched as a derivation and a
#     flake-builder is evaluated over it — so it cannot be a subject here.
#   * The `fetchPkgs.fetchgit` fallback for NON-github git URLs is STILL IFD
#     today, and this fixture does not cover it — it pins a github URL, so it
#     rides the `builtins.fetchTree` fast path. That is the right choice on a
#     measurement, not a guess: across 609 top-level `Cargo.lock` files in
#     ~/code/github/pleme-io on 2026-08-18, 663 of 663 git crate sources are on
#     `github.com`, so the fetchTree branch is 100% of the fleet's live git-dep
#     surface and the fetchgit fallback has zero consumers. It is a dormant
#     hole, not a live one — but it is a hole, and the honest fix is to make
#     the fallback pure rather than to widen this fixture.
#
# Usage (report form):
#   nix eval --impure --file lib/build/rust/tests/ifd-free-git-source-test.nix \
#     --apply 'f: (f { pkgs = import <nixpkgs> {}; }).summary'
# Wired as a derivation via `asCheck pkgs` in substrate's flake `checks`.
{
  pkgs,
  lib ? pkgs.lib,
  # Overridable ONLY so the anti-vacuity claim above can be exercised: point
  # this at a registry-only workspace and `fixture-still-exercises-the-git-
  # branch` must go red. Same seam, same reason, as `eval-suites.nix`'s
  # `workflow` argument. Every real consumer takes the default.
  fixture ? ./fixtures/git-dep-delta,
}:

let
  testHelpers = import ../../../util/test-helpers.nix { inherit lib; };

  # The REAL engine, not a copy. `mkSrcOf` is exported from
  # lockfile-builder.nix specifically so this gate drives the live function —
  # a gate over a reimplementation proves nothing about the fleet.
  builder = import ../lockfile-builder.nix { inherit pkgs lib; };
  deltaReader = import ../lockfile-delta.nix { inherit lib; };

  # Committed in the fixture's Cargo.lock + Cargo.gen.lock. Restated here so
  # the assertions compare against a constant rather than against whatever the
  # fixture happens to say — a test that reads its expectation out of its own
  # subject cannot fail.
  expectedGitSourceCount = 1;
  expectedUrl = "https://github.com/pleme-io/shibori";
  expectedRev = "53e586af23b707e0c8f4da743f76f5dcbbcadbc0";
  expectedNar = "sha256-nxR7aEymaiaBl/0EiLO/16FnvSxgVwKA6KvheGPZ07g=";

  # ── The subject ───────────────────────────────────────────────────────
  spec = deltaReader.reconstruct fixture;

  gitCrates =
    if spec == null then { }
    else lib.filterAttrs (_: c: c.source.kind == "git") (spec.crates or { });
  gitCount = builtins.length (builtins.attrNames gitCrates);

  # THE FORCING STEP. Evaluating a `mkSrcOf` result forces `firstMatch`, which
  # forces the `builtins.pathExists` probes INSIDE the fetched tree — the
  # mechanism under test. Nothing below is meaningful unless this is forced,
  # which every assertion that touches `resolved` does.
  resolved = lib.mapAttrs (_: c: builder.mkSrcOf pkgs fixture c) gitCrates;
  resolvedList = builtins.attrValues resolved;

  # A store path produced by a pure fetcher carries a `path` context entry; a
  # derivation output carries `outputs` (or `allOutputs`). Only the former can
  # be read at eval time without building anything.
  contextEntries = p: builtins.attrValues (builtins.getContext "${p}");
  isDerivationFree = p:
    lib.all (e: (e.path or false) && !(e ? outputs) && !(e ? allOutputs))
      (contextEntries p);

  storePathOf = p: builtins.unsafeDiscardStringContext "${p}";

  # The one git crate, by construction of the fixture. Guarded by the
  # denominator assertion below, so a fixture that lost its git dep fails
  # `fixture-still-exercises-the-git-branch` rather than dying here.
  theGitCrate =
    if gitCount == expectedGitSourceCount
    then builtins.head (builtins.attrValues gitCrates)
    else { source = { url = "<no git source in fixture>"; rev = null; sha256 = null; }; };

  tests = [
    # ── The fixture is readable at all ──────────────────────────────────
    (testHelpers.mkTest "delta-reader-accepts-the-committed-triple"
      (spec != null)
      "lockfile-delta.reconstruct returned null — the fixture is missing one of Cargo.toml / Cargo.lock / Cargo.gen.lock, or its D2 tie is stale (recompute cargo_lock_sha256 with `builtins.hashFile \"sha256\"`)")

    # ── ANTI-VACUITY: the denominator, inside the compared value ────────
    (testHelpers.mkTest "fixture-still-exercises-the-git-branch"
      (gitCount == expectedGitSourceCount)
      "expected exactly ${toString expectedGitSourceCount} git source in the fixture, found ${toString gitCount} — a registry-only fixture passes this whole file while never touching the branch that regressed")

    # ── The delta actually carried the git pins into the source ─────────
    (testHelpers.mkTest "git-source-url-has-its-query-string-stripped"
      (theGitCrate.source.url == expectedUrl)
      "expected the `?tag=v0.1.1` query stripped to ${expectedUrl}, got ${toString theGitCrate.source.url}")

    (testHelpers.mkTest "git-source-carries-the-pinned-rev"
      (theGitCrate.source.rev == expectedRev)
      "the reconstructed source must pin the rev the fixture's Cargo.lock names; a floating ref is not a locked source")

    (testHelpers.mkTest "git-source-carries-the-pinned-git-nar"
      (theGitCrate.source.sha256 == expectedNar)
      "the delta's git_nar_sha256 entry did not reach the source — without it the fetchgit fallback has no hash and this fixture would stop being a pinned subject")

    # ── The forcing assertions: resolving must not need a build ─────────
    (testHelpers.mkTest "git-source-resolves-to-a-store-path"
      (lib.all (p: lib.hasPrefix builtins.storeDir (storePathOf p)) resolvedList)
      "mkSrcOf did not resolve the git source to a store path")

    (testHelpers.mkTest "git-source-carries-no-derivation-dependency"
      (lib.all isDerivationFree resolvedList)
      "the resolved git source depends on a DERIVATION (its string context names a .drv), so mkSrcOf's pathExists probe inside it forces a build mid-evaluation — this is INV-4, violated; see this file's header")

    # ── The URL-SPELLING table ──────────────────────────────────────────
    #
    # Added 2026-08-18. The five assertions above prove the IFD-free property
    # for the ONE dep the fixture ships: an `https://`, tag-pinned github dep.
    # They are silent about which URLs actually REACH that property, and that
    # gap shipped a live defect -- `githubOwnerRepo` matched `https://` only,
    # so `ssh://git@github.com/o/r.git` fell through to `fetchgit` (a
    # DERIVATION) and the layout probe forced it mid-evaluation. pleme-theme
    # and pleme-widget-gen were both un-evaluable under
    # `--option allow-import-from-derivation false` for exactly this reason,
    # while their committed deltas recorded the dep's NAR hash all along.
    #
    # So the property is proven once, by the assertions above, and this table
    # proves every accepted spelling reaches the branch that has it. That is
    # cheaper and stricter than one fixture per spelling: a fixture needs a
    # real reachable repo per URL form, and a private ssh dep cannot be a
    # fixture in a public gate at all.
    #
    # Negative rows are the anti-vacuity half. Without them the table passes
    # if `githubOwnerRepo` were widened to match EVERYTHING, which would send
    # genuinely non-github deps down the github fetchTree path and fail at
    # fetch time instead of falling back to fetchgit as designed.
    (testHelpers.mkTest "github-url-spellings-all-resolve-to-owner-repo"
      (lib.all (row: builder.githubOwnerRepo (builtins.elemAt row 0)
                     == { owner = builtins.elemAt row 1; repo = builtins.elemAt row 2; })
        [
          [ "https://github.com/pleme-io/iac-forge"          "pleme-io" "iac-forge" ]
          [ "https://github.com/pleme-io/iac-forge.git"      "pleme-io" "iac-forge" ]
          [ "ssh://git@github.com/pleme-io/pleme-widget-spec.git" "pleme-io" "pleme-widget-spec" ]
          [ "git@github.com:pleme-io/shibori.git"            "pleme-io" "shibori" ]
        ])
      "a github URL spelling did not resolve to {owner, repo} — it will fall through to fetchgit, which is a DERIVATION, and mkSrcOf's layout probe then forces it mid-evaluation (INV-4)")

    (testHelpers.mkTest "non-github-urls-still-fall-through"
      (lib.all (u: builder.githubOwnerRepo u == null)
        [
          "https://gitlab.com/foo/bar"
          "ssh://git@bitbucket.org/foo/bar.git"
          "https://git.sr.ht/~foo/bar"
        ])
      "a non-github URL was matched as github — it would be sent down the fetchTree path and fail at fetch time rather than falling back to fetchgit as designed")

    (testHelpers.mkTest "fetched-tree-is-readable-without-a-build"
      (lib.all (p: builtins.pathExists ("${storePathOf p}/Cargo.toml")) resolvedList)
      "could not read inside the resolved source without realising it — the probe mkSrcOf itself performs is the IFD mechanism INV-4 forbids")
  ];

  result = testHelpers.runTests tests;

in
{
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  # Diagnostics — deliberately outside the verdict so a red gate is still
  # inspectable (`nix eval … --apply 'f: (f { pkgs = …; }).observed'`).
  observed = {
    gitSourceCount = gitCount;
    gitCrateKeys = builtins.attrNames gitCrates;
    resolvedPaths = lib.mapAttrs (_: storePathOf) resolved;
    resolvedContexts = lib.mapAttrs (_: p: builtins.getContext "${p}") resolved;
  };

  asCheck = pkgs':
    if result.allPassed
    then pkgs'.runCommand "rust-git-source-ifd-free" { } ''
      echo "INV-4 rust git-source IFD gate: ${result.summary}" > $out
    ''
    else throw ''
      INV-4 rust git-source IFD gate FAILED (${result.summary}):
        - ${builtins.concatStringsSep "\n  - " result.failures}'';
}
