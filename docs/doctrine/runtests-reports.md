## ★★ `runTests` REPORTS, it does not throw — the eval-suite catalog exists because of that

substrate's own eval tests come in three families, and the third one
cannot be gated the way the first two are.

| family | shape | run by |
|---|---|---|
| **A** self-evaluating | `throw`s on the first failure | `nix-instantiate --eval --strict <file>` |
| **B** `{ lib }` + `asCheck pkgs` | a `checks.<system>.*` derivation | `nix build .#checks.<system>.<name>` |
| **C** report-returning | evaluates to a VALUE describing the run | `lib/util/eval-suites.nix` |

**Family C's trap, stated plainly:** `util/test-helpers.nix`'s `runTests`
returns `{ total; passCount; failCount; allPassed; failures; }`. It does
**not** throw when a test fails — it records the failure and carries on.
So `nix-instantiate --eval --strict lib/util/tests.nix` **exits 0 whether
every assertion passes or every assertion fails**; it detects only an
evaluation error. Measured 2026-07-28 on a deliberately-broken copy of
that exact file: the family-A command exited 0 while the catalog gate
exited 1 on the same bytes. Copying the family-A steps for these suites
would have added four jobs that run 830 assertions and gate on none —
a discarded verdict, not a gate (★★ UNREPRESENTABILITY tier ⊥).

**What is wired.** 22 suites / **830 assertions**, none of which ran in
any job on any trigger before 2026-07-28: `lib/types` (144),
`lib/infra` (298), `lib/build/shared` + `nixos` + `rust` + `go` (244),
`lib/kube` (57), `lib/hm` (65), `lib/util` (22). Catalog and gate live in
`lib/util/eval-suites.nix`; the steps are in `nix-tests.yml`'s four
`*-suites` jobs, one step per suite so a failure names the suite.

Two properties beyond "it runs":

- **An assertion FLOOR per suite.** Each entry records the count measured
  when it was wired, and the gate fails on `total < min` as well as on a
  failing assertion — so a suite that silently *shrinks* (a `map` over a
  list that became empty, a block dropped in a refactor) turns red instead
  of reporting a smaller green.
- **A catalog-covers-workflow forcing-function.** `only = "coverage"`
  reads `nix-tests.yml` and fails when a catalogued suite has no step.
  "In the catalog, running nowhere" is the exact defect the catalog
  repairs, so it is made unable to recur silently. Same trick as
  `rust-shape`'s `known-set-covers-every-flake-call-site`, which reads
  `flake.nix`.

**NOT VACUOUS: verified red against deliberately-broken inputs, not
merely observed green.** A flipped assertion in `lib/util/tests.nix`
(1 of 22 failed, exit 1); six tests deleted from `lib/types/tests.nix`
(`SHRANK 73 < 79`, exit 1); an unknown suite name (exit 1); and the
coverage check itself was red on all 22 entries before the steps existed
and green after. All restored afterwards.

**One suite is deliberately excluded** — see `pending-vacuous-guard:
infra/wasm-compat` at the top of substrate's `CLAUDE.md`. It is green, and that is the
problem.

**A vacuity found INSIDE a newly-running suite, and fixed.**
`lib/types/property-tests.nix`'s `testInformationFlow` runs
`checkInformationFlow` over seven `sampleSpecs` that each carry
`secrets = []` and `env = {}` — so `leaked == []` holds by construction
and none of those seven can detect a leak. Its one "positive control"
re-implemented the leak filter inline and asserted on its own copy, so it
passed **without ever calling the function under test**: blinding
`checkInformationFlow` to always report no-leak left all 8 tests green.
The control now calls the real function on a genuinely leaking spec and
asserts the rejection — the same blinding now fails it (1 of 8, exit 1).
The seven remain structurally vacuous and are documented as such in the
file; they prove the checker *evaluates* per archetype, not that it
*detects*. Do not count them as leak coverage.

