# test-env.nix — WHICH devShell the publish gate tests in, and at what TIER,
# as a Nix decision rather than a shell if/else in a workflow.
#
# ── WHY THIS IS NIX AND NOT A `run:` BLOCK ────────────────────────────────
#
# It was a ~15-line `run:` with an embedded `nix eval`, a `grep -qx`, and an
# if/else, written into rust-auto-release.yml on 2026-08-06 by the same hand
# that had spent the session enforcing the fleet's no-shell rule. That is the
# whole tell: inline shell in a workflow does not read as a program, it reads
# as YAML with a long string in it, so the rule does not fire when the
# violation arrives in that shape.
#
# The intermediate attempt was a .tlisp, which is the fleet's default target —
# but it does not fit HERE, for two reasons worth recording so nobody re-tries
# it: the script would live in substrate while the job runs in the CONSUMER's
# checkout (so it needs a second `actions/checkout` in all 52 release runs),
# and `pleme-io/actions/tatara-script`'s outputs are an explicitly declared,
# GENERATED 317-key contract in which `tier` exists but `installable` does not
# — and a missing key there is a hard failure, not a silent drop.
#
# Nix is the better answer anyway: the branch belongs next to
# devshell-preflight.nix, which is the thing being branched on, and the caller
# then needs no logic at all — it redirects stdout and nothing else. Zero
# branching and zero parsing in YAML is the property to hold, not "some other
# language".
#
# ── WHAT IT DECIDES ───────────────────────────────────────────────────────
#
# Measured 2026-08-06 across all 52 consumers of rust-auto-release.yml: only
# 17 can enter their own devShell. 25 are devenv-backed (`nix develop` fails
# pure AND --impure), 7 have no flake at all, 3 hard-fail otherwise. A gate
# using `.#default` unconditionally would block ~35 repos from publishing for
# an ENVIRONMENT defect rather than a test failure — and a red whose cause is
# never the thing it claims to check gets muted within a week.
#
# ── WHY THE FALLBACK IS NOT THE ONE devshell-preflight.nix REJECTS ────────
#
# That file refuses `dtolnay/rust-toolchain@stable` + bare cargo, because an
# UNPINNED ambient toolchain lets a crate needing hermetic inputs go green on
# the accident — a fresh vacuous guard inside the gate meant to close one.
# A nix-PINNED substrate shell is a different object, and the difference is
# decisive: when a crate needs an input this shell lacks, the build FAILS.
# A loud false RED, never a vacuous green. It structurally cannot manufacture
# the failure this gate exists to remove.
#
# It is still a WEAKER tier — the environment under test is not the crate's
# declared one — so `tier` is emitted on every run and the caller stamps it
# into the log rather than letting a fallback pass as the strong thing.
#
# Set `fallback = ""` to make a non-Ok preflight THROW instead (fail-closed).
# That is the destination; the fallback is the staged path to it.
{
  system,
  devshell ? "default",
  devShells ? { },
  fallback ? "github:pleme-io/substrate",
  fallbackShell ? "release-gate",
  lib ? (import <nixpkgs> { }).lib,
}:
let
  githubOutput = import ./github-output.nix { inherit lib; };

  shell = if devshell == "" then "default" else devshell;

  pre = import ./devshell-preflight.nix {
    inherit system devShells;
    devshell = shell;
    strict = false;
  };

  useFallback = !pre.ok && fallback != "";

  installable = if pre.ok then ".#${shell}" else "${fallback}#${fallbackShell}";
  tier = if pre.ok then "declared-devshell" else "substrate-fallback";
in
# Rendered by the typed emitter, not concatenated here.
#
# This line used to be `"installable=${installable}\ntier=${tier}\n"` — a
# hand-assembled wire format, written in the same pass that removed a `run:`
# block for the identical reason. The no-shell rule fires on shell and does not
# fire on a format string, so the defect walked straight back in wearing Nix.
# `github-output.nix` refuses a newline in a value (that is an INJECTION, not a
# formatting slip — it writes extra keys), a non-string, a malformed key, and
# an empty set, and it sorts so the bytes never move for free.
if pre.ok || useFallback then
  githubOutput.render {
    inherit installable tier;
  }
else
  throw pre.message
