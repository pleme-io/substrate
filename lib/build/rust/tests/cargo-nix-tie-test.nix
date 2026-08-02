# cargo-nix-tie-test.nix — eval-time tests for ../cargo-nix-tie.nix.
#
# Family C (report-returning): evaluates to `{ total; passed; }` and throws
# on failure. Wired through lib/util/eval-suites.nix with an assertion
# floor, because `nix-instantiate --eval --strict` on a report-returning
# suite exits 0 whether every assertion passes or every one fails. See the
# ★★ `runTests` REPORTS section of CLAUDE.md.
#
# ── WHAT MAKES THIS SUITE NON-VACUOUS ───────────────────────────────────
#
# A freshness gate is the exact shape that goes green over an empty subject
# set, so this suite is built around three fixtures that pin all three
# verdicts, not just the happy one:
#
#   fixtures/cargo-nix-stale/   — the RED RUN. Same crate COUNT as its own
#     Cargo.lock (3 == 3, so only a set comparison sees it), one version
#     behind on aws-lc-fips-sys. Modelled on the real aresta drift.
#   fixtures/cargo-nix-fresh/   — proves the tie is not always-red. Without
#     this, a `status` hard-wired to "stale" would pass every other test.
#   fixtures/cargo-nix-absent/  — a Cargo.lock and NO Cargo.nix, the shape
#     of the overwhelming majority of consumers. Proves the tie is a no-op
#     there, AND that it reports "absent" rather than "fresh" — nothing to
#     verify must never read as verified.
#   fixtures/cargo-nix-unparseable/ — a crate2nix shape the parser cannot
#     read. Must be reported as a parser gap, never as staleness.
#   fixtures/cargo-nix-generated/  — a DIRECTORY named Cargo.nix beside a
#     real Cargo.lock, the shape of crate2nix's generated derivation
#     output. Regression: the first cut of this tie was handed that
#     fallback by three builders and would have read a directory on every
#     repo whose IFD generation succeeded.
#
# `importFresh` is tested separately from `status` on purpose. `status` is
# a value; `importFresh` is where the throw has to land, BEFORE the
# artifact is produced. Each fixture Cargo.nix carries a `marker` attr, so
# a tie that computed the right verdict and then failed to fire would show
# up as the marker coming back rather than as a throw.
let
  tie = import ../cargo-nix-tie.nix { };

  fresh = ./fixtures/cargo-nix-fresh;
  stale = ./fixtures/cargo-nix-stale;
  absent = ./fixtures/cargo-nix-absent;
  unparseable = ./fixtures/cargo-nix-unparseable;
  generated = ./fixtures/cargo-nix-generated;

  statusOf = dir: tie.status { cargoNix = dir + "/Cargo.nix"; };

  # `tryEval` forces to WHNF only, so force the whole value.
  attempt = v: builtins.tryEval (builtins.deepSeq v v);

  importOf =
    dir:
    attempt (tie.importFresh {
      cargoNix = dir + "/Cargo.nix";
      args = { pkgs = { }; };
    });

  sFresh = statusOf fresh;
  sStale = statusOf stale;
  sAbsent = statusOf absent;

  iFresh = importOf fresh;
  iStale = importOf stale;
  iAbsent = attempt (tie.assertFresh { cargoNix = absent + "/Cargo.nix"; } "untouched");
  iUnparseable = attempt (tie.artifactCrates (unparseable + "/Cargo.nix"));

  # The generated fixture pins BOTH sides of the regression: `cargoLock`
  # is passed explicitly, exactly as the three fallback builders do, so a
  # `pathExists`-only guard would sail past and read the directory.
  sGenerated = tie.status {
    cargoNix = generated + "/Cargo.nix";
    cargoLock = generated + "/Cargo.lock";
  };
  iGenerated = attempt (tie.assertFresh {
    cargoNix = generated + "/Cargo.nix";
    cargoLock = generated + "/Cargo.lock";
  } "untouched");

  has = x: xs: builtins.elem x xs;

  assertions = [
    # ── the RED RUN ──────────────────────────────────────────────────
    { label = "stale fixture: status.kind == stale";
      pred = sStale.kind == "stale"; }
    { label = "stale fixture: names the version the lock resolved";
      pred = has "aws-lc-fips-sys-0.13.16" sStale.missing; }
    { label = "stale fixture: names the version the artifact carries";
      pred = has "aws-lc-fips-sys-0.13.14" sStale.extra; }
    { label = "stale fixture: equal COUNTS are still caught (3 == 3)";
      pred = sStale.lockCount == 3 && sStale.artifactCount == 3; }
    { label = "stale fixture: does not implicate the crates that agree";
      pred = !(has "serde-1.0.228" sStale.missing)
          && !(has "serde-1.0.228" sStale.extra); }
    { label = "RED RUN — importFresh THROWS on the stale artifact";
      pred = !iStale.success; }
    { label = "RED RUN — the stale artifact is never produced";
      pred = !(iStale.success && iStale.value ? marker); }

    # ── not always-red ───────────────────────────────────────────────
    { label = "fresh fixture: status.kind == fresh";
      pred = sFresh.kind == "fresh"; }
    { label = "fresh fixture: no drift in either direction";
      pred = sFresh.missing == [ ] && sFresh.extra == [ ]; }
    { label = "fresh fixture: importFresh returns the imported artifact";
      pred = iFresh.success && iFresh.value.marker == "fresh-fixture-was-imported"; }
    { label = "fresh fixture: the workspace member is tied, not just the deps";
      pred = has "fixture-root-0.1.0" (tie.artifactCrates (fresh + "/Cargo.nix")); }

    # ── not vacuous over the empty subject set ───────────────────────
    { label = "absent fixture: kind is `absent`, NOT `fresh`";
      pred = sAbsent.kind == "absent"; }
    { label = "absent fixture: reports nothing verified, not zero drift";
      pred = sAbsent.lockCount == 0 && sAbsent.artifactCount == 0; }
    { label = "ADDITIVITY — assertFresh is the identity with no Cargo.nix";
      pred = iAbsent.success && iAbsent.value == "untouched"; }

    # ── a parser gap is never reported as drift ──────────────────────
    { label = "unparseable fixture: throws rather than under-extracting";
      pred = !iUnparseable.success; }

    # ── regression: a generated Cargo.nix is a DIRECTORY ─────────────
    { label = "generated fixture: a directory-shaped Cargo.nix is `absent`";
      pred = sGenerated.kind == "absent"; }
    { label = "generated fixture: the primitive refuses it, not the caller";
      pred = iGenerated.success && iGenerated.value == "untouched"; }

    # ── the shared primitive's own contract ──────────────────────────
    { label = "freshness-tie.held returns true when the tie holds";
      pred =
        (import ../../shared/freshness-tie.nix { }).held {
          subject = "t"; artifact = "a"; where = "w"; fresh = true;
          sides = [ ]; cause = "c"; fix = "f";
        } == true; }
    { label = "freshness-tie.held THROWS rather than returning false";
      pred =
        !(attempt (
          (import ../../shared/freshness-tie.nix { }).held {
            subject = "t"; artifact = "a"; where = "w"; fresh = false;
            sides = [ ]; cause = "c"; fix = "f";
          }
        )).success; }
    { label = "freshness-tie.hint degrades rather than replacing the error";
      pred = (import ../../shared/freshness-tie.nix { }).hint
               (throw "boom") == "<unprintable src>"; }
  ];

  failures = builtins.filter (a: !a.pred) assertions;
in
if failures == [ ] then
  { total = builtins.length assertions; passed = builtins.length assertions; }
else
  throw ''
    cargo-nix-tie-test: ${toString (builtins.length failures)} of ${toString (builtins.length assertions)} assertions failed:
    ${builtins.concatStringsSep "\n" (map (a: "  - " + a.label) failures)}
  ''
