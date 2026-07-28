# shape.nix — the typed meaning of `substrate.rust.<shape>`.
#
# ── THE DEFECT THIS CLOSES ──────────────────────────────────────────────
#
# `mk-rust-tool-flake.nix` declared `shape ? "tool"` in its argument set and
# then NEVER READ IT AGAIN. Five entry points — `substrate.rust.{tool,
# workspace,library,service,binary}` — are `callShape "<name>"` over that one
# builder (flake.nix), so every one of them resolved to byte-identical
# behaviour. `substrate.rust.library` WAS `substrate.rust.tool`.
#
# A parameter that is accepted and ignored is its own defect class: it reads
# as a promise at every call site, it type-checks nothing, and a typo in it
# (`shape = "libary"`) was silently swallowed. Measured consumers, `rg` across
# the fleet on 2026-07-28 (read-only):
#
#     substrate.rust.library      142 repos
#     substrate.rust.tool          91
#     substrate.rust.workspace     30
#     substrate.rust.service       17
#     substrate.rust.binary         0
#     mkRustToolFlake (direct)     21
#     ------------------------------------
#     total                       280 consumers, one builder
#
# ── WHY THIS FILE VALIDATES + RECORDS RATHER THAN ROUTES ────────────────
#
# The obvious "honour it" reading is: `shape = "library"` should dispatch to
# `lib/build/rust/library.nix` (which really does emit `checks.tests`). That
# was priced against the fleet and REFUSED, with numbers:
#
#   * `library.nix` builds through crate2nix and takes `cargoNix ? src +
#     "/Cargo.nix"`. 132 of the 142 `rust.library` consumers have NO
#     committed `Cargo.nix`, so they would fall to
#     `crate2nixTools.generatedCargoNix` — eval-time IFD running cargo WITH
#     NETWORK on every `nix build`, `nix flake check` and `nix develop`.
#     That is precisely the cost `mk-rust-tool-flake.nix`'s own header says
#     the gen delta exists to eliminate. Routing on `shape` would re-introduce
#     it for 132 repos in one commit.
#
#   * The remaining 10 would silently change which builder produces
#     `packages.default` — a different derivation for the same flake, with no
#     consumer-side diff to review.
#
#   * And it would not even deliver the thing it appears to promise. Routing
#     `library` to `library.nix` buys `checks.tests` only where a crate2nix
#     graph exists; for the 132 it buys an IFD and still no tests, because
#     the blocker is upstream and already tracked:
#     `pending-rust-test-check: lockfile-dev-deps`.
#
# So `shape` does not select a builder today, and this file says so out loud
# instead of letting the argument keep implying otherwise. What it DOES do,
# starting now, is real and observable:
#
#   1. CLOSED SET. An unknown shape throws at eval instead of being
#      discarded. `shape = "libary"` was accepted before this file existed.
#   2. IT TRAVELS. The resolved shape is threaded into the builder's `who`
#      identity, so every diagnostic the test-check surface emits names the
#      shape the consumer actually asked for rather than a generic
#      "rust-release".
#   3. IT EXPLAINS ITSELF. `explain` states, per shape, which builder ran and
#      what that means for the verification surface — the same
#      derive-the-verdict-and-carry-the-witness discipline
#      `flake-checks-gate.nix` applies to the check set
#      (UNREPRESENTABILITY §II.4).
#
# ── THE ROUTING DESTINATION, NAMED (Operating Principle #0) ─────────────
#
# The destination is that `shape` selects a verification surface per shape,
# with `library` running the crate's tests. It is blocked behind exactly one
# upstream item, not behind this file: gen-cargo emitting `dev_dependencies`
# edges into `Cargo.build-spec.json` (★★ GEN TYPED-SPEC CONTRACT). Once the
# lockfile path can compile a test target, `checks.tests` becomes available
# on the path all 280 consumers already use, and `shape` can select surface
# WITHOUT anybody moving to crate2nix. Fixing it by routing today would be
# the path-of-least-resistance answer to the wrong question.
#
# ── TIER, AND THE SUBJECT SET, MEASURED (do not round this up) ──────────
#
# This is PARSE-TIME REJECTION of an unknown shape (`known` is a closed list
# checked at eval). It is NOT unrepresentability — nothing in the type system
# stops a caller passing a string; the throw is what stops it.
#
# And the throw's LIVE SUBJECT SET IS EMPTY TODAY. Two measured facts, both
# verified 2026-07-28:
#
#   1. flake.nix's `callShape` is `args // { shape = shape; }` — the RIGHT
#      operand wins, so the hardcoded literal OVERRIDES anything a consumer
#      passes. `substrate.rust.library { shape = "libary"; }` evaluates to
#      `shape = "library"`; `normalize` never sees the typo. For the 271
#      consumers on the five `substrate.rust.<shape>` entry points, the only
#      values that can reach `normalize` are the five valid literals.
#   2. Of the 21 direct `mkRustToolFlake` callers — the only route that can
#      reach `normalize` with an arbitrary value — ZERO pass `shape` at all
#      (`grep 'shape *= *"'` over every consumer flake.nix: no hits).
#
# So `unknown-shape-throws` guards a real mechanism over a currently-empty
# population. It is a gate armed for a future caller, NOT evidence that any
# shipped consumer is protected — claiming the latter would be exactly the
# tier-⊥ round-up (a guard over zero subjects reporting a tier it lacks) this
# file otherwise exists to avoid. It is still worth landing: it costs one
# eval-time check, and it is what makes point 2 above STAY true.
#
# Reachability is also LAZY: `resolvedShape` is referenced at exactly one site
# downstream (tool-release.nix `who = resolvedShape.who`, inside `checks`), so
# the validation is forced by `nix flake check`, not by `nix build`.
{ lib }:

let
  # Every shape resolves to this builder today. One name, one place, so the
  # claim cannot drift between the doc above and the code below.
  currentBuilder = "tool-release";
in
rec {
  # The closed set. Mirrors flake.nix's `callShape` call sites exactly; a
  # shape added there without being added here is a loud throw, not a silent
  # pass-through.
  known = [ "tool" "workspace" "library" "service" "binary" ];

  # Validate a caller's `shape`, returning it unchanged or throwing.
  # `who` is the builder/consumer name, used only in the message.
  normalize = who: shape:
    if !(builtins.isString shape)
    then throw ''
      substrate/rust: ${who} — `shape` must be a string, got
      ${builtins.typeOf shape}. Known shapes: ${builtins.concatStringsSep ", " known}.
    ''
    else if !(builtins.elem shape known)
    then throw ''
      substrate/rust: ${who} — unknown `shape` "${shape}".

      Known shapes: ${builtins.concatStringsSep ", " known}.

      Until 2026-07-28 this argument was accepted and then never read, so a
      typo here silently built the default shape instead of failing. It is a
      closed set now. If you meant to add a new shape, add it to
      `known` in lib/build/rust/shape.nix AND to the `callShape` call sites
      in substrate's flake.nix — the two must not drift.
    ''
    else shape;

  # The typed record. `selectsBuilder = false` is the load-bearing field:
  # it is the machine-readable form of "this argument does not route", so a
  # future reader does not have to re-derive that from the source.
  resolve = who: shape:
    let s = normalize who shape;
    in {
      requested = s;
      builder = currentBuilder;
      selectsBuilder = false;
      # Identity handed to test-check.nix, so its diagnostics name the shape.
      who = "rust-release[shape=${s}]/${who}";
    };

  # Human-readable statement of what a shape yielded and what that means for
  # the verification surface. `mode` is tool-release.nix's `effectiveMode`
  # ("lockfile" | "cargo-nix").
  explain = { who, shape, mode }:
    let r = resolve who shape;
    in
      "shape=${r.requested} built by ${r.builder} (shape does not select a "
      + "builder — see lib/build/rust/shape.nix) on the ${mode} build path; "
      + (if mode == "cargo-nix"
         then "`checks.tests` emitted."
         else "`checks.tests` absent — the lockfile path carries no "
              + "dev-dependency graph (pending-rust-test-check: "
              + "lockfile-dev-deps). The real test leg for this consumer is "
              + "the `cargo-test` job in substrate's cargo-ci.yml.");
}
