# lockfile-delta-schema-test.nix — eval-time tests for ../delta-schema.nix and
# the closed reader in ../lockfile-delta.nix.
#
# Family C (report-returning): evaluates to `{ total; passed; }` and throws on
# failure. Wired through lib/util/eval-suites.nix with an assertion floor,
# because `nix-instantiate --eval --strict` on a report-returning suite exits 0
# whether every assertion passes or every one fails.
#
# ── WHAT MAKES THIS SUITE NON-VACUOUS ───────────────────────────────────
#
# The defect being fixed is a reader that answered YES to "is this the shape I
# expect?" for every possible input, via 17 bare `or` defaults. A suite that
# only checks the happy path would have passed against the BROKEN reader too.
# So the anchor case is the one the old reader got wrong:
#
#   fixtures/gen-lock-current-gen/ — THE RED RUN. The literal bytes gen-gomod
#     emits TODAY: {schema_version, go_sum_sha256, source_hashes}, with no
#     per_package at all. Measured 2026-08-08 against the OLD reader, it
#     returned { version = 1; packages = { }; root_package = null;
#     workspace_members = [ ]; } behind a GREEN D2 tie — a zero-package build
#     spec, no throw. Against the new reader it must throw naming `per_package`
#     AND the producing adapter.
#   fixtures/gen-lock-fresh/       — proves the reader is not always-red. Without
#     it, a `throw` hard-wired at the top would pass every other case.
#   fixtures/gen-lock-empty-pkgs/  — `per_package` present but EMPTY. The old
#     `root_package = if packageKeys == [ ] then null` branch is deleted, so
#     this must be refused rather than reconstructed.
#   fixtures/gen-lock-unknown-key/ — producer drift at the top level.
#   fixtures/gen-lock-pkg-unknown/ — producer drift inside a package.
#   fixtures/gen-lock-no-module/   — a required per-package field absent.
#   fixtures/gen-lock-stale/       — the D2 tie still fires; the schema work
#     must not have displaced the freshness check.
#   fixtures/gen-lock-absent/      — no Go.gen.lock: `reconstruct` returns null
#     and the ladder falls through. Nothing-to-verify must not read as verified.
#
# ── THE FORCING CASE (the critic's mandatory override) ──────────────────
#
# Nix is lazy. `seq d2ok { … }` forces ONE binding, so an unreferenced
# `closedTop`/`nonEmptyOk` would be DEAD IN PRODUCTION while this suite — which
# uses `deepSeq` — reported them green. That is the vacuous-guard class the
# whole change exists to remove, reproduced inside its own fix.
#
# `forcedWithoutDeepSeq` below is the guard against that: it reads exactly ONE
# field of the result and requires the refusal to fire anyway. If someone later
# reverts the `seq closedTop (seq nonEmptyOk …)` nesting, every `deepSeq` case
# here stays green and THAT case goes red.
let
  lib = import <nixpkgs/lib>;
  reader = import ../lockfile-delta.nix { inherit lib; };
  fx = name: ./fixtures + "/${name}";

  # tryEval + deepSeq: forces the whole result, catching a throw anywhere.
  evalOf = path: builtins.tryEval (builtins.deepSeq (reader.reconstruct path) (reader.reconstruct path));

  throws = path: !(evalOf path).success;
  okOf = path: (evalOf path).value;

  # Reads ONE field only — no deepSeq. Proves the check is forced in the
  # production path rather than by a test that forces everything.
  forcedWithoutDeepSeq = path:
    !(builtins.tryEval ((reader.reconstruct path).root_package)).success;

  cases = [
    # ── the red run: the current gen shape ────────────────────────────
    { name = "current-gen-shape is REFUSED (was green+empty before)"; expr = throws (fx "gen-lock-current-gen"); }
    { name = "current-gen-shape refusal fires without deepSeq"; expr = forcedWithoutDeepSeq (fx "gen-lock-current-gen"); }

    # ── the reader is not always-red ──────────────────────────────────
    { name = "well-formed delta reconstructs"; expr = (evalOf (fx "gen-lock-fresh")).success; }
    { name = "root_package is the single package key"; expr = (okOf (fx "gen-lock-fresh")).root_package == "example.com/x"; }
    { name = "workspace_members carries the module path"; expr = (okOf (fx "gen-lock-fresh")).workspace_members == [ "example.com/x" ]; }
    { name = "vendorHash is surfaced"; expr = (okOf (fx "gen-lock-fresh")).packages."example.com/x".args.vendorHash == "sha256-AAAA"; }
    { name = "has_external_deps derives from vendor_hash"; expr = (okOf (fx "gen-lock-fresh")).packages."example.com/x".has_external_deps; }
    { name = "declared default applies: tags"; expr = (okOf (fx "gen-lock-fresh")).packages."example.com/x".args.tags == [ "netgo" ]; }
    { name = "declared default applies: absent ldflags -> []"; expr = (okOf (fx "gen-lock-fresh")).packages."example.com/x".args.ldflags == [ ]; }
    { name = "pname falls back to the delta key"; expr = (okOf (fx "gen-lock-fresh")).packages."example.com/x".args.pname == "example.com/x"; }
    { name = "absent version -> declared 0.0.0"; expr = (okOf (fx "gen-lock-fresh")).packages."example.com/x".version == "0.0.0"; }

    # ── empty set is refused, not reconstructed ───────────────────────
    { name = "empty per_package is REFUSED"; expr = throws (fx "gen-lock-empty-pkgs"); }
    { name = "empty per_package refusal fires without deepSeq"; expr = forcedWithoutDeepSeq (fx "gen-lock-empty-pkgs"); }

    # ── producer drift, both levels ───────────────────────────────────
    { name = "undeclared TOP-LEVEL key is REFUSED"; expr = throws (fx "gen-lock-unknown-key"); }
    { name = "undeclared top-level key fires without deepSeq"; expr = forcedWithoutDeepSeq (fx "gen-lock-unknown-key"); }
    { name = "undeclared PER-PACKAGE key is REFUSED"; expr = throws (fx "gen-lock-pkg-unknown"); }

    # ── required per-package field ────────────────────────────────────
    { name = "absent per-package `module` is REFUSED"; expr = throws (fx "gen-lock-no-module"); }

    # ── the D2 tie was not displaced by the schema work ───────────────
    { name = "stale go_sum_sha256 still throws (D2 intact)"; expr = throws (fx "gen-lock-stale"); }

    # ── nothing-to-verify is not verified ─────────────────────────────
    { name = "absent Go.gen.lock -> null (ladder falls through)"; expr = reader.reconstruct (fx "gen-lock-absent") == null; }

    # ── the schema itself ─────────────────────────────────────────────
    { name = "per_package is declared REQUIRED"; expr = (import ../delta-schema.nix { inherit lib; }).topLevel.per_package.required; }
    { name = "go_sum_sha256 is declared REQUIRED"; expr = (import ../delta-schema.nix { inherit lib; }).topLevel.go_sum_sha256.required; }
    { name = "vendor_hash is NOT required (absent is meaningful)"; expr = !(import ../delta-schema.nix { inherit lib; }).perPackage.vendor_hash.required; }
    { name = "every declared field states required or a default"; expr =
        let s = import ../delta-schema.nix { inherit lib; };
            all = builtins.attrValues s.topLevel ++ builtins.attrValues s.perPackage;
        in builtins.all (f: f.required || (f ? default)) all; }
    { name = "every declared field carries a note"; expr =
        let s = import ../delta-schema.nix { inherit lib; };
            all = builtins.attrValues s.topLevel ++ builtins.attrValues s.perPackage;
        in builtins.all (f: f ? note) all; }
  ];

  failures = builtins.filter (c: !c.expr) cases;
  total = builtins.length cases;
in
if failures != [ ] then
  throw ''
    lockfile-delta-schema-test: ${toString (builtins.length failures)} of ${toString total} FAILED
    ${builtins.concatStringsSep "\n" (map (f: "  - ${f.name}") failures)}
  ''
else { inherit total; passed = total; }
