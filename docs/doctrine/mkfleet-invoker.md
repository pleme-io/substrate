## ★★ `mkFleet` now ships the INVOKER, not just the check

Third face of the defect that [`flake-check-builds-only-checks.md`](./flake-check-builds-only-checks.md)
and [`runtests-reports.md`](./runtests-reports.md) chase, one layer out.
`kata.mkFleet` returned **`checksFor` — a declaration — and nothing that
runs it.** Nothing in a fleet workflow does: `nixos-rebuild` /
`darwin-rebuild` never look at `checks`, and a fleet repo is private by
default, so no CI runs `nix flake check` either. So every consumer had to
re-derive an invoker by hand or go without.

**Three consumers, counted 2026-07-28, all the same shape:**

| consumer | had | state |
|---|---|---|
| `templates/fleet` (this repo, PUBLIC) | `checks = … fleet.checksFor …`, no invoker | the template `nix flake init` actually reaches |
| `pleme-io/nix` (the live fleet) | `parts/fleet.nix:68` calls `mkFleet`; `:111` ships `hostMatrix.nixosConfigurations`; `:172` declares `checks`; **no `.github/workflows` at all** | `parts/kata.nix:387` self-describes as `TIER: eval-rejected (a nix flake check failure)` — a **round-up**, because nothing ever ran that command |
| `pleme-io/nix-template` | ~25 hand-rolled lines of gate in its own `flake.nix` (`2044c33`) | the one that got it right; this lift generalizes it |

**What landed.** The verdict now has two faces, built from ONE suite.
`iroha.mkEvalChecks` gained **`gate`** — the same verdict as a pure
EVAL-time value (`asCheck` is a derivation and decides nothing until
something *builds* it). `mkFleet` re-exports it plus `gated` (`v ->
builtins.seq gate v`) and **`shipping`** — `{ nixosConfigurations,
darwinConfigurations, deployRs, colmena, registry, byTag }`, pre-gated.
Selecting a gated output on a red fleet throws, naming every failing case,
**before a byte is built — no CI, no builder, no matching system.**

**The asymmetry is the point, not an omission.** `report` / `invariants` /
`checksFor` are deliberately NOT gated and are absent from `shipping`: a
fleet whose gate is red must stay inspectable, or the gate is unusable
rather than merely strict. Measured on one deliberately-broken template
fixture — all four shipping outputs exit 1 with
`FAIL test:fleet:deployed-nodes-have-domains … got: ["alpha"]`, while
`fleetReport` / `fleetSshAliases` / `checks` exit 0 on the same bytes, and
`fleetReport` shows the `fqdn: null` that explains the red.

**`n == 0` is the load-bearing half.** `lib.runTests { }` returns `[ ]`, so
an empty suite reports `passed = true` / `"0/0 passed"` — the
strongest-looking evidence available, proving nothing (★★ UNREPRESENTABILITY
tier ⊥, "vacuous"). `gate` refuses it. Living in `iroha` rather than `kata`
is deliberate: a kata fleet is **structurally** non-empty (four
`crossInvariants` are unconditional — measured 19 assertions on the
template), so at the kata layer alone the refusal would guard an
unreachable state, while at the harness layer it covers every
`mkEvalChecks` caller, including a suite that shrank to empty through a
filter.

**ADDITIVE — no existing consumer's behaviour changes.** Top-level
`fleet.nixosConfigurations` & co. are returned exactly as before, ungated;
`checksFor` returns the same derivation. Opting in means taking the output
from `shipping` instead. Gating by default would have thrown for any fleet
currently red — including the live one, blind, from here.

**Adoption, one line each:** `templates/fleet` — done, `inherit
(fleet.shipping) …`. `pleme-io/nix` — `parts/fleet.nix:111`, take
`fleet.shipping.nixosConfigurations.${n}` instead of
`fleet.hostMatrix.…` (leave `kataConfigurations` at `:107` ungated; it is
the drvPath-parity diagnostic). `nix-template` — replace its hand-rolled
`suite`/`gate`/`gated` block with `fleet.shipping`.

**TIER: eval-rejected.** Stronger than a CI gate (only-mitigated, and
vacuous wherever Actions never run — which is exactly why this must not
depend on CI); weaker than truly-unrepresentable, because a Nix `throw` is
not a compile error. Do not round it up.

**NOT VACUOUS: verified red against deliberately-broken inputs.** Deleting
the `n == 0` arm reddens exactly `iroha/checks:gate-refuses-an-EMPTY-suite`
(768/769) and `kata/fleet:gate-refuses-an-EMPTY-invariant-suite` (194/195);
making `gated` a no-op reddens exactly
`kata/fleet:gate-throws-every-shipping-output-on-a-RED-fleet` (194/195).
Both restored green (769/769, 195/195). Suites run in CI already —
`nix-tests.yml`'s `flake-checks` job builds `checks.<sys>.iroha` and
`.kata`, and its path filter already watches `lib/iroha/**` + `lib/kata/**`.

