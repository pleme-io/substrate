# devshell-preflight.nix — "can the `cargo test` job actually ENTER this
# flake's devShell?" as a typed verdict rather than an opaque `nix develop`
# crash.
#
# ── WHY ─────────────────────────────────────────────────────────────────
#
# `cargo-ci.yml`'s `cargo-test` job runs `nix develop ".#<shell>" -c cargo
# test`. That is the ONLY leg that executes a substrate Rust consumer's tests
# today — measured 2026-07-28: ZERO of the 280 `substrate.rust.*` consumers
# set `buildMode = "cargo-nix"`, and `checks.tests` is emitted on that path
# only, so `nix flake check` compiles every consumer's crate but runs nobody's
# tests. The devShell leg is load-bearing, and its failure mode was raw.
#
# When the devShell cannot be entered, `nix develop` fails with a nix
# evaluation trace before cargo is ever invoked. The job goes red for a
# reason that has nothing to do with the tests, and the trace does not say
# what to do about it. A red gate nobody can act on gets muted, which is
# strictly worse than the vacuous gate it replaced — the "abandoned red"
# subclass (iac-forge red 54 days, ruby-synthesizer 67).
#
# ── THE SKEW THIS EXISTS TO NAME, MEASURED ──────────────────────────────
#
# The failure has a specific and very common cause, and it is a VERSION SKEW,
# not a repo defect. Consumers call the workflow at `@main` — it updates the
# instant substrate does — while their `flake.lock` pins whatever substrate
# rev they last locked. So a new workflow leg runs against an OLD builder.
#
# Worked case (shikumi, read-only, 2026-07-28), every number probed:
#
#   shikumi flake.lock pins substrate fcd3514  (2026-06-07)
#   substrate e232917 "devshell(rust-gen): non-interactive-safe shell —
#     devenv=null -> plain fenix mkShell"       (2026-07-17, 40 days later)
#
#   nix eval .#devShells.<sys>.default.name
#     @ fcd3514, pure     -> THROWS "devenv was not able to determine the
#                            current directory"
#     @ fcd3514, --impure -> "devenv-shell"
#     @ substrate HEAD    -> "nix-shell"        (both aarch64-darwin and
#                            x86_64-linux, the CI platform)
#
# So the devShell shape defect is ALREADY FIXED in substrate: since e232917
# `tool-release.nix` passes `devenv = null` and `mkRustDevShell` takes its
# plain `pkgs.mkShell` + fenix branch, at which point neither reported error
# is constructible — there is no devenv to demand a PWD, and no
# `languages.rust.channel` to demand a `rust-overlay` input. What remains is
# purely that consumers have not re-locked.
#
# That is why this file classifies rather than repairs. The repair is one
# command in the consumer's repo; the job's duty is to NAME it.
#
# ── WHY NOT JUST FALL BACK TO A PLAIN TOOLCHAIN ─────────────────────────
#
# Rejected, and the rejection is `nix-devshell-cargo-test.yml`'s own founding
# rationale: that workflow exists to REPLACE "a `dtolnay/rust-toolchain@stable`
# + bare `cargo test` job that passes today only because `ubuntu-latest`'s own
# ambient environment happens to satisfy the requirement, with no pin and no
# guarantee it keeps doing so." Falling back to that on failure would restore
# the unpinned accident silently, and a crate whose tests need the devShell's
# hermetic inputs would then go green on the accident. A green whose subject
# is not the thing it claims to verify is a fresh vacuous guard
# (UNREPRESENTABILITY §II.3, tier ⊥) inside the gate meant to close one.
#
# ── WHY IT IS A NIX FILE AND NOT SHELL IN THE WORKFLOW ──────────────────
#
# Same reason `flake-checks-gate.nix` is: policy in a YAML block scalar inside
# a shell-quoted argument is three layers of quoting deep, and the first
# version of that gate silently lost its string delimiters — a gate that fails
# to PARSE never runs. In a real file it is parseable, reviewable, and covered
# by substrate's own `checks.<system>.devshell-preflight`.
#
# ── CONSUMPTION ────────────────────────────────────────────────────────
#
#   nix eval --impure --raw --expr '
#     import (builtins.getFlake "github:pleme-io/substrate").devshellPreflightPath {
#       system   = builtins.currentSystem;
#       devshell = "default";
#       devShells = (builtins.getFlake (toString ./.)).devShells or {};
#     }'
#
# `--impure` is required: on the very rev this gate exists to diagnose, the
# devShell attribute cannot be evaluated purely at all (probe above).
{
  # The system whose devShell is being entered, e.g. "x86_64-linux".
  system,
  # The devShell attribute name the job will `nix develop`.
  devshell,
  # The flake's entire `devShells` output: `{ <system> = { <name> = drv; }; }`.
  # A flake with no `devShells` output at all passes `{}`.
  devShells ? { },
  # Set false to get the verdict as data (`{ ok; verdict; message; … }`)
  # rather than a throw. Used by the tests, so the failure paths are
  # exercised without the test file itself having to die.
  strict ? true,
}:

let
  forSystem = devShells.${system} or { };
  available = builtins.attrNames forSystem;
  present = builtins.elem devshell available;

  # Total by construction: a devShell that throws on evaluation is a verdict,
  # not an unhandled error. This is the state the stale-pin case is actually
  # in under a PURE eval, so it must be classified rather than propagated.
  probe =
    if !present then null
    else builtins.tryEval (forSystem.${devshell}.name or "<unnamed>");

  shellName = if probe != null && probe.success then probe.value else null;

  # devenv's own shell derivation name. mkRustDevShell's devenv branch
  # produces it; its plain `pkgs.mkShell` branch produces "nix-shell".
  devenvBacked = shellName == "devenv-shell";

  availableList =
    if available == [ ]
    then "(none — this flake declares no devShells for ${system})"
    else builtins.concatStringsSep ", " available;

  # Shared tail: the two levers, stated once so both failure arms carry them.
  levers = ''
    Two levers, in order of preference:

      1. RE-LOCK. If this flake is built by `substrate.rust.{tool,workspace,
         library,service,binary}`, its devShell stopped being devenv-backed at
         substrate e232917 (2026-07-17) — it is a plain `pkgs.mkShell` with the
         fenix toolchain, which enters non-interactively and needs no extra
         flake input. A pin older than that still carries the broken shape:

             nix flake update substrate

         Verify with:

             nix eval --impure .#devShells.${system}.${devshell}.name
             # "nix-shell"   -> fixed shape
             # "devenv-shell" -> still on the old shape, re-lock

      2. If the devenv shell is DELIBERATE (a hand-authored devenv devShell
         this repo owns, not substrate's), it needs `--impure` passed to
         `nix develop`. NOTE, verified 2026-07-28:
         `nix-devshell-cargo-test.yml` declares only `runner`, `devshell` and
         `test-args` — there is NO `devshell-args` input yet, so this lever
         requires adding one first:

             with:
               devshell-args: "--impure"     # input not yet declared

         and add the input its `languages.rust.channel` resolves against
         (`inputs.rust-overlay.url = "github:oxalica/rust-overlay";`).
         `--impure` alone is NOT sufficient — it clears the working-directory
         assertion and then surfaces the missing input behind it.

    Do not "fix" this by deleting the cargo-test job: on the lockfile build
    path it is the only thing that runs this crate's tests at all.
  '';

  missingMessage = ''
    This flake declares no devShell named `${devshell}` for ${system}, so
    `nix develop ".#${devshell}"` cannot run and the crate's tests would not
    execute.

    devShells declared for ${system}: ${availableList}

    Either point the job at one that exists:

        with:
          devshell: "<one of the above>"

    or have the flake emit `devShells.${system}.${devshell}`.
  '';

  unevaluableMessage = ''
    The devShell `${devshell}` for ${system} is declared but does NOT
    EVALUATE, so `nix develop` fails before cargo is ever invoked. The
    tests did not run and did not fail — nothing was verified.

    devShells declared for ${system}: ${availableList}

    The overwhelmingly common cause is a stale substrate pin: a devenv-backed
    devShell asserts on `builtins.getEnv "PWD"`, which is empty under a
    non-interactive CI `nix develop`.

    ${levers}
  '';

  devenvMessage = ''
    The devShell `${devshell}` for ${system} is DEVENV-BACKED (its derivation
    name is "devenv-shell"), and a devenv shell cannot be entered by this job
    as configured: it asserts on the working directory under a pure
    evaluation, and behind that assertion its `languages.rust.channel` setting
    resolves a `rust-overlay` flake input that a substrate-built consumer
    never declares.

    This is a VERSION SKEW, not a defect in this repo. The workflow is
    consumed at `@main` and updates immediately; your `flake.lock` pins
    whichever substrate rev you last locked.

    ${levers}
  '';

  verdict =
    if !present then "Missing"
    else if shellName == null then "Unevaluable"
    else if devenvBacked then "DevenvBacked"
    else "Ok";

  message =
    if verdict == "Missing" then missingMessage
    else if verdict == "Unevaluable" then unevaluableMessage
    else if verdict == "DevenvBacked" then devenvMessage
    else
      # A green states its subject, never just "ok" — same discipline as
      # flake-checks-gate.nix printing the checks it built.
      "devShell preflight OK on ${system}: `${devshell}` resolves to a "
      + "`${shellName}` derivation and is enterable non-interactively. "
      + "devShells declared for ${system}: ${availableList}";

  ok = verdict == "Ok";

in
  if !strict then { inherit ok verdict message available; name = shellName; }
  else if ok then message
  else throw message
