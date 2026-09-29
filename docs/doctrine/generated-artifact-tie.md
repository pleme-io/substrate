## ★★ A GENERATED ARTIFACT IS TIED TO ITS SOURCE, or it ships a lie

Fourth face of the same defect, and the one that reaches outside this repo:
**a generated artifact that outlives its source fix, with nothing tying the
two.** Four independent instances on 2026-08-01 — `aresta`'s `Cargo.nix`,
`pangea-operator`'s `Cargo.gen.lock`, `pangea-operator`'s CRDs, `blue`'s
`gen-confirm --if-present`. Exactly one of the four HAD a tie
(`Cargo.gen.lock`'s D2 gate) and that tie is what caught its instance.

**One tie shape, one file.** `lib/build/shared/freshness-tie.nix`. It was
written inline in `build/rust/lockfile-delta.nix`, copied inline into
`build/go/lockfile-delta.nix`, and the two wordings had already drifted;
`cargo-nix-tie.nix` is the third use, so it is the extraction. `held`
**never returns false** — it returns `true` or throws, because a tie that
reports a boolean is a verdict the caller can drop on the floor, which is
what `--if-present` did in instance four.

### The `Cargo.nix` tie — `lib/build/rust/cargo-nix-tie.nix`

`crate2nix records no input hash`, so D2's exact shape (recorded hash vs
`hashFile` of the current input) is unavailable — verified across all 136
committed `Cargo.nix` files in the checkout, crate2nix 0.15.0 / 0.14.1, no
hash field in any. **A sidecar stamp was rejected rather than invented:** a
stamp binds only repos that opt in, so `aresta` — the repo that motivated
this — would have been the unprotected case, and the `--if-present` branch
tolerating its absence is instance four, not a fix for instance one.

So the tie is DERIVED: the `name-version` set crate2nix emitted must equal
the package set of the `Cargo.lock` it was generated from. Equality is the
invariant and not a heuristic because the **29 repos whose `Cargo.nix` is
current match theirs EXACTLY, both directions**.

**Where it lives: at the import, all nine of them.** Every site inside
substrate that imports a `Cargo.nix` — `library.nix`,
`library-workspace.nix`, `tool-release.nix`, `tool-image.nix`,
`crate2nix-builders.nix` (×2), `wasm/build.nix`, `typescript/tool.nix`,
`service/platform-service.nix` — now goes through `importFresh`, so the tie
cannot be skipped by adding a tenth site. `python3` over the tree finds
exactly one remaining `import cargoNix`, inside `importFresh` itself.

**REACHED, measured, and RED on real consumers — not a tenth guard over an
empty set.** `terraform-forge` and `samba` are the two live `library.nix`
(pattern-3) consumers that commit a `Cargo.nix`, and both disagree with
their own lock. Baseline `b7b6c0e` evaluates
`terraform-forge#packages.aarch64-darwin.default.drvPath` to
`c22af0m1…-rust_terraform-forge-0.1.4.drv`; with the tie it exits 1 naming
the two crates `Cargo.lock` added that the artifact never saw. `samba` goes
red on 13 crates.

**ADDITIVE — three drvPath comparisons, baseline vs tie:**

| consumer | shape | before | after |
|---|---|---|---|
| `aldrava` | `substrate.rust.tool`, no `Cargo.nix` at all | `3j9mbaml…-rust_aldrava-0.1.2.drv` | identical |
| `hashfix` | `substrate.rust.tool`, **stale `Cargo.nix` that nothing imports** | `y1yma46r…-rust_hashfix-0.1.2.drv` | identical |
| `iac-forge` | `library.nix` pattern-3, no `Cargo.nix` | same failing IFD drv (`40xd8i7q…-takumi-0.1.0.drv`, pre-existing) | identical |

The `hashfix` row is the load-bearing one: it proves the tie did **not**
redden the 107 repos whose stale `Cargo.nix` is never read.

**NOT VACUOUS — six blindings, each reddening exactly its own assertions**
(20-assertion suite, `lib/build/rust/tests/cargo-nix-tie-test.nix`, floor 20):
`status.kind` hard-wired to `"fresh"` → 3 red (the RED-RUN cluster);
`assertFresh` made a no-op → 2 red (the tie computed and discarded);
`absent` rounded up to `"fresh"` → 1 red; the parser-gap guard removed → 1
red; `held` returning `false` instead of throwing → 3 red; the file-type
guard reverted to bare `pathExists` → exit 1 with `read of 96 bytes: Is a
directory` (an eval error rather than an assertion failure — still red,
said plainly rather than counted as a clean assertion). All restored,
20/20 green, and the whole 24-suite catalog re-run green.

**One of those six is a defect this work introduced and then caught.** The
first cut handed the tie `generatedCargoNix` — which on the fallback branch
is crate2nix's DERIVATION, a store *directory* holding `default.nix`. Three
builders take that branch, and every repo whose IFD generation succeeded
would have hit `readFile` on a directory. It surfaced only because the
consumer tested first (`iac-forge`) had a pre-existing IFD build failure
that masked it. Both halves are fixed: the callers name the committed path,
**and** `status` refuses a non-regular file rather than trusting them — a
guard whose correctness depends on every call site getting it right is the
call sites' guard, not the primitive's.

The `absent` verdict is a distinct third state on purpose. A repo with no
`Cargo.nix` reports **"nothing to verify"**, never `"fresh"` — the empty
subject set must not be readable as a pass.

### The named limits — do not round these up

- **TIER: eval-rejected** where substrate does the import. A Nix `throw`,
  not a compile error; stronger than a CI gate (which is vacuous wherever
  Actions are disabled — 554 of 716 workflow-bearing repos).
- **A consumer flake that writes `import ./Cargo.nix` itself is outside
  substrate's reach** and stays **only-mitigated** until it adopts
  `importFresh`. Four do, counted 2026-08-01: `aresta`,
  `pangea-operator/pangea-web`, `dev-tools/nix-cli`, `dev-tools/rust-init`.
  The first two are stale today; `aresta`'s is the shipped FIPS sidecar.
  One-line conversion, in the file's header.
- **The tie covers GRAPH drift, not FEATURE drift.** A `Cargo.toml` edit
  that does not move `Cargo.lock` changes per-crate `features` inside
  `Cargo.nix` and no `name-version` pair. Closing it means re-deriving
  cargo's feature resolution in Nix — a second, untested copy of the
  resolver. `pending-cargo-nix-tie: feature-resolution`.
- **12 repos commit a `Cargo.nix` with no sibling `Cargo.lock`** and are
  untieable by construction; they report `absent`.

### The measurement that says `Cargo.nix` should be RETIRED, not maintained

**107 of the 136** committed `Cargo.nix` files with a sibling `Cargo.lock`
disagree with that lock (measured 2026-08-01 over a local checkout
containing vendored mirrors — a lower bound, not an org-wide percentage;
cross-checked by two independent implementations, one Nix and one Python,
which agree on the 29/107 split). Nobody regenerates them because
`useLockfileBuilder` defaults to `true` and **zero repos in the checkout set
it to `false`**: for the great majority the file is not read at all. The
correct fix for an unread `Cargo.nix` is `git rm`, not `crate2nix generate`,
and the throw says so. The tie is what makes that backlog visible without
reddening the repos that merely carry a dead file.

