## ★★ `nix flake check` BUILDS ONLY `checks.<system>.*` — a builder that emits none hands out a green lie

**The single most load-bearing fact about this repo's verification
surface.** `nix flake check` *evaluates* `packages` / `devShells` / `apps`
— it literally prints `(build skipped)` — and **builds** only
`checks.<system>.*`. So a flake declaring zero checks makes that command a
pure *evaluation* check: it passes over a crate that was never compiled,
let alone tested.

**Measured, not inferred (2026-07-27).** A consumer-shaped fixture over
`lib/build/rust/library.nix` at substrate `3f4dfb9` reported
`checks.<system>` = `[]` and `nix flake check` **exit 0 with a
deliberately failing test in the crate**. On `forge`, `nix flake check
--impure` returned exit 0 in 8.66 s with `compile_error!` inside
`#[cfg(test)] mod tests`, and again with literal non-Rust garbage in a
function body. `cargo-ci.yml`'s header meanwhile claimed it ran
"`cargo test` via the substrate baseline" — **there was no such
baseline**, and at least `forge`, `iac-forge`, `engenho` plus nine
`tool-release` consumers were relying on the claim.

### What every Rust builder now emits

| check | emitted | proves |
|---|---|---|
| `checks.build` | always, both build paths | the SHIPPED artifact compiles (same derivation as `packages.default`, so it is paid for once) |
| `checks.tests` | `library.nix` always; `tool-release.nix` only on `buildMode = "cargo-nix"` | the crate's tests actually RUN (crate2nix `runTests` → `crateWithTest`) — **emitted by the builders, reaching zero consumers; see below** |

Policy lives in **`lib/build/rust/test-check.nix`** — one surface, so both
builders emit the same shape. Opting out is typed (`tests = { enable =
false; reason = "…"; }`); a bare boolean is refused, same grammar as
`lib/infra/mutating-verbs.nix`.

### `checks.tests` reaches ZERO consumers — the row above is about the builders, not the fleet

Two independent reasons, both measured 2026-07-28 over a local fleet
checkout containing vendored mirrors (lower bounds, not org-wide
percentages). Either one alone would be sufficient; both hold.

1. **`substrate.rust.library` never reaches `library.nix`.** All five
   `substrate.rust.<shape>` entry points are `callShape` over one builder
   (`flake.nix:496-506` → `mk-rust-tool-flake.nix` → `tool-release.nix`);
   `shape` validates and records, it does not select a builder.
   `lib/build/rust/shape.nix` states this and prices the routing fix — read
   it before assuming the shape name means anything about the build path.
   So the **136** `flake.nix` files naming `substrate.rust.library` — out of
   **270** naming any `substrate.rust.*`, or **290** counting direct
   `mkRustToolFlake` — all land on the `tool-release` path, where the row's
   other condition applies: **zero of them set `buildMode = "cargo-nix"`**.

2. **The 16 repos that DO reach `library.nix` discard its `checks`.**
   Pattern-3 standalone import is a live route the shape-routing argument
   misses entirely: 15 repos import `lib/rust-library.nix` (the two-line
   shim to `build/rust/library.nix`) and `pleme-app-core` imports
   `lib/build/rust/library.nix` directly. Every one of the 16 then writes
   `inherit (lib) packages devShells apps;` — the string `checks` does not
   appear **anywhere** in any of their `flake.nix` files. The builder emits
   the check; the consumer flake never re-exports it; `nix flake check`
   there builds nothing. That is the same green lie this whole section
   exists to close, one layer further out, and it is not fixed by anything
   in `test-check.nix`.

### The named gap — do not paper over it

`checks.tests` is **absent on the default `lockfile` build path**, and the
absence is deliberate. gen's build spec carries **no dev-dependency
graph** (a crate record has `runtime_dependencies` + `build_dependencies`
only, and `spec-invariants.nix` *rejects* a `kind = "dev"` edge in
either), and nixpkgs' bare `buildRustCrate` has no `runTests` argument at
all — only `buildTests`, which compiles test targets without dev-dep
externs and never runs them. **12 of 13 surveyed consumers declare
`[dev-dependencies]`**, so a test target simply cannot be compiled there
today. Emitting an always-green `checks.tests` that ran nothing would be
strictly worse than emitting none — a guard over an empty subject set
reports a tier it does not have (★★ UNREPRESENTABILITY §II.3, tier ⊥).

**The load-bearing fix is upstream in gen-cargo** (emit `dev_dependencies`
edges into the spec, per the ★★ GEN TYPED-SPEC CONTRACT in
`lib/build/rust/spec-invariants.nix` and gen's `docs/CARGO-LOCK-DELTA-CONTRACT.md`) plus a
substrate-side test-runner derivation. A Nix-side re-derivation of cargo's
dev-dep feature resolution would be a second, untested copy of the
resolver. Tracked as **`pending-rust-test-check: lockfile-dev-deps`**.
Until it lands, the real-test leg for those consumers is the `cargo-test`
job in `cargo-ci.yml` (`cargo test` inside the flake's devShell on the CI
runner), which retires into `checks.tests` when the pending item closes.

**Opt-in runner, available now (2026-09-19): `tests.cargo = { … }`.**
`lib/build/rust/workspace-tests.nix` runs `cargo test --frozen` over a vendor
dir built from the workspace's own `Cargo.lock` — cargo, the real resolver,
so dev-deps, test-profile features, integration tests, doctests and the
workspace `[profile.*]` behave as on a laptop. lockfile-builder exposes it as
`mkProject { … }.runTests` (plus the spec-free `mkWorkspaceTests`), and any
`substrate.rust.<shape>` emits it as `checks.tests` when the consumer writes
`tests.cargo.runs = [ { args = [ "--workspace" … ]; } … ];`. **Opt-in only**:
it compiles the whole graph again, uncached per crate, and a consumer that
does not ask gets a byte-identical check set (pinned by
`checks.rust-workspace-tests`). **Tier-honest:** it proves the tests pass under
cargo; it proves nothing about the buildRustCrate artifact, so it narrows
`pending-rust-test-check` rather than closing it.

**That leg carries three repos — `engenho`, `forge`, `iac-forge` — against
the 270 `flake.nix` files naming a `substrate.rust.*` builder** (290 counting
direct `mkRustToolFlake`). `nix-devshell-cargo-test.yml`, which
`cargo-ci.yml` composes, has one further direct caller, `pangea-operator`.
So for the great majority of consumers there is no real-test leg at all
today: not `checks.tests`, and not this job either.

**And on 2026-07-27 it ran the tests of ZERO of those three.** State the
denominator here too, because "carries three repos" is a reach, not a
coverage. Measured 2026-07-28, `devShells.<sys>.default.name` per caller:
`forge` → `devenv-shell` (its own `devenv.flakeModule`, the only pleme-io
repo importing it), `engenho` → `devenv-shell`, `iac-forge` → `devenv-shell`
(both stale substrate pins, pre-`e232917`). `nix develop` cannot enter a
devenv shell non-interactively, so the leg that was added to make the test
claim true broke all three consumers and verified none. `checks.tests` was
vacuous by **absence**; this was vacuous by **breakage**.

The general lesson, which outlives the devenv specifics: **a job added to a
shared `@main` reusable asserts a capability of every consumer.** This one
asserted "`.#default` is enterable non-interactively" — never guaranteed by
any substrate builder, and true for none of them. Two things now hold it:

- **The preflight is wired.** `lib/util/devshell-preflight.nix` shipped
  tested-but-unwired (its own header: "No workflow imports
  `devshellPreflightPath` — zero hits"), which is the *unreached* subclass of
  tier ⊥ — a guard passing its unit tests against zero real subjects.
  `nix-devshell-cargo-test.yml` now invokes it, so a non-enterable devShell
  yields an actionable verdict naming the fix instead of a raw nix trace.
- **The reusable has an in-repo caller.** `devshell-cargo-test-selftest.yml`
  + `devShells.<sys>.selftest-cargo` + a dependency-free fixture crate. Until
  it existed, the first execution of a new leg *anywhere* was in a downstream
  repo's CI — a shared reusable with no caller here cannot go red before its
  blast radius does.

`--impure` is **not** the fix, measured rather than assumed: `nix develop
--impure .#default` on forge does not succeed, it fails *differently*
(`error: To use 'languages.rust.channel', Add … inputs.rust-overlay.url`).
Hence `devshell-args` is a distinct input and `flake-args` is deliberately
not forwarded into `nix develop`. Receipts: run `30411786849` — `1 passed`
through the shipped path after `preflight OK`, and the deliberate break
refusing non-zero.

Count uncommented `uses:` lines, not mentions. A plain grep for the string
`cargo-ci.yml` returns 8 repos: 3 callers, substrate itself (which defines
it), and **4 — `pangea-forge`, `ruby-synthesizer`, `yaml-synthesizer`,
`shikumi` — that name it only in comments explaining why they deliberately
do NOT adopt the shim**, each with its own measured blockers worth reading
before "simplifying" any of them back.

Counted 2026-07-28 over a local fleet checkout containing vendored mirrors:
lower bounds, not org-wide percentages. And a caller is not a run — **554 of
716 workflow-bearing pleme-io repos have Actions disabled at the repo
level**, so 3 callers is itself an upper bound on how many execute this leg.

### `cargo-ci.yml` — two jobs, and the split is the point

`flake-check` runs `nix flake check`, then a gate
(`lib/util/flake-checks-gate.nix`) that **fails loudly when the flake
exposes zero checks** and otherwise **prints the check names it built**, so
a green states what it verified instead of being opaque. `cargo-test`
composes the existing `nix-devshell-cargo-test.yml` (Operating Principle
#1 — extend the near-miss) and defaults to `--all-features`: on forge,
plain `--all-targets` ran 2,663 tests while `--all-features` ran 2,950
— an `attestation` feature gated 263 of them, and a gate that silently
skips a tenth of the suite is a fresh subject-set vacuity inside the very
thing meant to close one.

Both new surfaces are covered by substrate's own gate:
`checks.<system>.rust-test-check` and `checks.<system>.flake-checks-gate`,
each **verified red against a deliberately-broken input before landing**
(removing the availability gate throws on the poisoned `mkTests`;
dropping the reason requirement fails 3 tests; making the gate return a
string instead of throwing fails 4).

**Separately documented under-scope, left alone on purpose:**
`tool-release.nix`'s `gen confirm . --if-present` tolerates `rc=1` for the
~10 consumers with no committed delta — an honest, documented gap in a
different gate, not this one.

